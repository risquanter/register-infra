variable "cluster_name" {
  description = "k3d cluster name. Becomes the Docker container name prefix and the kubeconfig context."
  type        = string
  default     = "register-dev"
}

variable "k3d_image" {
  description = "k3s image k3d runs, pinned to match the Hetzner k3s version. Note the tag form: k3s '+' becomes '-' here (v1.30.0+k3s1 → rancher/k3s:v1.30.0-k3s1)."
  type        = string
  default     = "rancher/k3s:v1.30.0-k3s1"
}

# ── Image-repo axis (local target) ────────────────────────────────────────────
# create_local_registry selects the image-repo axis for a local cluster:
#   true  → point 1 (local-registry): a k3d-managed registry is created and the
#           cluster nodes are wired to it; apps use the values-localreg overlay.
#   false → point 2 (GHCR): no local registry; apps pull from GHCR via the
#           values-ghcr overlay and the ghcr-pull secret (SECRETS-BOOTSTRAP.md).
# The axis is independent of the cluster; see docs/IMAGE-DEPLOY.md.
variable "create_local_registry" {
  description = "Create a k3d-managed local image registry (point 1). Set false to pull from GHCR instead (point 2)."
  type        = bool
  default     = true
}

variable "registry_name" {
  description = "k3d registry name. k3d prefixes the container/host name with 'k3d-' → k3d-registry.localhost."
  type        = string
  default     = "registry.localhost"
}

variable "registry_port" {
  description = "Host port the local registry publishes on. Overlays reference k3d-registry.localhost:<port>."
  type        = number
  default     = 5000
}

# ── Platform chart versions (passed through to the platform module) ───────────

variable "cilium_version" {
  description = "Cilium Helm chart version."
  type        = string
  default     = "1.17.0"
}

variable "istio_version" {
  description = "Istio Helm chart version. Applied to all four Istio charts (base, cni, ztunnel, istiod)."
  type        = string
  default     = "1.25.0"
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version."
  type        = string
  default     = "1.17.0"
}

variable "argocd_version" {
  description = "ArgoCD Helm chart version (argo/argo-cd)."
  type        = string
  default     = "7.8.0"
}

variable "argocd_image_updater_version" {
  description = "ArgoCD Image Updater Helm chart version."
  type        = string
  default     = "0.11.0"
}
