# ── Providers — local k3d env root ───────────────────────────────────────────
#
# This root creates a local k3d (k3s-in-Docker) cluster and an optional local
# image registry by wrapping the k3d CLI in null_resource local-exec
# provisioners (ADR-INFRA-012 forbids community providers, so there is no k3d
# Terraform provider). It then installs the shared platform module.
#
# Every provider is pinned to an exact version (ADR-INFRA-012 §3: mutable tags
# and version ranges are prohibited). The committed .terraform.lock.hcl records
# the matching checksums. Each block carries the ADR-INFRA-012 §6 approval
# record; versions are the newest release that clears the §4 cooldown as of the
# reviewed date.

terraform {
  required_version = ">= 1.10"

  required_providers {
    # Installs the platform Helm charts into the cluster — holds the kubeconfig
    # and applies CRDs/RBAC cluster-wide (ADR-INFRA-012 Tier-1).
    # Vendor: HashiCorp — https://github.com/hashicorp/terraform-provider-helm
    # Security disclosure: https://github.com/hashicorp/terraform-provider-helm/security/policy
    # Cooldown (T1, 90d): released 2024-12-20 → adopted 2026-08-19 (607 days)
    # Approved: ADR-INFRA-012. Reviewed: 2026-08-19
    helm = {
      source  = "hashicorp/helm"
      version = "= 2.17.0"
    }
    # Backs the k3d cluster/registry lifecycle (create + destroy provisioners).
    # The provisioner scripts are authored in this repo; the provider itself is a
    # trivial utility (ADR-INFRA-012 Tier-4).
    # Vendor: HashiCorp — https://github.com/hashicorp/terraform-provider-null
    # Security disclosure: https://github.com/hashicorp/terraform-provider-null/security/policy
    # Cooldown (T4, 7d): released 2026-05-13 → adopted 2026-08-19 (98 days)
    # Approved: ADR-INFRA-012. Reviewed: 2026-08-19
    null = {
      source  = "hashicorp/null"
      version = "= 3.3.0"
    }
  }
}
