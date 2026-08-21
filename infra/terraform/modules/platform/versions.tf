# Platform module — target-independent Helm layer.
#
# This module installs the same platform stack (Cilium, Istio ambient,
# cert-manager, ArgoCD, ArgoCD Image Updater) into whatever cluster the calling
# env root has already created and pointed the helm provider at. It creates no
# cluster and holds no cloud credentials — the env roots (envs/local,
# envs/hetzner) own cluster creation and configure the helm provider.
#
# The helm provider is configured in the env root and inherited here as the
# default provider. Exact version pinning and the ADR-INFRA-012 §6 approval
# record for the helm provider live in each env root's versions.tf.

terraform {
  required_version = ">= 1.10"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "= 2.17.0"
    }
  }
}
