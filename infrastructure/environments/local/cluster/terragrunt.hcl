include "root" { path = find_in_parent_folders() }

terraform { source = "../../../modules/kind-cluster" }

inputs = {
  cluster_name = "gitops-local"
}