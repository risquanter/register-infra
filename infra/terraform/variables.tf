variable "hcloud_token" {
  description = "Hetzner Cloud API token. Pass via TF_VAR_hcloud_token — never hardcode or commit."
  type        = string
  sensitive   = true
}

variable "ssh_key_name" {
  description = "Name of the SSH key already uploaded to Hetzner Cloud (hcloud ssh-key create)."
  type        = string
}

variable "operator_cidr" {
  description = "Operator egress IP in CIDR notation, e.g. 203.0.113.5/32. Restricts SSH and k8s API firewall rules."
  type        = string
}

variable "hcloud_location" {
  description = "Hetzner datacenter location. eu-central options: nbg1 (Nuremberg), fsn1 (Falkenstein), hel1 (Helsinki)."
  type        = string
  default     = "nbg1"
}

variable "environment" {
  description = "Environment label applied to Hetzner server tags. Used for cost allocation and filtering."
  type        = string
  default     = "dev"
}

variable "k3s_version" {
  description = "k3s release tag. Keep within ±1 minor version of your kubectl client."
  type        = string
  default     = "v1.30.0+k3s1"
}

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
