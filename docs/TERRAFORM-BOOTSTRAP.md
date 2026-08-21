# Terraform Bootstrap — the automated track

Declarative, reproducible cluster provisioning with Terraform, Cilium, Istio
ambient, and ArgoCD. This is the **automated track**: one Terraform codebase
creates the cluster and installs the platform layer up to **Platform Ready** — the
cut-off point where GitOps takes over — then hands off to the shared secrets and
rollout guides. The other track is [MANUAL-BOOTSTRAP.md](MANUAL-BOOTSTRAP.md),
which reaches the same Platform Ready state by hand. See
[START-HERE.md](START-HERE.md) for the full map.

The codebase has two env roots and covers all three supported points:

| Env root | Cluster | Points | Command |
|---|---|---|---|
| `infra/terraform/envs/local` | local k3d | 1 (`create_local_registry=true`), 2 (`=false`) | `cd infra/terraform/envs/local && terraform apply` |
| `infra/terraform/envs/hetzner` | Hetzner VM | 3 (GHCR) | `cd infra/terraform/envs/hetzner && terraform apply` |

Both roots install the same shared platform module
(`infra/terraform/modules/platform`), so the cluster reached is identical.

- **Targets**: local k3d (k3s-in-Docker) or single-node k3s on a Hetzner Cloud VM
- **Principle**: every cluster state change is a `git push` or a `terraform apply` — no imperative commands after bootstrap
- **Secret strategy**: SOPS + age + YubiKey, two recipients (YubiKey + offline backup) — see [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md)
- **GitOps engine**: ArgoCD with App of Apps pattern

> **New to Kubernetes?** The platform components (what each is and why it is
> installed in this order) are documented once in
> [GITOPS-OPERATIONS.md § Platform components](GITOPS-OPERATIONS.md#platform-components--what-each-layer-is-and-why),
> and every term is defined in the [Glossary](GITOPS-OPERATIONS.md#glossary). The
> [MANUAL-BOOTSTRAP.md](MANUAL-BOOTSTRAP.md) track installs the same platform by
> hand, one component at a time, if you would rather learn it that way first — but
> it is not a prerequisite for this one.

---

## How this guide relates to the other docs

Read in this order:

| Order | Document | Purpose |
|---|---|---|
| **1 (this guide)** | Terraform provisioning (local k3d or Hetzner VM) | Create the cluster + install the platform → Platform Ready |
| 2 | [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) | Create + apply the SOPS/age/YubiKey secrets (shared) |
| 3 | [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md) | Enroll ArgoCD, connect git, apply the root app, run tests (shared) |
| 4 | [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md) | Build → push → rollout; the image-repo axis (local registry vs GHCR) |
| ref | [GITOPS-OPERATIONS.md](GITOPS-OPERATIONS.md) | Platform component concepts, day-to-day GitOps workflow, repo layout, glossary |
| ref | [MANUAL-BOOTSTRAP.md](MANUAL-BOOTSTRAP.md) | The by-hand track — the same platform, installed one component at a time |
| ref | [SECURITY-FLOW.md](SECURITY-FLOW.md) | Auth chain architecture |

> **What differs by env root?** `envs/hetzner` adds the Hetzner provider config,
> cloud-init, firewall rules, and VM provisioning; `envs/local` wraps the k3d CLI
> to create a local cluster (and, for point 1, a local registry). Both call the
> same `modules/platform`. Everything from the secrets bootstrap onward (steps
> 2–4) is **shared** — the per-point differences (git-auth method, TLS issuer,
> image repo) are called out in
> [GITOPS-ROLLOUT.md § Environment differences](GITOPS-ROLLOUT.md#environment-differences)
> and [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md).

---

## The bootstrap boundary

The whole build divides into exactly two layers, and the split is the reason the
guides are ordered the way they are:

1. **Bootstrap layer** — Terraform provisions the VM and installs the platform
   (k3s, Cilium, Istio, cert-manager, ArgoCD) via the Helm provider. This is
   run once by the operator (this guide).
2. **GitOps layer** — ArgoCD manages everything above the platform. Changes
   happen through git commits. ArgoCD detects and applies them automatically.

The boundary is the moment you `kubectl apply -f infra/argocd/apps/root.yaml`
(in [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)).

```
╔═══════════════════════════════════════════════════════════════╗
║  GITOPS LAYER — ArgoCD manages from git                      ║
║                                                               ║
║  Namespaces + Pod Security    ← infra/helm/namespaces/        ║
║  PostgreSQL / Keycloak / SpiceDB ← infra/argocd/apps/         ║
║  Istio auth policies          ← infra/k8s/istio/              ║
║  OPA policies                 ← infra/k8s/opa/                ║
║  NetworkPolicies              ← infra/k8s/network-policy/     ║
║  Register application         ← infra/helm/register/          ║
╠═══════════════════════════════════════════════════════════════╣
║  BOOTSTRAP LAYER — Terraform + one-time manual steps          ║
║                                                               ║
║  THIS GUIDE (envs/local or envs/hetzner):                    ║
║  Terraform: k3d cluster, or Hetzner VM/firewall/network       ║
║  modules/platform: Cilium, Istio, cert-manager, ArgoCD        ║
║                                                               ║
║  SECRETS-BOOTSTRAP.md:  SOPS + age + YubiKey secrets          ║
║  GITOPS-ROLLOUT.md:     mesh-enroll ArgoCD → connect git      ║
║                         → root app  ← the handoff moment      ║
╚═══════════════════════════════════════════════════════════════╝
```

---

## Repository layout

See [GITOPS-OPERATIONS.md — Repository layout](GITOPS-OPERATIONS.md#repository-layout)
for the full annotated tree (kept in one place to avoid drift between guides).

The Terraform tree:

```
infra/terraform/
  modules/platform/     shared Helm layer — Cilium, Istio, cert-manager, ArgoCD,
                        Image Updater (target-independent)
  envs/local/           local k3d cluster + optional local registry → modules/platform
  envs/hetzner/         Hetzner VM (network, firewall, cloud-init) → modules/platform
```

Each env root is a separate Terraform root with its own state and its own
`.terraform.lock.hcl`. Running one never touches the other's cluster.

---

## The local env root (points 1 & 2)

This is the automated equivalent of [MANUAL-BOOTSTRAP.md](MANUAL-BOOTSTRAP.md):
Terraform wraps the k3d CLI to create the cluster (and, for point 1, a local
registry), then installs the platform module — reaching the same Platform Ready
state. It needs no cloud account.

**Prerequisites** (operator machine): Docker running, plus the `k3d`, `kubectl`,
and `helm` CLIs — install them per [MANUAL-BOOTSTRAP.md §0](MANUAL-BOOTSTRAP.md).
No Hetzner token, no SSH key.

```bash
cd infra/terraform/envs/local
terraform init

# Point 1 (local-registry): create a k3d registry the cluster pulls from.
terraform apply -var create_local_registry=true

# Point 2 (GHCR): no local registry; apps pull from GHCR (needs the ghcr-pull
# secret from SECRETS-BOOTSTRAP.md, and the values-ghcr overlay).
# terraform apply -var create_local_registry=false

export KUBECONFIG="$PWD/kubeconfig.yaml"
kubectl get nodes
kubectl -n argocd get pods    # ArgoCD Running → Platform Ready
```

Teardown: `terraform destroy` (deletes the k3d cluster and, if created, the
registry). The rest of this guide (§0–§2) is the **Hetzner env root (point 3)**.

---

## Prerequisites — container images

Hetzner (point 3) and local-GHCR (point 2) both use the **GHCR** image-repo:
the three locally-built images (`register-server`, `irmin-prod`, `frontend`) are
pulled from `ghcr.io/risquanter/<image>` with `pullPolicy: IfNotPresent`, applied
via each chart's `values-ghcr.yaml` overlay (the ArgoCD Application layers it in
`helm.valueFiles`). The build → push → rollout loop and that overlay are
documented once in [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md); the images must be in GHCR
before the root app sync
([GITOPS-ROLLOUT.md §5](GITOPS-ROLLOUT.md#5-ensure-application-images-are-in-the-registry)).
The public upstream images (PostgreSQL, Keycloak, SpiceDB, OPA, nginx) pull
directly and need no action. (Point 1 pulls from the local registry instead — no
GHCR, no pull secret; see [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md).)

The one image prerequisite for the **GHCR points** is the pull secret — part of
[Platform Ready checklist #8](GITOPS-ROLLOUT.md#platform-ready--the-precondition):

- **GHCR pull secret** — if the GHCR packages are private, create a GitHub PAT
  with `read:packages` scope, store it as a SOPS-encrypted Kubernetes Secret
  named `ghcr-pull`, and reference it via `imagePullSecrets` (the `values-ghcr.yaml`
  overlays already do). Applied in [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md).

**Outstanding work (not yet implemented):** a GitHub Actions pipeline to build
the three images on push to `main`, tag `:git-sha`, and push to GHCR (tracked in
AUTHORIZATION-PLAN.md phase K.2). Until it exists — or you push the images by hand
per [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md) — ArgoCD shows the `register` and `frontend`
Applications as **Degraded** (ImagePullBackOff) after the root app syncs.

---

## Before you begin — the Phase 4 gate

> **Gate (decided 2026-07-08): do not provision Hetzner until the local cluster
> passes.** The Hetzner rollout (Phase 4) does not start until L2 Path Steps 1–4
> are complete and verified locally, with Step 5 ("Usable Exposure") passing
> against the local k3d cluster. Provisioning paid infrastructure before
> fine-grained authorization works locally means debugging auth issues on
> Hetzner instead of on localhost — strictly worse. Track status in
> [TODO.md § Phase 4](TODO.md).

This is the only ordering dependency on the local cluster. The provisioning steps
below (§0–§2) are otherwise self-contained: you can read and understand them on
their own, and the gate is about *when* to run them, not *how*.

---

## 0) Workstation setup

> **These tools run on YOUR machine**, not on the cluster. They talk to Hetzner
> Cloud (hcloud, Terraform) and to the Kubernetes API (kubectl, ArgoCD CLI). The
> YubiKey plugin (`age-plugin-yubikey`) is installed in
> [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md).

> **Security note — install method**: the workstation tools below are installed
> as pinned binaries verified by checksum (and, for Terraform, by GPG signature),
> or from distro/vendor package repos — no `curl <url> | bash`. The one
> `curl | bash` in this guide is k3s inside the VM's cloud-init (§2), which trusts
> the k3s download server at provision time; that risk is noted where it occurs.

```bash
# ── Terraform ── infrastructure provisioner
# WHAT: pinned binary, checksum-verified, plus a GPG signature check on the
#   checksum manifest (HashiCorp signs it, so this proves authenticity — not
#   just that the zip matches a manifest fetched from the same server).
# WHY: main.tf sets required_version >= 1.10; pin a specific stable release.
# SECURITY: matches the sops/argocd pattern below (no `curl | bash`).
TERRAFORM_VERSION=1.15.8
TF_BASE="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
curl -fsSLO "${TF_BASE}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
curl -fsSLO "${TF_BASE}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
curl -fsSLO "${TF_BASE}/terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig"
# authenticity: import HashiCorp's PGP key and verify it signed the manifest
curl -fsSL https://www.hashicorp.com/.well-known/pgp-key.txt | gpg --import
gpg --verify "terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig" \
             "terraform_${TERRAFORM_VERSION}_SHA256SUMS"   # expect: Good signature
# integrity: the zip matches the (now-trusted) manifest
grep "terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
     "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum --check
unzip -o "terraform_${TERRAFORM_VERSION}_linux_amd64.zip" terraform -d .
sudo install -m755 terraform /usr/local/bin/terraform
rm -f terraform "terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
      "terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
      "terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig"
terraform version   # expect: Terraform v1.15.8

# ── Hetzner Cloud CLI ── API token management and SSH key upload
# macOS:
brew install hcloud
# Linux: download from https://github.com/hetznercloud/cli/releases
#   HCLOUD_VERSION=$(curl -fsSL https://api.github.com/repos/hetznercloud/cli/releases/latest | jq -r .tag_name)
#   curl -fsSLO "https://github.com/hetznercloud/cli/releases/download/${HCLOUD_VERSION}/hcloud-linux-amd64.tar.gz"
#   tar xzf hcloud-linux-amd64.tar.gz && sudo install -m755 hcloud /usr/local/bin/hcloud

# ── age ── modern encryption tool; replaces GPG for SOPS
sudo apt install -y age     # Debian/Ubuntu

# ── SOPS ── encrypts/decrypts secret files using age keys
# SECURITY: verify checksum after download.
SOPS_VERSION=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | jq -r .tag_name)
curl -fsSLO "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
curl -fsSLO "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.checksums.txt"
grep "sops-${SOPS_VERSION}.linux.amd64$" "sops-${SOPS_VERSION}.checksums.txt" | sha256sum --check
sudo install -m755 "sops-${SOPS_VERSION}.linux.amd64" /usr/local/bin/sops
rm -f "sops-${SOPS_VERSION}.linux.amd64" "sops-${SOPS_VERSION}.checksums.txt"

# ── ArgoCD CLI ── bootstrap-time only; day-to-day interaction is via git
# SECURITY: checksum verification included.
ARGOCD_VERSION=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r .tag_name)
curl -fsSLO "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
curl -fsSLO "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/cli_checksums.txt"
grep argocd-linux-amd64 cli_checksums.txt | sha256sum --check
sudo install -m755 argocd-linux-amd64 /usr/local/bin/argocd
rm -f argocd-linux-amd64 cli_checksums.txt
```

---

## 1) Hetzner Cloud setup

> **What is Hetzner Cloud?** A European cloud provider offering affordable
> VMs (called "servers") with good network performance. We use a single VM
> running k3s — enough for this stack at development/early-production scale.

```bash
# WHAT: create an hcloud CLI context. This stores your API token locally.
# The token is created at: https://console.hetzner.cloud → your project → API Tokens
# SECURITY: create a token with read+write scope. Store it in a password manager.
#   The token grants full control over your Hetzner project — treat it like a root password.
hcloud context create register-dev
# paste your API token when prompted

# WHAT: upload your SSH public key to Hetzner. Terraform references it by name.
# WHY: the VM will only accept SSH connections from this key. Password auth is disabled.
hcloud ssh-key create --name register-dev-key --public-key-file ~/.ssh/id_ed25519.pub
```

---

## 2) Hetzner env root — VM, k3s, Cilium, Istio, cert-manager, ArgoCD

> **What does Terraform do here?** It provisions the entire bootstrap layer in
> one `terraform apply`:
> 1. Creates a Hetzner private network + subnet
> 2. Creates a firewall (SSH + HTTPS + k8s API, all CIDR-restricted)
> 3. Creates a VM with cloud-init that installs k3s on first boot
> 4. Retrieves the kubeconfig from the VM
> 5. Installs Cilium, Istio, cert-manager, ArgoCD, and Image Updater via
>    the Terraform Helm provider
>
> All of this is idempotent — running `terraform apply` again changes nothing
> unless the code has changed. This is the core benefit of Infrastructure as
> Code (IaC).

The Hetzner env root lives at
[infra/terraform/envs/hetzner/](../infra/terraform/envs/hetzner/). Key files:

| File | Purpose |
|---|---|
| [main.tf](../infra/terraform/envs/hetzner/main.tf) | Hetzner resources: provider, network, firewall, VM, kubeconfig retrieval, and the `module "platform"` call |
| [variables.tf](../infra/terraform/envs/hetzner/variables.tf) | Input variables with defaults (locations, CIDRs, k3s + chart versions) |
| [outputs.tf](../infra/terraform/envs/hetzner/outputs.tf) | Output values (server IP etc.) |
| [cloud-init.yaml](../infra/terraform/envs/hetzner/cloud-init.yaml) | First-boot script: installs k3s with hardening flags |
| [modules/platform/main.tf](../infra/terraform/modules/platform/main.tf) | The shared Helm releases (Cilium → Istio → cert-manager → ArgoCD → Image Updater) |

### 2.1 The platform stack — what each layer is, and why this order

`terraform apply` builds the cluster from the bottom up. Each layer needs the one
beneath it to already exist, which is why the order is fixed and why every Helm
release in [modules/platform/main.tf](../infra/terraform/modules/platform/main.tf)
is wired to the previous one with `depends_on` (the env root gates the whole
module on cluster readiness). Read top to bottom, this is the shape of the build:

1. **The VM and k3s — the machine and the Kubernetes API.** Terraform creates a
   Hetzner VM, and cloud-init installs k3s (a small single-binary Kubernetes
   distribution) on first boot. k3s is installed *without* its default networking
   and ingress (the cloud-init flags in §2.2 turn them off) because the next
   layers replace them. At the end of this step there is a running Kubernetes API
   but pods cannot yet get network addresses.

2. **Cilium — the network (CNI).** A cluster cannot run application pods until a
   CNI (Container Network Interface) plugin gives pods IP addresses and routes
   traffic between them. k3s ships with flannel, but flannel cannot enforce
   NetworkPolicy (pod-to-pod firewall rules). Cilium replaces it, using eBPF (a
   Linux kernel technology) for both networking and policy. It is installed first
   because every later component runs as pods that need networking.

3. **Istio ambient — the service mesh (mTLS + L7 policy).** The mesh encrypts
   traffic between pods with mutual TLS and enforces identity-based authorization,
   without adding a proxy container to every pod ("ambient" = sidecar-less). It
   installs as four charts in a required order:
   - `base` — the CRDs and cluster roles the mesh's controllers depend on;
     nothing else can install until these types exist.
   - `cni` — the Istio CNI plugin, which runs *alongside* Cilium. This is why
     Cilium is installed with `cni.exclusive=false`: it must not claim sole
     ownership of pod networking.
   - `ztunnel` — the per-node L4 proxy that carries the mTLS tunnel between
     enrolled pods.
   - `istiod` — the control plane that configures ztunnel and issues each pod its
     cryptographic identity.
   Installing out of order produces "CRD not found" errors, so each release
   `depends_on` the previous.

4. **cert-manager — TLS certificate lifecycle.** Issues and renews the TLS
   certificates the ingress gateway serves to browsers. It is installed together
   with its own CRDs (`Certificate`, `ClusterIssuer`) so that later
   GitOps-managed manifests can reference those types. It comes after the mesh
   (it is a normal in-cluster workload that benefits from mTLS) and before ArgoCD
   (its types must exist before ArgoCD syncs manifests that use them).

5. **ArgoCD — the GitOps controller, and the handoff point.** ArgoCD is the last
   thing Terraform installs. Once it is running, Terraform's job is done:
   everything above the platform is declared in git, and ArgoCD applies it. This
   is the bootstrap boundary described earlier — the line between the bootstrap
   layer (this guide) and the GitOps layer.

6. **ArgoCD Image Updater — the build→deploy loop.** A companion controller that
   watches GHCR for new image digests and commits the updated pin back to git, so
   ArgoCD then syncs it. It is installed with ArgoCD because it is part of the
   same GitOps machinery.

The result of `terraform apply` is **Platform Ready**: a networked, mesh-enabled
cluster with a GitOps controller running, waiting for the root application. The
shared guides ([SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md),
[GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)) take it from there.

> Every term above (CNI, service mesh, ztunnel, mTLS, CRD, GitOps, …) has a
> one-line definition in the [Glossary](GITOPS-OPERATIONS.md#glossary). The chart
> sources and pinned versions are recorded in
> [ADR-INFRA-012 §7](adr/ADR-INFRA-012.md) (approved-upstream registry) and set
> in [variables.tf](../infra/terraform/envs/hetzner/variables.tf).

### 2.2 Resource reference

Per-resource notes on [main.tf](../infra/terraform/envs/hetzner/main.tf), focusing on the
security-relevant flags and the two fragile spots in the apply. The code itself
is the definitive source; this is the annotated map.

**Providers** ([versions.tf](../infra/terraform/envs/hetzner/versions.tf)):
- `hcloud` — creates Hetzner Cloud resources (VMs, networks, firewalls)
- `helm` — installs Helm charts into the cluster Terraform just created
- `cloudinit` — renders the cloud-init template with variables (k3s version)
- `null` — backs `null_resource.kubeconfig` (the SSH kubeconfig retrieval below)
- All four are pinned to exact versions with an approval record inline in
  `versions.tf`, and the checksums are committed in this env root's
  `.terraform.lock.hcl` ([ADR-INFRA-012 §3/§6](adr/ADR-INFRA-012.md)).
  `terraform init` therefore resolves identical provider builds on every machine.

**Network** ([main.tf](../infra/terraform/envs/hetzner/main.tf)):
- `hcloud_network` + `hcloud_network_subnet` — private network for pod traffic.
  All node-to-node communication stays off the public internet.

**Firewall** ([main.tf](../infra/terraform/envs/hetzner/main.tf)):
- SSH (port 22): restricted to `var.operator_cidr` — your IP only
- HTTPS (port 443): open to the internet (application ingress)
- k8s API (port 6443): restricted to `var.operator_cidr`
- **Security note**: update `operator_cidr` if your ISP changes your IP.
  Forgetting this locks you out of SSH and the k8s API.

**VM + cloud-init** ([main.tf](../infra/terraform/envs/hetzner/main.tf) + [cloud-init.yaml](../infra/terraform/envs/hetzner/cloud-init.yaml)):
- `hcloud_server` creates a `cpx41` (8 vCPU / 16 GB RAM) VM running Debian 12
- cloud-init writes `/etc/rancher/k3s/config.yaml` with hardening flags:
  - `secrets-encryption: true` — encrypts Kubernetes Secrets at rest in etcd
  - `flannel-backend: none` — Cilium replaces flannel
  - `disable-network-policy: true` — Cilium replaces the built-in controller
  - `disable: traefik` — not needed (Istio handles ingress)
  - `write-kubeconfig-mode: "600"` — strict file permissions
- k3s is installed via `curl | bash` with a pinned version
  - **Security note**: the `curl | bash` pattern trusts the download server.
    For hardened environments, consider pre-baking k3s into a custom VM image
    with checksum verification.

**Kubeconfig retrieval** ([main.tf](../infra/terraform/envs/hetzner/main.tf)):
- `null_resource.kubeconfig` waits 90 seconds, then SSHs into the VM to copy
  the kubeconfig file locally
- **Security note — `StrictHostKeyChecking=no`**: this disables SSH host key
  verification for the first connection. Acceptable for a freshly provisioned
  VM where the host key is unknown. In production with persistent VMs, pin the
  host key after first contact. A MITM attack during this window is low-risk
  because the connection goes over Hetzner's internal network to a VM you just
  created seconds ago.
- **Fragility note — `sleep 90`**: cloud-init may not finish in exactly 90
  seconds depending on VM load and package mirror speed. If `terraform apply`
  fails at the kubeconfig step, wait a minute and run `terraform apply` again
  — it is idempotent. For a more robust approach, replace the sleep with a
  retry loop polling `ssh root@<ip> kubectl get nodes`.

**Helm releases** ([modules/platform/main.tf](../infra/terraform/modules/platform/main.tf)):
- Cilium → Istio (base → cni → ztunnel → istiod) → cert-manager → ArgoCD →
  Image Updater, each `depends_on` the previous; the env root gates the whole
  module on cluster readiness
- Versions are passed through from the env root's [variables.tf](../infra/terraform/envs/hetzner/variables.tf) (defaults in [modules/platform/variables.tf](../infra/terraform/modules/platform/variables.tf))
- Key flag: `cni.exclusive=false` on Cilium (allows Istio CNI coexistence)
- Key flag: `server.insecure=true` on ArgoCD — disables ArgoCD's own TLS
  listener; ztunnel provides mTLS between ArgoCD pods once the namespace is
  enrolled ([GITOPS-ROLLOUT.md §1](GITOPS-ROLLOUT.md#1-enroll-argocd-in-the-mesh)),
  making ArgoCD's built-in TLS redundant

### 2.3 Apply

Prerequisites — walk down this list before the first `terraform apply`:

- [ ] Workstation tools installed (§0): `terraform`, `hcloud`, `kubectl`, `age`, `sops`, `argocd`
- [ ] Hetzner API token created and `hcloud context` set (§1)
- [ ] SSH keypair uploaded to Hetzner and matching `~/.ssh/id_ed25519` present locally (§1)
- [ ] The three application images pushed to GHCR ([IMAGE-DEPLOY.md](IMAGE-DEPLOY.md)), or accept that `register`/`frontend` show **Degraded** until they are
- [ ] The local Phase 4 gate above is green

```bash
cd infra/terraform/envs/hetzner

# WHAT: pass credentials via environment variables — never in .tfvars or CLI flags.
# WHY: environment variables are not stored in shell history (unlike CLI args)
#   and are not committed to git (unlike .tfvars files).
# SECURITY: TF_VAR_hcloud_token has full Hetzner project access. Treat carefully.
export TF_VAR_hcloud_token="<your-hetzner-api-token>"
export TF_VAR_ssh_key_name="register-dev-key"
export TF_VAR_operator_cidr="$(curl -fsSL https://api4.my-ip.io/ip)/32"

# WHAT: terraform init downloads the providers, verifying each against the
#   checksums in the committed .terraform.lock.hcl. A checksum mismatch aborts
#   the init — this is the supply-chain guarantee (ADR-INFRA-012 §3).
terraform init

# WHAT: terraform plan shows what WILL change, without changing anything.
# Always review the plan before applying. This is the IaC equivalent of a dry-run.
terraform plan -out=tfplan

# WHAT: apply the plan. Creates all resources in order.
# This takes 5-10 minutes: VM provisioning + cloud-init + sleep 90 + Helm installs.
terraform apply tfplan

# WHAT: set the kubeconfig so kubectl talks to the new cluster.
# SECURITY: kubeconfig.yaml contains cluster credentials. It is in .gitignore —
#   do not commit it.
export KUBECONFIG="$PWD/kubeconfig.yaml"
kubectl get nodes -o wide

# VERIFICATION: ArgoCD pods should be Running (installed by the Helm provider).
kubectl -n argocd get pods
```

---

## → Continue with the shared guides

The platform is up and ArgoCD's pods are Running. Now:

1. **[SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md)** — create the SOPS/age/YubiKey
   secrets and apply them to the cluster.
2. **[GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)** — enroll ArgoCD in the mesh, rotate
   its password, connect git (Hetzner uses the **HTTPS + PAT** branch in §4),
   apply the root App-of-Apps, and run the auth-chain tests.

There is **no cluster-side age key to inject** — ArgoCD does not decrypt
secrets; the operator applies them by hand with a YubiKey touch
([SECRETS-BOOTSTRAP.md §6](SECRETS-BOOTSTRAP.md#6-apply-the-secrets-to-the-cluster)).

---

## Teardown

```bash
cd infra/terraform/envs/hetzner

# WHAT: destroy all Hetzner Cloud resources (VM, network, firewall).
# Terraform reads its state file and deletes every resource it created.
# Data on the VM (etcd, PVCs) is permanently destroyed.
terraform destroy

# WHAT: remove the local kubeconfig — it is no longer valid.
rm -f kubeconfig.yaml
```

> **Reconstruction**: the cluster is fully recreated by running `terraform apply`
> again, then re-running [SECRETS-BOOTSTRAP.md §6](SECRETS-BOOTSTRAP.md#6-apply-the-secrets-to-the-cluster)
> and [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md). Because all state lives in git
> (Helm charts, ArgoCD apps, SOPS-encrypted secrets), nothing is lost. The only
> external dependency is a private key — the YubiKey or the offline backup.

> **Note:** Terraform state is currently stored locally. Migrate to an
> S3-compatible backend when multi-operator or CI access is needed.
> Tracked in [TODO.md](TODO.md) § Phase 4.

---

## Security boundaries and accepted risks

> **Reference frameworks**: these boundaries are informed by the
> [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
> and [NSA/CISA Kubernetes Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF).

The post-deploy security verification checklist is in
[GITOPS-ROLLOUT.md §12](GITOPS-ROLLOUT.md#12-post-deploy-security-verification)
(shared between environments). The Hetzner-specific boundaries:

| Boundary | Protection | Accepted risk |
|---|---|---|
| **Secrets at rest** | k3s `--secrets-encryption` (AES-CBC) | Single-node: node compromise = key compromise. Mitigate with disk encryption. |
| **Secrets in git** | SOPS + age, two recipients (YubiKey + offline backup). See [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md). | Loss of both the YubiKey and the offline backup = ciphertext unrecoverable. |
| **Container images** | GHCR private registry, digest pinning via Image Updater. Two application images: `register-server` and `irmin` (both built from `risquanter/register`). | Image Updater PAT has `read:packages` scope only. |
| **API server access** | Hetzner firewall restricts port 6443 to `operator_cidr` | Must update CIDR when ISP changes your IP. |
| **SSH access** | Key-only auth, firewall-restricted to `operator_cidr` | No bastion host — direct SSH from operator IP. |
| **Pod-to-pod traffic** | Istio mTLS (ambient) + NetworkPolicy (Cilium) + CiliumNetworkPolicy for health probes | Health probe ports use PeerAuthentication PERMISSIVE. Rollback: remove infra from mesh. |
| **ArgoCD** | Enrolled in mesh, admin password rotated, UI behind port-forward | No SSO in this baseline. Add Dex + OIDC for team use. |
| **Supply chain** | k3s installed via `curl \| bash` | Trusts k3s download server at provision time. Mitigate with custom VM images. |
| **First SSH connection** | `StrictHostKeyChecking=no` for kubeconfig retrieval | One-time risk during fresh VM provisioning. Pin host key afterward. |

### Known limitation: ztunnel + PostgreSQL liveness probes

> **Note:** LimitRange does not cap total namespace resource consumption.
> A ResourceQuota will complement it. Tracked in [TODO.md](TODO.md) § Phase 3.

> **Resolved for the current stack.** The `infra` namespace is enrolled in the
> mesh (`meshEnroll: true` in [values.yaml](../infra/helm/namespaces/values.yaml)).
> Ztunnel intercepts all L4 traffic including kubelet probes. This is handled by:
>
> - **CiliumNetworkPolicy** per service allowing `169.254.7.127/32` (ztunnel
>   SNAT address) to reach health probe ports
> - **PeerAuthentication** port-level PERMISSIVE for probe ports so kubelet's
>   non-mTLS probes succeed
> - PostgreSQL uses `exec` probes (`pg_isready` on `127.0.0.1`) which bypass
>   the network entirely
>
> **If future changes break probes**, use the full rollback file
> [values-infra-no-mesh.yaml](../infra/helm/namespaces/values-infra-no-mesh.yaml)
> to remove infra from the mesh. State this as an accepted risk: `app →
> postgres` and `app → keycloak` traffic becomes plaintext TCP.

---

## Troubleshooting

### Terraform fails at kubeconfig retrieval

The `sleep 90` may be too short if Hetzner is under load or package mirrors
are slow. Wait 2 minutes and re-run — Terraform is idempotent and skips
completed resources:

```bash
terraform apply
```

### SOPS decryption fails

Under the manual two-recipient model, decryption happens on **your workstation**
with the YubiKey (there is no cluster-side age key). If `sops -d` fails:

```bash
# Is the YubiKey present and its identity listed?
age-plugin-yubikey --list

# Does .sops.yaml list the recipient your key corresponds to?
grep -A3 'age:' .sops.yaml

# If the YubiKey is unavailable, decrypt with the offline backup key instead:
export SOPS_AGE_KEY_FILE=/path/to/restored/backup-age-key.txt
sops -d infra/secrets/postgres.enc.yaml | head
```

See [SECRETS-BOOTSTRAP.md § Recovery](SECRETS-BOOTSTRAP.md#recovery).

### Locked out — operator IP changed

```bash
# update your IP and re-apply the firewall rule
export TF_VAR_operator_cidr="$(curl -fsSL https://api4.my-ip.io/ip)/32"
terraform plan -out=tfplan
terraform apply tfplan
```

> For environment-agnostic troubleshooting (ArgoCD stuck, PG/KC crash, quick
> health check), see
> [GITOPS-OPERATIONS.md — Troubleshooting](GITOPS-OPERATIONS.md#troubleshooting).

---

> **Glossary, tooling overview, and repository layout** are maintained in the
> shared operations reference to avoid drift between the local and Hetzner guides:
>
> - [Glossary](GITOPS-OPERATIONS.md#glossary)
> - [Tooling overview](GITOPS-OPERATIONS.md#tooling-overview)
> - [Repository layout](GITOPS-OPERATIONS.md#repository-layout)
