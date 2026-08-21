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
