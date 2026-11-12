# Engineering Report: AI_WORKLOAD_007
**Workload:** Open-Weight LLM Inference on Kubernetes (`Qwen2.5-1.5B-Instruct`)
**Deployment Method:** GitOps (Kustomize + ArgoCD/FluxCD)

## 1. Technology Choices & Justification
- **Model (`Qwen/Qwen2.5-1.5B-Instruct-GGUF`, `Q4_K_M`):** Chosen as a production-representative transformer architecture (28 layers, GQA with 12 query / 2 KV heads) quantized to 4-bit medium (~1.1 GB footprint) to fit comfortably within standard Kubernetes node memory limits while avoiding multi-hour weight transfers.
- **Inference Runtime (`llama.cpp` HTTP Server):** Deployed via `ghcr.io/ggml-org/llama.cpp:server`. Provides native C++ execution without Python runtime overhead, an OpenAI-compatible `/v1/chat/completions` endpoint, Prometheus `/metrics`, and continuous batching (`--parallel 4 --cont-batching`).
- **Storage & GitOps:** Weights are downloaded once via an idempotent `initContainer` onto a `5Gi` `ReadWriteOnce` PVC, decoupling pod lifecycle from external Hugging Face bandwidth.
- **Benchmark Harness (`Grafana k6`):** Deployed as an in-cluster Kubernetes `Job` (`per-vu-iterations`) with deterministic decoding (`temperature: 0.0`, `max_tokens: 128`) to eliminate WAN latency jitter and output variance.

## 2. Benchmark Results (Concurrency 1 vs. Concurrency 4)
**Cluster Node Spec:** [e.g., AMD EPYC / Intel Xeon, X vCPUs, Y GiB RAM]
**Pod Resource Limits:** `4000m` CPU (`--threads 4`), `4Gi` Memory, `--ctx-size 4096`

| Metric | Concurrency = 1 (1 VU) | Concurrency = 4 (4 VUs) | Delta / Scaling Factor |
| :--- | :--- | :--- | :--- |
| **Total Requests** | 15 | 60 | 4.0x |
| **Request Success Rate** | [e.g., 100.0%] | [e.g., 100.0%] | 0.0% |
| **p50 Latency (`med`)** | [e.g., 4,120 ms] | [e.g., 11,450 ms] | [e.g., +178%] |
| **p95 Latency (`p(95)`)** | [e.g., 4,380 ms] | [e.g., 12,890 ms] | [e.g., +194%] |
| **Request Throughput** | [e.g., 0.24 req/s] | [e.g., 0.34 req/s] | [e.g., +41.6%] |
| **Token Throughput** | [e.g., 30.7 tok/s] | [e.g., 43.5 tok/s] | [e.g., +41.6%] |
| **Peak Pod CPU Usage** | [e.g., 3,850m] | [e.g., 3,990m] | Saturated at limit |
| **Peak Pod Memory (RSS)** | [e.g., 1,680 MiB] | [e.g., 1,920 MiB] | +240 MiB (KV Cache) |

## 3. Bottleneck Analysis
1. **CPU Compute & CFS Throttling during Prompt Prefill:** At `concurrency=1`, a single request saturates all 4 allocated CPU threads during matrix-vector multiplication. At `concurrency=4`, continuous batching groups matrix operations across the 4 parallel slots, improving aggregate token throughput by ~[X]%, but per-request p95 latency increases nearly linearly because the pod hits the hard `4000m` CPU CFS quota (`nr_throttled` increases in `/sys/fs/cgroup/cpu.stat`).
2. **Memory Bandwidth Saturation during Decode:** Autoregressive token generation reads the entire 1.1 GB weight file from system RAM for every generated token step. While batching 4 requests amortizes weight reads across 4 tokens simultaneously, system DDR memory bandwidth and L3 cache capacity limit sub-linear scaling on CPU nodes.
3. **KV-Cache Slot Contention:** Allocating `--ctx-size 4096` with `--parallel 4` divides the context window into 4 static 1024-token slots. Requests exceeding 1024 combined prompt + completion tokens will either truncate or block until slots flush.

## 4. Operational Limitations & Next Steps
- **Single-Replica RWO Constraint:** Using a `ReadWriteOnce` PVC requires `strategy: Recreate`, causing brief downtime during deployment rollouts. Migrating to a `ReadOnlyMany` object-store CSI driver or baking the 1.1 GB model into an OCI image volume would enable `RollingUpdate` and Horizontal Pod Autoscaling (HPA).
- **Autoscaling Blindness:** Standard CPU-based HPA reacts poorly to LLM workloads because a single request spikes CPU to 100%. Production scaling requires KEDA triggered by `llamacpp:requests_processing` or `llamacpp:requests_deferred` exported on `/metrics`.