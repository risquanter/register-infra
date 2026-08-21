# ── Providers — Hetzner env root ─────────────────────────────────────────────
#
# This root provisions a Hetzner Cloud VM running k3s (via cloud-init), retrieves
# its kubeconfig over SSH, then installs the shared platform module.
#
# Every provider is pinned to an exact version (ADR-INFRA-012 §3: mutable tags
# and version ranges are prohibited). The committed .terraform.lock.hcl records
# the matching checksums. Each block carries the ADR-INFRA-012 §6 approval
# record; versions are the newest release that clears the §4 cooldown as of the
# reviewed date.

terraform {
  required_version = ">= 1.10"

  required_providers {
    # Creates the Hetzner Cloud VM, network, and firewall — holds the cloud API
    # token, so a compromised build has full project reach (ADR-INFRA-012 Tier-1).
    # Vendor: Hetzner Cloud GmbH — https://github.com/hetznercloud/terraform-provider-hcloud
    # Security disclosure: https://github.com/hetznercloud/terraform-provider-hcloud/security/policy
    # Cooldown (T1, 90d): released 2026-05-12 → adopted 2026-08-19 (99 days)
    # Approved: ADR-INFRA-012. Reviewed: 2026-08-19
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.63.0"
    }
    # Installs the platform Helm charts into the cluster — holds the kubeconfig and
    # applies CRDs/RBAC cluster-wide (ADR-INFRA-012 Tier-1).
    # Vendor: HashiCorp — https://github.com/hashicorp/terraform-provider-helm
    # Security disclosure: https://github.com/hashicorp/terraform-provider-helm/security/policy
    # Cooldown (T1, 90d): released 2024-12-20 → adopted 2026-08-19 (607 days)
    # Approved: ADR-INFRA-012. Reviewed: 2026-08-19
    helm = {
      source  = "hashicorp/helm"
      version = "= 2.17.0"
    }
    # Renders the cloud-init template with dynamic values (k3s version). Handles no
    # credentials and touches nothing on the cluster (ADR-INFRA-012 Tier-4).
    # Vendor: HashiCorp — https://github.com/hashicorp/terraform-provider-cloudinit
    # Security disclosure: https://github.com/hashicorp/terraform-provider-cloudinit/security/policy
    # Cooldown (T4, 7d): released 2026-05-13 → adopted 2026-08-19 (98 days)
    # Approved: ADR-INFRA-012. Reviewed: 2026-08-19
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "= 2.4.0"
    }
    # Backs null_resource.kubeconfig (retrieves the kubeconfig over SSH). The
    # provisioner script is authored in this repo; the provider itself is a
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

  # Remote state keeps the state file off operator laptops and enables team use.
  # Uncomment and configure when a second operator is added.
  # backend "s3" {
  #   bucket = "register-tf-state"
  #   key    = "k3s/terraform.tfstate"
  #   region = "eu-central-1"   # or an S3-compatible EU endpoint
  # }
}
