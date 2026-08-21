# ── Local k3d env root ───────────────────────────────────────────────────────
#
# Creates a local k3d cluster (and, for point 1, a local image registry) by
# wrapping the k3d CLI, writes a kubeconfig, then installs the shared platform
# module into it. The end state is identical to the by-hand MANUAL-BOOTSTRAP.md
# path: a Platform Ready cluster.
#
# Prerequisites on the operator machine: Docker running, and the k3d and helm
# CLIs installed (see docs/MANUAL-BOOTSTRAP.md § prerequisites).

locals {
  kubeconfig_path = "${path.root}/kubeconfig.yaml"

  # Cluster nodes resolve the registry by its k3d host name (k3d prefixes 'k3d-').
  registry_host = "k3d-${var.registry_name}:${var.registry_port}"
  registry_use  = var.create_local_registry ? "--registry-use ${local.registry_host}" : ""
}

# ── Optional local image registry (image-repo axis: point 1) ─────────────────

resource "null_resource" "registry" {
  count = var.create_local_registry ? 1 : 0

  triggers = {
    registry_name = var.registry_name
    registry_port = var.registry_port
  }

  provisioner "local-exec" {
    command = "k3d registry create ${self.triggers.registry_name} --port ${self.triggers.registry_port}"
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "k3d registry delete k3d-${self.triggers.registry_name}"
  }
}

# ── k3d cluster ───────────────────────────────────────────────────────────────

# The --k3s-arg flags disable the k3s components that purpose-built replacements
# supersede: flannel (Cilium is the CNI), the k3s network-policy controller
# (Cilium enforces NetworkPolicy), and traefik (Istio handles ingress). kube-proxy
# and servicelb stay enabled. k3d has no --secrets-encryption equivalent; that is
# the only at-rest difference from the Hetzner env (data lives in a local Docker
# container). See docs/GITOPS-ROLLOUT.md § Platform Ready.
resource "null_resource" "cluster" {
  depends_on = [null_resource.registry]

  triggers = {
    cluster_name    = var.cluster_name
    kubeconfig_path = local.kubeconfig_path
  }

  provisioner "local-exec" {
    command = <<-BASH
      set -euo pipefail
      k3d cluster create ${var.cluster_name} \
        --image ${var.k3d_image} \
        ${local.registry_use} \
        --k3s-arg "--flannel-backend=none@server:0" \
        --k3s-arg "--disable-network-policy@server:0" \
        --k3s-arg "--disable=traefik@server:0" \
        --port "8443:443@loadbalancer" \
        --port "8080:80@loadbalancer" \
        --wait
      k3d kubeconfig get ${var.cluster_name} > ${local.kubeconfig_path}
      chmod 600 ${local.kubeconfig_path}
    BASH
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "k3d cluster delete ${self.triggers.cluster_name}; rm -f ${self.triggers.kubeconfig_path}"
  }
}

# ── Helm provider — targets the k3d cluster created above ────────────────────

provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_path
  }
}

# ── Platform layer (shared module) ────────────────────────────────────────────

module "platform" {
  source     = "../../modules/platform"
  depends_on = [null_resource.cluster]

  cilium_version               = var.cilium_version
  istio_version                = var.istio_version
  cert_manager_version         = var.cert_manager_version
  argocd_version               = var.argocd_version
  argocd_image_updater_version = var.argocd_image_updater_version
}
