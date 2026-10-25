terraform {
  required_providers {
    kind = { source = "tehcyx/kind", version = "~> 0.2.0" }
  }
}

variable "cluster_name" { type = string }

resource "kind_cluster" "default" {
  name           = var.cluster_name
  wait_for_ready = true
}