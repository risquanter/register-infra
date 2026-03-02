output "node_ipv4" {
  description = "Public IPv4 address of the cluster node. Use this for DNS A records and firewall rules."
  value       = hcloud_server.node.ipv4_address
}

output "node_ipv6" {
  description = "Public IPv6 address of the cluster node."
  value       = hcloud_server.node.ipv6_address
}

output "kubeconfig_path" {
  description = "Local path to the generated kubeconfig. Set KUBECONFIG to this value after apply."
  value       = "${path.root}/kubeconfig.yaml"
  sensitive   = true
}

output "argocd_initial_login" {
  description = "Port-forward command to access ArgoCD UI for the initial password rotation."
  value       = "kubectl -n argocd port-forward svc/argocd-server 8080:80"
}
