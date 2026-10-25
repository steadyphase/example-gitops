include "root" { path = find_in_parent_folders() }

terraform { source = "../../../modules/argocd-bootstrap" }

dependencies {
  paths = ["../cluster"]
}

generate "helm_provider" {
  path      = "helm_provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "kind-gitops-local"
  }
}
EOF
}