# ── Hetzner env root ─────────────────────────────────────────────────────────
#
# Provisions the Hetzner Cloud VM (network, firewall, k3s via cloud-init),
# retrieves its kubeconfig over SSH, then installs the shared platform module.
# The end state is identical to the local env: a Platform Ready cluster.

provider "hcloud" {
  token = var.hcloud_token
}

locals {
  kubeconfig_path = "${path.root}/kubeconfig.yaml"
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
  server_type  = "cpx41" # 8 vCPU / 16 GB RAM — fits full stack with headroom
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
      > ${local.kubeconfig_path}
      chmod 600 ${local.kubeconfig_path}
      echo "kubeconfig written to ${local.kubeconfig_path}"
    BASH
  }
}

# ── Helm provider — targets the cluster created above ────────────────────────

provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_path
  }
}

# ── Platform layer (shared module) ────────────────────────────────────────────

module "platform" {
  source     = "../../modules/platform"
  depends_on = [null_resource.kubeconfig]

  cilium_version               = var.cilium_version
  istio_version                = var.istio_version
  cert_manager_version         = var.cert_manager_version
  argocd_version               = var.argocd_version
  argocd_image_updater_version = var.argocd_image_updater_version
}
