output "cluster_name" {
  description = "k3d cluster name. Use with `k3d cluster delete <name>` and kubectl context selection."
  value       = var.cluster_name
}

output "local_registry" {
  description = "Local image registry host, or null when create_local_registry = false (GHCR point)."
  value       = var.create_local_registry ? local.registry_host : null
}

output "kubeconfig_path" {
  description = "Local path to the generated kubeconfig. Set KUBECONFIG to this value after apply."
  value       = local.kubeconfig_path
  sensitive   = true
}

output "argocd_initial_login" {
  description = "Port-forward command to access ArgoCD UI for the initial password rotation."
  value       = "kubectl -n argocd port-forward svc/argocd-server 8080:80"
}
