# k3s GitOps Bootstrap — Infrastructure as Code

Declarative, reproducible cluster provisioning using Terraform, Cilium, Istio ambient, and ArgoCD.

- **Target**: single-node k3s on Hetzner Cloud (identical procedure for any bare Linux VM)
- **Principle**: every cluster state change is a `git push` or a `terraform apply` — no imperative `kubectl` or `helm` commands after bootstrap
- **Secret strategy**: SOPS + age — secrets are encrypted in git, no external secret manager required at this scale
- **GitOps engine**: ArgoCD with App of Apps pattern

---

## Repository layout assumed by this guide

```
infra/
  terraform/          # provisions the VM, k3s, Cilium, Istio, ArgoCD
    main.tf
    variables.tf
    outputs.tf
    cloud-init.yaml
  helm/
    register/         # application Helm chart
      Chart.yaml
      values.yaml
      templates/
    namespaces/       # namespace + label declarations
  argocd/
    apps/
      root.yaml       # App of Apps root — ArgoCD watches this directory
      infra.yaml      # infra-level apps (PostgreSQL, Keycloak)
      register.yaml   # application-level app
  secrets/
    keycloak-db.enc.yaml    # SOPS-encrypted Secret manifests
    postgres.enc.yaml
.sops.yaml                  # SOPS configuration (age recipient)
```

---

## 0) One-time workstation setup

These tools are installed once on the operator's machine, not on the cluster node.

```bash
# Terraform — infrastructure provisioner
# Use tfenv to pin versions, avoiding drift between team members
curl -fsSL https://tfswitch.warrensbox.com/install.sh | bash
tfswitch 1.10.0

# Hetzner Cloud CLI — used for SSH key upload and API token management
brew install hcloud         # macOS
# or: https://github.com/hetznercloud/cli/releases (Linux binary)

# age — modern encryption tool used by SOPS
# age keypairs replace GPG for secret encryption in git
sudo apt install -y age     # Debian/Ubuntu

# SOPS — encrypts/decrypts secret files; reads age keys
# https://github.com/getsops/sops/releases
SOPS_VERSION=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | jq -r .tag_name)
curl -fsSLO "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
sudo install -m755 "sops-${SOPS_VERSION}.linux.amd64" /usr/local/bin/sops

# ArgoCD CLI — used during bootstrap only; day-to-day interaction is via git
ARGOCD_VERSION=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r .tag_name)
curl -fsSLO "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
curl -fsSLO "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/cli_checksums.txt"
grep argocd-linux-amd64 cli_checksums.txt | sha256sum --check
sudo install -m755 argocd-linux-amd64 /usr/local/bin/argocd
rm -f argocd-linux-amd64 cli_checksums.txt
```

---

## 1) Secrets bootstrap (age + SOPS)

Age generates a keypair. The **private key stays on the operator's machine** (and in a secure backup). The public key goes in `.sops.yaml` so anyone can encrypt; only the keyholder can decrypt.

```bash
# generate age keypair — store the private key output securely (password manager)
age-keygen -o ~/.config/sops/age/keys.txt
# output: public key → age1xxxxxxxxxxxxxxxxxxxxxxxxx

# configure SOPS to encrypt to your age public key
# all files matching infra/secrets/** will be encrypted with this recipient
cat > .sops.yaml <<YAML
creation_rules:
  - path_regex: infra/secrets/.*\.yaml$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxx   # replace with your actual public key
YAML
```

```bash
# create and immediately encrypt a secret
# sops opens $EDITOR; write plain YAML, save, sops encrypts on exit
sops infra/secrets/postgres.enc.yaml
```

Example plain content before encryption:

```yaml
# sops will encrypt the values; keys remain visible for auditability
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: infra
type: Opaque
stringData:
  postgres-password: "REPLACE_WITH_STRONG_PASSWORD"
  keycloak-db-password: "REPLACE_WITH_STRONG_PASSWORD"
```

```bash
# verify: encrypted file is safe to commit
cat infra/secrets/postgres.enc.yaml   # values are ciphertext; metadata is plain
git add .sops.yaml infra/secrets/
git commit -m "chore: add encrypted secret stubs"
```

> **Key custody**: the age private key at `~/.config/sops/age/keys.txt` is the single credential that unlocks all secrets. Back it up to a password manager. The cluster itself gets this key as a Kubernetes Secret during bootstrap (step 3.4), so ArgoCD can decrypt secrets at sync time via the SOPS provider.

---

## 2) Hetzner Cloud setup

```bash
# authenticate hcloud CLI
hcloud context create register-dev
# paste your API token when prompted (create one at console.hetzner.cloud → API Tokens)

# upload your SSH public key — Terraform references this by name
hcloud ssh-key create --name register-dev-key --public-key-file ~/.ssh/id_ed25519.pub
```

---

## 3) Terraform — VM, k3s, Cilium, Istio, ArgoCD

Terraform provisions the VM and bootstraps the cluster. All cluster-level tools (Cilium, Istio, ArgoCD) are installed via the Terraform Helm provider so the provisioning is fully idempotent and tracked in state.

### 3.1 `infra/terraform/main.tf`

```hcl
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
    # Used to render the cloud-init template with dynamic values
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
  }
  # Store state remotely so multiple operators share the same view.
  # For a solo project, local state is acceptable but risks loss.
  # backend "s3" {
  #   bucket = "my-tf-state"
  #   key    = "register/k3s.tfstate"
  #   region = "eu-central-1"
  # }
}

# ── Hetzner network ───────────────────────────────────────────────────────────

# Private network: pods and services communicate internally,
# not over the public internet
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

  # Allow SSH from operator IP only — replace with your actual egress IP
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.operator_cidr]
  }

  # Allow HTTPS for the ingress (application traffic)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # k8s API server — restrict to operator only in production
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.operator_cidr]
  }
}

# ── Server ────────────────────────────────────────────────────────────────────

# cloud-init configures the OS and installs k3s on first boot.
# All k3s flags are set here — no SSH session needed.
data "cloudinit_config" "node" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content      = templatefile("${path.module}/cloud-init.yaml", {
      k3s_version = var.k3s_version
    })
  }
}

resource "hcloud_server" "node" {
  name        = "register-node"
  server_type = "cpx41"        # 8 vCPU / 16 GB RAM — fits full stack with headroom
  image       = "debian-12"
  location    = "nbg1"         # Nuremberg; use fsn1 or hel1 for other EU regions
  ssh_keys    = [data.hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]
  user_data   = data.cloudinit_config.node.rendered

  network {
    network_id = hcloud_network.main.id
    ip         = "10.0.1.10"
  }

  # Hetzner block storage — survives server replacement
  labels = { environment = "dev", project = "register" }
}

data "hcloud_ssh_key" "operator" {
  name = var.ssh_key_name
}

# ── kubeconfig ────────────────────────────────────────────────────────────────

# Wait for cloud-init to finish, then retrieve kubeconfig from the node.
# The null_resource is a deliberate escape hatch: there is no Terraform-native
# way to retrieve a file written by cloud-init. This is accepted practice.
resource "null_resource" "kubeconfig" {
  depends_on = [hcloud_server.node]

  provisioner "local-exec" {
    command = <<-BASH
      echo "Waiting for k3s to finish starting..."
      sleep 90
      ssh -o StrictHostKeyChecking=no \
          -i ~/.ssh/id_ed25519 \
          root@${hcloud_server.node.ipv4_address} \
          "cat /etc/rancher/k3s/k3s.yaml" \
      | sed 's/127.0.0.1/${hcloud_server.node.ipv4_address}/g' \
      > ${path.root}/kubeconfig.yaml
      chmod 600 ${path.root}/kubeconfig.yaml
    BASH
  }
}

# ── Helm provider — points at the cluster we just created ────────────────────

provider "helm" {
  kubernetes {
    config_path = "${path.root}/kubeconfig.yaml"
  }
}

# ── Cilium ────────────────────────────────────────────────────────────────────

# Cilium is the CNI (pod networking layer). It replaces k3s's default flannel
# because flannel cannot enforce NetworkPolicy — a hard requirement for our
# default-deny security posture.
#
# cni.exclusive = false is mandatory: Istio ambient installs its own CNI plugin
# (istio-cni) alongside Cilium. Without this flag, Cilium marks itself as the
# sole CNI owner and istio-cni fails to register.
resource "helm_release" "cilium" {
  depends_on = [null_resource.kubeconfig]

  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.17.0"
  namespace  = "kube-system"

  set {
    name  = "cni.exclusive"
    value = "false"
  }

  set {
    name  = "operator.replicas"
    value = "1"   # single-node: one operator replica is sufficient
  }
}

# ── Istio ambient ─────────────────────────────────────────────────────────────

# Istio is the service mesh. "Ambient mode" means no per-pod sidecar containers.
# Instead, a per-node ztunnel DaemonSet handles traffic. This is lighter and
# avoids disrupting existing deployments with sidecar injection.
#
# Installation order matters: base → cni → ztunnel → istiod → gateway
# Each chart provides a distinct layer; installing in wrong order causes CRD errors.

resource "helm_release" "istio_base" {
  depends_on = [helm_release.cilium]

  name       = "istio-base"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = "1.25.0"
  namespace  = "istio-system"
  create_namespace = true
}

resource "helm_release" "istio_cni" {
  depends_on = [helm_release.istio_base]

  name       = "istio-cni"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "cni"
  version    = "1.25.0"
  namespace  = "istio-system"

  set {
    name  = "profile"
    value = "ambient"
  }
}

resource "helm_release" "ztunnel" {
  depends_on = [helm_release.istio_cni]

  name       = "ztunnel"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "ztunnel"
  version    = "1.25.0"
  namespace  = "istio-system"
}

resource "helm_release" "istiod" {
  depends_on = [helm_release.ztunnel]

  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = "1.25.0"
  namespace  = "istio-system"

  set {
    name  = "profile"
    value = "ambient"
  }
}

# ── cert-manager ──────────────────────────────────────────────────────────────

# cert-manager automates TLS certificate lifecycle (issuance, renewal).
# Required before any Ingress or Gateway that needs HTTPS.
resource "helm_release" "cert_manager" {
  depends_on = [helm_release.istiod]

  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "1.17.0"
  namespace  = "cert-manager"
  create_namespace = true

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────

# ArgoCD is the GitOps controller. After this is installed, all further cluster
# state is declared in git and applied by ArgoCD — not by Terraform or kubectl.
#
# server.insecure = true: TLS termination happens at the ingress/gateway layer,
# not at the ArgoCD server itself. ArgoCD listens plain HTTP inside the cluster.
resource "helm_release" "argocd" {
  depends_on = [helm_release.cert_manager]

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.8.0"
  namespace  = "argocd"
  create_namespace = true

  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  # Expose the API server as ClusterIP only — access via port-forward or ingress
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
}

# ── ArgoCD Image Updater ──────────────────────────────────────────────────────

# Image Updater watches GHCR for new image tags and writes the updated tag
# back to the git repo as a commit. ArgoCD then detects the git change and
# syncs the cluster. This closes the fully automated deploy loop:
#   git push → CI builds image → Image Updater commits tag → ArgoCD syncs
resource "helm_release" "argocd_image_updater" {
  depends_on = [helm_release.argocd]

  name       = "argocd-image-updater"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  version    = "0.11.0"
  namespace  = "argocd"

  set {
    name  = "config.argocd.insecure"
    value = "true"
  }
}
```

### 3.2 `infra/terraform/cloud-init.yaml`

```yaml
#cloud-config
# Runs on first boot of the Hetzner VM.
# Installs k3s with all hardening flags in one automated step.
# No SSH session required.

package_update: true
packages:
  - curl
  - jq
  - git

# Write the k3s install flags to a file before running the installer.
# This makes them visible and auditable rather than buried in a long CLI string.
write_files:
  - path: /etc/rancher/k3s/config.yaml
    owner: root:root
    permissions: "0600"
    content: |
      # encrypt secrets at rest in etcd
      secrets-encryption: true
      # restrict kubeconfig to owner only
      write-kubeconfig-mode: "600"
      # traefik disabled — ingress is managed as an ArgoCD application
      disable:
        - traefik
      # flannel disabled — Cilium is the CNI (installed by Terraform Helm provider)
      flannel-backend: "none"
      # disable k3s's built-in network policy controller — Cilium handles this
      disable-network-policy: true

runcmd:
  # Install k3s. The config file above is read automatically.
  # Pin to a specific version matching your kubectl client (±1 minor skew).
  - |
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${k3s_version}" sh -
  # Verify secret encryption is active before anything else starts
  - k3s secrets-encrypt status
```

### 3.3 `infra/terraform/variables.tf`

```hcl
variable "hcloud_token" {
  description = "Hetzner Cloud API token. Set via TF_VAR_hcloud_token env var — never hardcode."
  type        = string
  sensitive   = true
}

variable "ssh_key_name" {
  description = "Name of the SSH key uploaded to Hetzner Cloud (hcloud ssh-key create)."
  type        = string
}

variable "operator_cidr" {
  description = "Your egress IP in CIDR notation, e.g. 203.0.113.5/32. Restricts SSH and k8s API access."
  type        = string
}

variable "k3s_version" {
  description = "k3s release tag, e.g. v1.30.0+k3s1. Keep in sync with kubectl client version (±1 minor)."
  type        = string
  default     = "v1.30.0+k3s1"
}
```

### 3.4 Apply

```bash
cd infra/terraform

# pass the API token via environment — never in terraform.tfvars or CLI flags
export TF_VAR_hcloud_token="<your-hetzner-api-token>"
export TF_VAR_ssh_key_name="register-dev-key"
export TF_VAR_operator_cidr="$(curl -fsSL https://api4.my-ip.io/ip)/32"

terraform init
terraform plan -out=tfplan
terraform apply tfplan

# kubeconfig.yaml is now written to infra/terraform/ — do not commit this file
export KUBECONFIG="$PWD/kubeconfig.yaml"
kubectl get nodes -o wide
```

---

## 4) Post-Terraform bootstrap (one-time, then GitOps takes over)

After `terraform apply`, the cluster has Cilium, Istio, cert-manager, and ArgoCD running. This section performs the minimum one-time configuration needed before GitOps can operate autonomously.

### 4.1 ArgoCD admin password rotation

```bash
# port-forward ArgoCD API server for bootstrap commands only
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
PF_PID=$!
sleep 3

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

argocd login localhost:8080 \
  --username admin \
  --password "$ARGOCD_PASS" \
  --insecure

# rotate immediately — generated password is single-use
read -r -s -p "New ArgoCD admin password: " NEW_PASS; echo
argocd account update-password \
  --account admin \
  --current-password "$ARGOCD_PASS" \
  --new-password "$NEW_PASS"

unset ARGOCD_PASS NEW_PASS
kubectl -n argocd delete secret argocd-initial-admin-secret

kill $PF_PID 2>/dev/null || true
```

### 4.2 Install SOPS decryption key into the cluster

ArgoCD uses the `argocd-sops` plugin to decrypt `infra/secrets/*.enc.yaml` at sync time. The age private key must be present as a Secret so the plugin can access it.

```bash
# read age private key content — stored in ~/.config/sops/age/keys.txt by age-keygen
kubectl -n argocd create secret generic sops-age-key \
  --from-file=keys.txt="$HOME/.config/sops/age/keys.txt" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 4.3 Connect the GitHub repository

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
PF_PID=$!
sleep 3

read -r -p "GitHub repo URL (https://github.com/org/repo): " GH_REPO
read -r -p "GitHub username: " GH_USER
read -r -s -p "GitHub PAT (read:repo): " GH_PAT; echo

argocd repo add "$GH_REPO" \
  --username "$GH_USER" \
  --password "$GH_PAT" \
  --insecure

unset GH_USER GH_PAT
kill $PF_PID 2>/dev/null || true
```

### 4.4 Register base namespaces as a Helm release

```bash
# Namespaces with Pod Security labels and istio enrollment are declared as a
# Helm chart so ArgoCD manages them. No manual `kubectl create namespace`.
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
PF_PID=$!
sleep 3

argocd app create namespaces \
  --repo "$GH_REPO" \
  --path infra/helm/namespaces \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default \
  --sync-policy automated \
  --auto-prune \
  --self-heal

argocd app sync namespaces
argocd app wait namespaces --health --timeout 60

kill $PF_PID 2>/dev/null || true
```

### 4.5 Apply the root App of Apps

The root Application points ArgoCD at `infra/argocd/apps/`. Every file in that directory is itself an ArgoCD Application — this is the App of Apps pattern. Adding a new service means adding one YAML file to that directory and pushing; ArgoCD handles the rest.

```bash
kubectl apply -f infra/argocd/apps/root.yaml
```

`infra/argocd/apps/root.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  # Finalizer ensures child apps are deleted if root is deleted.
  # Remove if you want to decommission without cascade delete.
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/<repo>
    targetRevision: HEAD
    path: infra/argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## 5) Application declarations (managed by ArgoCD, not kubectl)

After step 4.5, all further cluster state is declared in `infra/argocd/apps/` and synced automatically. The following files are committed to the repo — no further manual commands.

### `infra/argocd/apps/postgresql.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: postgresql
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: postgresql
    targetRevision: "16.4.0"
    helm:
      valuesObject:
        auth:
          # Secret reference — value injected by SOPS decrypt at sync time
          existingSecret: postgres-credentials
          secretKeys:
            adminPasswordKey: postgres-password
        primary:
          persistence:
            enabled: true
            size: 10Gi
          containerSecurityContext:
            enabled: true
            runAsNonRoot: true
  destination:
    server: https://kubernetes.default.svc
    namespace: infra
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### `infra/argocd/apps/keycloak.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: keycloak
    targetRevision: "24.4.0"
    helm:
      valuesObject:
        auth:
          existingSecret: keycloak-credentials
          passwordSecretKey: admin-password
        postgresql:
          enabled: false
        externalDatabase:
          host: postgresql-postgresql.infra.svc.cluster.local
          port: 5432
          user: bn_keycloak
          existingSecret: postgres-credentials
          existingSecretPasswordKey: keycloak-db-password
          database: keycloak
  destination:
    server: https://kubernetes.default.svc
    namespace: infra
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### `infra/argocd/apps/register.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: register
  namespace: argocd
  annotations:
    # Image Updater: watch GHCR for new tags on the main branch
    # update-strategy=digest tracks the exact image digest, not a mutable tag
    argocd-image-updater.argoproj.io/image-list: "app=ghcr.io/<org>/<image>"
    argocd-image-updater.argoproj.io/app.update-strategy: digest
    argocd-image-updater.argoproj.io/app.helm.image-name: image.repository
    argocd-image-updater.argoproj.io/app.helm.image-tag: image.tag
    # write-back commits the new tag to git — the audit trail lives in git history
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/git-branch: main
    argocd-image-updater.argoproj.io/app.pull-secret: "secret:argocd/ghcr-image-updater#password"
spec:
  project: default
  source:
    repoURL: https://github.com/<org>/<repo>
    targetRevision: HEAD
    path: infra/helm/register
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: register
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## 6) Namespace chart (Pod Security + mesh enrollment)

`infra/helm/namespaces/templates/namespaces.yaml`:

```yaml
{{- range .Values.namespaces }}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .name }}
  labels:
    {{- with .podSecurity }}
    pod-security.kubernetes.io/enforce: {{ .enforce }}
    pod-security.kubernetes.io/audit: {{ .audit }}
    pod-security.kubernetes.io/warn: {{ .warn }}
    {{- end }}
    {{- if .meshEnroll }}
    # enrolling in ambient mode means ztunnel intercepts all traffic in/out of
    # this namespace — no per-pod annotation needed
    istio.io/dataplane-mode: ambient
    {{- end }}
---
{{- end }}
```

`infra/helm/namespaces/values.yaml`:

```yaml
namespaces:
  - name: register
    meshEnroll: true
    podSecurity:
      enforce: restricted
      audit: restricted
      warn: restricted
  - name: infra
    meshEnroll: false   # PostgreSQL + Keycloak are not in the mesh
    podSecurity:
      enforce: baseline
      audit: restricted
      warn: restricted
  - name: observability
    meshEnroll: false
    podSecurity:
      enforce: baseline
      audit: baseline
      warn: restricted
```

---

## 7) The full automated deploy loop

```
git push (application code change)
  → GitHub Actions:
      sbt test
      docker buildx build --push ghcr.io/<org>/<image>:<git-sha>
  → ArgoCD Image Updater (polls GHCR every 2 min):
      detects new digest at ghcr.io/<org>/<image>
      commits updated tag to infra/helm/register/.argocd-source-register.yaml
  → ArgoCD (polls git every 3 min, or webhook for instant trigger):
      detects commit on HEAD
      runs helm upgrade -n register register infra/helm/register
  → kubectl -n register get pods   ← new pod running within ~90s of git push
```

For instant sync on push, add a GitHub webhook pointing at the ArgoCD API server (requires public ingress or a tunnel for dev).

---

## 8) Teardown

```bash
# destroy all cloud resources — VM, network, firewall, volumes
cd infra/terraform
terraform destroy

# remove kubeconfig
rm -f kubeconfig.yaml
```

The cluster is fully reconstructed by re-running `terraform apply`. Because all state is in git (Helm charts, ArgoCD applications, encrypted secrets), there is nothing to back up beyond the age private key.

---

## 9) Security boundaries and accepted risks

| Boundary | Protection | Accepted risk |
|---|---|---|
| Secrets at rest (etcd) | k3s `--secrets-encryption` | Single-node: node compromise = key compromise |
| Secrets in git | SOPS + age encryption | Age private key must be kept secure; loss = lockout |
| Container images | GHCR private registry, digest pinning | Image Updater PAT has read:packages scope only |
| API server access | Hetzner firewall, restricted to operator CIDR | CIDR rotation required on IP change |
| Pod-to-pod traffic | Istio mTLS (ambient), NetworkPolicy (Cilium) | Unenrolled namespaces (`infra`) are plaintext east-west |
| SSH access | Key-only, firewall-restricted | No bastion; direct SSH from operator IP |
| ArgoCD | Admin password rotated on bootstrap, UI behind port-forward | No SSO in this baseline; add Dex + OIDC for team use |
