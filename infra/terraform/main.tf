# ── Providers ────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.10"
  required_providers {
    # Official Hetzner Cloud provider — maintained by Hetzner GmbH
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
    # Helm provider — installs charts into the cluster Terraform just created
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # Renders the cloud-init template with dynamic values (k3s version etc.)
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
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

provider "hcloud" {
  token = var.hcloud_token
}

# ── Hetzner private network ───────────────────────────────────────────────────

# All node-to-node and pod-to-pod traffic travels on this private network.
# The public interface is used only for SSH (bootstrap) and ingress (HTTPS).
resource "hcloud_network" "main" {
  name     = "register-net"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "main" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

# ── Firewall ──────────────────────────────────────────────────────────────────

resource "hcloud_firewall" "node" {
  name = "register-node"

  # SSH — operator CIDR only. Update var.operator_cidr when your IP changes.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.operator_cidr]
  }

  # HTTPS — application traffic from the public internet
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # k8s API server — operator CIDR only. Never expose publicly.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.operator_cidr]
  }
}

# ── cloud-init — installs k3s on first boot ───────────────────────────────────

data "cloudinit_config" "node" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/cloud-init.yaml", {
      k3s_version = var.k3s_version
    })
  }
}

# ── Server ────────────────────────────────────────────────────────────────────

data "hcloud_ssh_key" "operator" {
  name = var.ssh_key_name
}

resource "hcloud_server" "node" {
  name         = "register-node"
  server_type  = "cpx41"     # 8 vCPU / 16 GB RAM — fits full stack with headroom
  image        = "debian-12"
  location     = var.hcloud_location
  ssh_keys     = [data.hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]
  user_data    = data.cloudinit_config.node.rendered

  network {
    network_id = hcloud_network.main.id
    ip         = "10.0.1.10"
  }

  labels = {
    environment = var.environment
    project     = "register"
  }
}

# ── kubeconfig retrieval ──────────────────────────────────────────────────────

# Waits for cloud-init / k3s to finish, then copies the kubeconfig locally.
# null_resource is an accepted pattern here — there is no Terraform-native
# mechanism to retrieve a file written by a remote cloud-init run.
# kubeconfig.yaml is in .gitignore — it must never be committed.
resource "null_resource" "kubeconfig" {
  depends_on = [hcloud_server.node]

  provisioner "local-exec" {
    command = <<-BASH
      echo "Waiting for k3s API server to become ready (~90s)..."
      sleep 90
      ssh -o StrictHostKeyChecking=no \
          -o ConnectTimeout=30 \
          -i ~/.ssh/id_ed25519 \
          root@${hcloud_server.node.ipv4_address} \
          "cat /etc/rancher/k3s/k3s.yaml" \
      | sed 's/127.0.0.1/${hcloud_server.node.ipv4_address}/g' \
      > ${path.root}/kubeconfig.yaml
      chmod 600 ${path.root}/kubeconfig.yaml
      echo "kubeconfig written to ${path.root}/kubeconfig.yaml"
    BASH
  }
}

# ── Helm provider — targets the cluster created above ────────────────────────

provider "helm" {
  kubernetes {
    config_path = "${path.root}/kubeconfig.yaml"
  }
}

# ── Cilium — CNI ──────────────────────────────────────────────────────────────

# Cilium replaces k3s's default flannel CNI. Flannel cannot enforce
# NetworkPolicy; Cilium provides full NetworkPolicy support and better eBPF
# integration with Istio ambient ztunnel.
#
# cni.exclusive = false is mandatory: Istio ambient installs its own CNI plugin
# (istio-cni) alongside Cilium. Cilium must not claim sole CNI ownership.
resource "helm_release" "cilium" {
  depends_on = [null_resource.kubeconfig]

  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  set {
    name  = "cni.exclusive"
    value = "false"
  }

  set {
    name  = "operator.replicas"
    value = "1"  # single-node — one replica sufficient
  }
}

# ── Istio ambient — service mesh ──────────────────────────────────────────────

# Installation order: base → cni → ztunnel → istiod
# Each release depends on the previous one via depends_on.
# Out-of-order installation causes CRD-not-found errors.

resource "helm_release" "istio_base" {
  depends_on       = [helm_release.cilium]
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version
  namespace        = "istio-system"
  create_namespace = true
}

resource "helm_release" "istio_cni" {
  depends_on = [helm_release.istio_base]
  name       = "istio-cni"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "cni"
  version    = var.istio_version
  namespace  = "istio-system"

  set { name = "profile"; value = "ambient" }
}

resource "helm_release" "ztunnel" {
  depends_on = [helm_release.istio_cni]
  name       = "ztunnel"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "ztunnel"
  version    = var.istio_version
  namespace  = "istio-system"
}

resource "helm_release" "istiod" {
  depends_on = [helm_release.ztunnel]
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version
  namespace  = "istio-system"

  set { name = "profile"; value = "ambient" }
}

# ── cert-manager — TLS certificate lifecycle ──────────────────────────────────

resource "helm_release" "cert_manager" {
  depends_on       = [helm_release.istiod]
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  set { name = "crds.enabled"; value = "true" }
}

# ── ArgoCD — GitOps controller ────────────────────────────────────────────────

# After ArgoCD is running, all further cluster state is declared in git and
# applied by ArgoCD — Terraform does not manage application-level resources.
#
# server.insecure = true: TLS terminates at the ingress/gateway layer,
# not at the ArgoCD server process. ArgoCD listens plain HTTP inside the cluster.
resource "helm_release" "argocd" {
  depends_on       = [helm_release.cert_manager]
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  namespace        = "argocd"
  create_namespace = true

  set { name = "configs.params.server\\.insecure"; value = "true" }
  set { name = "server.service.type";              value = "ClusterIP" }
}

# ── ArgoCD Image Updater ──────────────────────────────────────────────────────

# Image Updater polls GHCR for new image digests and commits the updated tag
# back to git. ArgoCD then detects the commit and syncs the cluster.
# Full automated loop: git push → CI builds → Image Updater commits → ArgoCD syncs.
resource "helm_release" "argocd_image_updater" {
  depends_on = [helm_release.argocd]
  name       = "argocd-image-updater"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  version    = var.argocd_image_updater_version
  namespace  = "argocd"

  set { name = "config.argocd.insecure"; value = "true" }
}
