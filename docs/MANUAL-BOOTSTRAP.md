# Manual Bootstrap — build the platform by hand (local)

The **by-hand track**: install each platform component yourself with its own CLI,
from first principles, on a k3d (k3s-in-Docker) cluster running entirely on your
machine. It provisions the cluster and platform layer up to **Platform Ready** —
the cut-off point where GitOps takes over — then hands off to the shared
[SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) and [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md).

The other way to reach Platform Ready is the automated track,
[TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md), which does the same steps with
Terraform (on a local k3d cluster or a Hetzner VM). Both tracks are educational
and both end at the same Platform Ready state, after which the secrets and rollout
guides are identical. See [START-HERE.md](START-HERE.md) for the full map.

This guide covers the local cluster. The image-repo choice is separate: point 1
(local registry, §1.1 below) or point 2 (GHCR — skip §1.1 and follow the GHCR
variant in [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md)). Both run on this same by-hand
cluster.

- **Target**: fresh Debian workstation, no cloud account needed
- **Principle**: manually bootstrap the platform layer (k3d + registry, Cilium,
  Istio, cert-manager, ArgoCD), then let GitOps manage everything above it
- **End state**: [Platform Ready](GITOPS-ROLLOUT.md#platform-ready--the-precondition)
  — the cut-off point defined in the rollout guide
- **Versions**: every pinned version comes from the [Pinned versions](#pinned-versions)
  table below — the single source in this track; no number is restated inline
- **Security posture**: defence-in-depth from the start — even on localhost

> **New to Kubernetes?** This guide explains every concept as it comes up.
> Skim the [Glossary](GITOPS-OPERATIONS.md#glossary) and
> [Tooling overview](GITOPS-OPERATIONS.md#tooling-overview) in the shared
> operations reference before starting — you do not need to memorise anything,
> but having seen the terms once makes the rest easier to follow.

---

## How this guide relates to the other docs

Read in this order:

| Order | Document | Purpose |
|---|---|---|
| **1 (this guide)** | Local dev cluster on your machine | Provision k3d (+ optional registry), install the platform, by hand → Platform Ready |
| 2 | [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) | Create + apply the SOPS/age/YubiKey secrets (shared) |
| 3 | [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md) | Enroll ArgoCD, connect git, apply the root app, run tests (shared) |
| — | [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md) | Build → push → rollout loop; the image-repo axis (local registry vs GHCR) |
| ref | [GITOPS-OPERATIONS.md](GITOPS-OPERATIONS.md) | Platform component concepts, day-to-day GitOps workflow, repo layout, glossary |
| ref | [TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md) | The automated track — the same platform via Terraform (local k3d or Hetzner VM) |
| ref | [SECURITY-FLOW.md](SECURITY-FLOW.md) | Auth chain architecture |

Steps 2 and 3 are **shared** with the automated track — only this part (how you
get a cluster and install the platform, by hand) is track-specific. Both tracks
end at Platform Ready; everything in the GitOps layer (ArgoCD Applications, Helm
charts, policies) is identical and portable between them.

---

## Pinned versions

**The single source of versions for this track.** Every step below cites a row
here; no version number is typed anywhere else in this guide. The automated track
reads the same numbers from the `infra/terraform/envs/*/variables.tf` and
`infra/terraform/modules/platform/variables.tf` defaults — keep them in sync when
you bump a version.

| Component | Version | Installed at |
|---|---|---|
| **k3s** | `v1.30.0+k3s1` (k3d `--image rancher/k3s:v1.30.0-k3s1`) | §1.2 |
| **kubectl** (client) | `v1.31.0` (stay within ±1 minor of k3s) | §0.3 |
| **Cilium** chart | `1.17.0` | §2 |
| **Gateway API CRDs** | `v1.2.0` (standard channel) | §3.1 |
| **Istio** (base, cni, ztunnel, istiod) | `1.25.0` | §0.7 / §3.2 |
| **cert-manager** chart | `1.17.0` | §4 |
| **ArgoCD** chart (argo/argo-cd) | `7.8.0` | §5 |
| **ArgoCD Image Updater** chart | `0.11.0` | §5.1 |

---

## The bootstrap boundary

This is the most important concept. There are exactly two layers in any
GitOps-managed Kubernetes setup:

1. **Bootstrap layer** — things you install by hand, because the automation
   engine (ArgoCD) does not exist yet. You run shell commands for this.
2. **GitOps layer** — everything ArgoCD manages. You change these by editing
   files in git and pushing. ArgoCD detects the change and applies it.

The boundary is the moment you apply the "root App-of-Apps" (in
[GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)).

```
GITOPS LAYER — ArgoCD manages these from your git repo
    Namespaces + Pod Security        ← infra/helm/namespaces/
    PostgreSQL / Keycloak / SpiceDB  ← infra/argocd/apps/
    Istio auth policies              ← infra/k8s/istio/
    OPA policies                     ← infra/k8s/opa/
    Network policies                 ← infra/k8s/network-policy/
    Register application             ← infra/helm/register/
    To change any of the above: edit file → commit → push
────────────────────────────────────────────────────────────────
BOOTSTRAP LAYER — manual, one-time

  THIS GUIDE (each step builds toward Platform Ready):
    ① k3d cluster create (+ local registry — point 1 only)
    ② Cilium               (CNI — pod networking)
    ③ Istio ambient        (service mesh — mTLS + L7 policy)
    ④ cert-manager         (TLS certificate automation)
    ⑤ ArgoCD + Image Updater (GitOps engine) — installed, pods Running
    ────────────────────── ← PLATFORM READY (cut-off point → GITOPS-ROLLOUT.md)

  SECRETS-BOOTSTRAP.md:  ⑥ SOPS + age + YubiKey secrets
  GITOPS-ROLLOUT.md:     ⑦ mesh-enroll ArgoCD → root app  ← the handoff moment
                         ⑧ images pushed to the registry (IMAGE-DEPLOY.md)
```

---

## Repository layout

See [GITOPS-OPERATIONS.md — Repository layout](GITOPS-OPERATIONS.md#repository-layout)
for the full annotated tree (kept in one place to avoid drift between guides).

---

## 0) Prerequisites — fresh Debian install

This section installs the CLI tools you need on your workstation. None of
these tools run inside the cluster — they talk to the cluster from your
terminal.

> **Security note — `curl | bash` pattern**: Several tools below use the
> convenience pattern `curl <url> | bash` to install. This is standard in the
> Kubernetes ecosystem for development workstations but means you are trusting
> the download server at install time. For production CI pipelines, prefer
> pinned binary downloads with checksum verification (shown where available).

### 0.1 System packages

```bash
# WHAT: install foundational Unix tools used by later steps.
# - curl: download files from the internet (used by every installer below)
# - jq: parse JSON output from APIs and kubectl
# - git: version control — the backbone of GitOps
# - openssl: TLS utilities used by Helm and cert-manager
# - ca-certificates: trusted root certificates for HTTPS connections
# - gnupg: GPG used by Docker's repo signing
# - lsb-release: identifies your Debian version for apt repository setup
sudo apt update
sudo apt install -y curl jq git openssl ca-certificates gnupg lsb-release
```

### 0.2 Docker

k3d runs k3s inside Docker containers. Docker must be installed first.

> **What is Docker?** Docker is a tool for running applications inside
> lightweight, isolated environments called "containers". k3d uses Docker
> to run k3s (a Kubernetes distribution) as a container on your machine,
> so you get a full Kubernetes cluster without needing a separate VM.

```bash
# WHAT: add Docker's official apt repository.
# WHY: Debian's repos ship older Docker versions. The official repo provides
#   security patches and feature releases much faster.
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io

# WHAT: allow your user to use Docker without typing "sudo" every time.
# WHY: convenience, and many tools (k3d, docker build) assume non-root Docker.
# SECURITY: this makes YOUR user equivalent to root for container operations.
#   Acceptable on a personal dev machine. On shared servers, use rootless Docker.
sudo usermod -aG docker "$USER"
newgrp docker

# IMPORTANT: log out and back in for the group change to take effect.
# Then verify Docker works:
docker info >/dev/null && echo "Docker is working"
```

### 0.3 kubectl

> **What is kubectl?** The Kubernetes command-line tool. Every interaction with
> a Kubernetes cluster — listing pods, applying YAML files, reading logs —
> goes through kubectl. Think of it as "the Kubernetes terminal client".

```bash
# WHAT: install kubectl, pinned to a specific Kubernetes version.
# WHY: kubectl should match your cluster's Kubernetes version within ±1 minor
#   version. k3d currently ships k3s based on Kubernetes ~1.31.
# SECURITY: we verify the download checksum to ensure the binary is authentic
#   and not tampered with in transit.
K8S_VERSION="v1.31.0"

curl -fsSLO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
curl -fsSLO "https://dl.k8s.io/${K8S_VERSION}/bin/linux/amd64/kubectl.sha256"

# verify integrity: compares the computed SHA-256 hash against the expected one
echo "$(cat kubectl.sha256) kubectl" | sha256sum --check

sudo install -m755 kubectl /usr/local/bin/kubectl
rm -f kubectl kubectl.sha256
kubectl version --client
```

### 0.4 Helm

> **What is Helm?** Helm is a package manager for Kubernetes (analogous to
> apt for Debian). A "Helm chart" is a bundle of Kubernetes YAML templates +
> a `values.yaml` configuration file. Instead of writing dozens of YAML files
> by hand, you install a chart and configure it with values. For example,
> `helm install postgresql bitnami/postgresql` deploys a full PostgreSQL
> database with one command. Keycloak is deployed from a local Helm chart
> (at `infra/helm/keycloak/`) using the official upstream image
> `quay.io/keycloak/keycloak:26.0`.

```bash
# WHAT: install Helm via the official install script.
# NOTE: this is a curl|bash install. For CI/production use, download the
#   binary directly from https://github.com/helm/helm/releases with checksum.
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### 0.5 k3d

> **What is k3d?** k3d runs k3s (a lightweight Kubernetes distribution)
> inside Docker containers on your machine. You get a real Kubernetes cluster
> that can be created and destroyed in seconds. The Kubernetes API is
> identical to a full cluster — your Helm charts, policies, and ArgoCD
> config work exactly the same on k3d as on a Hetzner Cloud VM.

```bash
# WHAT: install k3d via the official install script.
curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
k3d version
```

### 0.6 Cilium CLI

> **What is Cilium?** Cilium is a CNI (Container Network Interface) plugin.
> In plain English: it is the software that lets pods talk to each other.
> A fresh Kubernetes cluster has no networking until a CNI is installed —
> the node will show "NotReady" until then.
>
> We chose Cilium specifically because it also enforces NetworkPolicies
> (firewall rules between pods) using eBPF — a high-performance Linux kernel
> technology. The default CNI shipped with k3s (flannel) cannot enforce
> NetworkPolicies at all, which means our default-deny security posture
> would not work.

```bash
# WHAT: install the Cilium CLI, which is used to install Cilium into a cluster.
# SECURITY: we verify the download checksum.
CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -fsSLO "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"
curl -fsSLO "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz.sha256sum"
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm -f cilium-linux-amd64.tar.gz cilium-linux-amd64.tar.gz.sha256sum
cilium version --client
```

### 0.7 istioctl

> **What is Istio?** Istio is a service mesh — a dedicated infrastructure
> layer that handles network traffic between your services. It provides:
> - **mTLS** (mutual TLS): automatic encryption of all traffic between pods,
>   with no code changes needed in your application
> - **L7 policy enforcement**: rules like "reject this request if the JWT is
>   invalid" or "only allow GET requests to this endpoint"
>
> Istio **ambient mode** (which we use) runs as a per-node process (ztunnel)
> instead of injecting a sidecar container into every pod. This is simpler
> and lighter than traditional Istio.
>
> `istioctl` is the CLI tool for installing and managing Istio.

```bash
# WHAT: download the Istio release bundle, extract the istioctl binary, clean up.
# The istioctl version determines the Istio control-plane version it installs in
# §3, so pin it to the Istio row of the Pinned versions table.
ISTIO_VERSION=1.25.0   # = Pinned versions table (Istio)
curl -L https://istio.io/downloadIstio | ISTIO_VERSION="$ISTIO_VERSION" sh -
ISTIO_DIR=$(ls -d istio-*/ | head -n1)
sudo install -m755 "${ISTIO_DIR}bin/istioctl" /usr/local/bin/istioctl
rm -rf "$ISTIO_DIR"
istioctl version --remote=false
```

### 0.8 SOPS + age

> **What are SOPS and age?** SOPS (Secrets OPerationS) encrypts YAML values
> while leaving keys visible — you can see which fields a secret contains
> (for code review and auditability) without seeing the values. age is the
> modern encryption backend SOPS uses (replacing GPG).
>
> Both the local and production guides use the same SOPS + age workflow. The
> YubiKey plugin (`age-plugin-yubikey`) and the full secrets model are covered
> in the shared [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) — this step just
> installs the two base binaries.

```bash
# ── age ── modern encryption tool
sudo apt install -y age
age --version

# ── SOPS ── encrypts/decrypts secret files using age keys
# SECURITY: verify checksum after download.
SOPS_VERSION=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | jq -r .tag_name)
curl -fsSLO "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
curl -fsSLO "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.checksums.txt"
grep "sops-${SOPS_VERSION}.linux.amd64$" "sops-${SOPS_VERSION}.checksums.txt" | sha256sum --check
sudo install -m755 "sops-${SOPS_VERSION}.linux.amd64" /usr/local/bin/sops
rm -f "sops-${SOPS_VERSION}.linux.amd64" "sops-${SOPS_VERSION}.checksums.txt"
sops --version
```

### 0.9 ArgoCD CLI

> **What is ArgoCD?** ArgoCD is a GitOps controller for Kubernetes. It
> watches a git repository and ensures the cluster state matches what is
> declared in the repo. If someone manually changes something in the cluster,
> ArgoCD reverts it (self-healing). If a new file is added to git, ArgoCD
> applies it (reconciliation).
>
> The ArgoCD CLI is used only during bootstrap to log in, rotate the admin
> password, and connect the git repo. After that, you interact with ArgoCD
> by pushing to git — or via the web UI at `http://localhost:9090`.

```bash
# WHAT: install the ArgoCD CLI.
ARGOCD_VERSION=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest \
  | jq -r .tag_name)
curl -fsSLO "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
sudo install -m755 argocd-linux-amd64 /usr/local/bin/argocd
rm -f argocd-linux-amd64
argocd version --client
```

---

## 1) Create the k3d cluster

> **What happens here**: k3d asks Docker to start a container running k3s.
> This container IS your Kubernetes cluster. k3d also creates a "loadbalancer"
> container that forwards ports from your host machine (localhost:8080,
> localhost:8443) into the cluster.
>
> **Why these `--k3s-arg` flags** — each disables a bundled k3s component that
> a purpose-built replacement supersedes:
> - **`--flannel-backend=none`** — Cilium is the CNI.
> - **`--disable-network-policy`** — Cilium enforces NetworkPolicy.
> - **`--disable=traefik`** — Istio handles ingress via the Gateway API; nothing
>   in this repo uses classic `Ingress` objects.
>
> **kube-proxy stays enabled** — Cilium runs as the CNI/NetworkPolicy layer
> without replacing kube-proxy. (Cilium's `kubeProxyReplacement` uses eBPF
> socket-level load balancing that conflicts with Istio ambient's ztunnel
> redirection, so it is not used here.) **servicelb (klipper) stays enabled** —
> it assigns the EXTERNAL-IP to the ingress Gateway's `LoadBalancer` Service and
> binds the node port that the `--port "8080:80@loadbalancer"` host mapping
> forwards to.
>
> **Security note**: k3d does not support the `--secrets-encryption` flag that
> bare k3s provides (etcd secret encryption at rest). This is acceptable for a
> local dev cluster where the "etcd" data lives inside a Docker container on
> your own machine. The Hetzner env of the automated track enables this — see the
> [Platform Ready note on secret encryption](GITOPS-ROLLOUT.md#platform-ready--the-precondition)
> and [TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md). It is the only at-rest
> difference between the local and Hetzner clusters.
>
> **Automated-track equivalent**: `envs/local` creates this same k3d cluster via
> Terraform; `envs/hetzner` is the Hetzner VM + `cloud-init.yaml` — see
> [TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md).

### 1.1 Create the local image registry — point 1 only

> **Skip this section for point 2 (GHCR).** A local registry is meaningful only
> when the image-repo axis is the local registry (point 1). For point 2 (GHCR on
> this local cluster), do not create a registry: leave §1.2's `--registry-use`
> flag out, and follow the GHCR variant in [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md).

> **Why a registry?** The cluster pulls application images the same way in every
> environment: from a registry, with `pullPolicy: IfNotPresent`. For point 1 that
> registry is a k3d-managed container; for points 2 and 3 it is GHCR. Using a real
> registry (rather than side-loading images into the node) means the image is
> genuinely "in the registry" from the GitOps engine's point of view — the local
> path mirrors the GHCR pull path exactly. The build → push → rollout loop, and
> the image-repo axis, are in [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md).

```bash
# WHAT: create a k3d-managed registry container, published on host port 5000.
# k3d names the container k3d-registry.localhost and configures cluster nodes
# to resolve that name to it.
k3d registry create registry.localhost --port 5000

# WHAT: make the SAME image reference resolve from the host too, so `docker push
# k3d-registry.localhost:5000/...` reaches the published port. The cluster nodes
# already resolve the name via k3d's injected registries config.
grep -q 'k3d-registry.localhost' /etc/hosts \
  || echo '127.0.0.1 k3d-registry.localhost' | sudo tee -a /etc/hosts
```

### 1.2 Create the cluster

```bash
# --image pins k3s to the Pinned versions table (k3s row), matching the
#   Hetzner k3s version so both infra targets run the same Kubernetes.
# --registry-use wires the cluster's nodes to the registry created in §1.1.
#   POINT 2 (GHCR): omit the --registry-use line entirely — you did not create
#   a local registry; apps pull from GHCR instead (IMAGE-DEPLOY.md, GHCR variant).
k3d cluster create register-dev \
  --image rancher/k3s:v1.30.0-k3s1 \
  --registry-use k3d-registry.localhost:5000 \
  --k3s-arg "--flannel-backend=none@server:0" \
  --k3s-arg "--disable-network-policy@server:0" \
  --k3s-arg "--disable=traefik@server:0" \
  --port "8443:443@loadbalancer" \
  --port "8080:80@loadbalancer" \
  --wait
```

k3d automatically writes a kubeconfig (the file that tells kubectl how to
connect to your cluster) and sets it as the active context:

```bash
# WHAT: verify the cluster is reachable.
# The node will show "NotReady" — this is expected because we disabled flannel
# and have not installed Cilium yet. No CNI = no pod networking = NotReady.
kubectl cluster-info
kubectl get nodes
```

---

## 2) Install Cilium (CNI)

> **Why now?** The node stays NotReady until a CNI is installed. Pods cannot be
> scheduled or communicate without a network layer. Cilium must be first.
>
> **Key flag**: `cni.exclusive=false` — this is critical. Istio ambient mode
> installs its own CNI plugin (istio-cni) alongside Cilium. By default,
> Cilium marks itself as the exclusive CNI and blocks istio-cni from
> registering. Setting `exclusive=false` allows both to coexist.

```bash
# --version: the Cilium row of the Pinned versions table.
# operator.replicas=1: single-node cluster — one operator instance is sufficient.
cilium install --version 1.17.0 \
  --set cni.exclusive=false \
  --set operator.replicas=1

# WHAT: wait until all Cilium pods are running and healthy.
# This typically takes 30-60 seconds.
cilium status --wait

# VERIFICATION: the node should now show "Ready".
kubectl get nodes
```

> **Terraform equivalent**: `helm_release.cilium` in `infra/terraform/modules/platform/` (the automated track) — same
> chart, same version variable, same `cni.exclusive=false` / `operator.replicas=1`.

> **What just happened**: Cilium deployed several pods into `kube-system`:
> - `cilium-agent` (DaemonSet) — runs on every node, programs eBPF rules
> - `cilium-operator` — manages Cilium's internal state
>
> Every pod created from now on gets its network interface from Cilium.
> NetworkPolicy resources (firewall rules between pods) will be enforced by
> Cilium's eBPF programs in the Linux kernel.

---

## 3) Install Istio ambient mode

> **Why now?** Istio should be installed before any workload pods are created.
> This ensures ztunnel (the per-node proxy) intercepts traffic from the very
> first packet every pod sends, rather than having to restart existing pods.

### 3.1 Gateway API CRDs

> **What are CRDs?** Custom Resource Definitions extend the Kubernetes API
> with new resource types. The Gateway API CRDs add resource types like
> `Gateway` and `HTTPRoute` that Istio uses for traffic management.
> These are not included in k3s by default — they must be installed
> before Istio's waypoint proxies can work.

```bash
# v1.2.0 = the Gateway API CRDs row of the Pinned versions table.
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# VERIFICATION: confirm the CRDs are registered.
kubectl get crd gateways.gateway.networking.k8s.io
kubectl get crd httproutes.gateway.networking.k8s.io
```

### 3.2 Install Istio

> **What does `--set profile=ambient` do?** It installs Istio in ambient mode,
> which means:
> - A `ztunnel` DaemonSet runs on every node (L4 proxy — handles mTLS)
> - An `istiod` Deployment runs as the control plane
> - An `istio-cni` DaemonSet integrates with the node's CNI (alongside Cilium)
> - No sidecar containers are injected into your application pods
>
> Traditional Istio injects a sidecar proxy container into every pod. Ambient
> mode avoids this — the ztunnel process on the node handles mTLS transparently.

```bash
# Installs the Istio version of the istioctl binary — pinned to the table in §0.7.
istioctl install -y --set profile=ambient

# VERIFICATION: all Istio pods should be Running.
# You should see: istiod, istio-cni, and ztunnel pods.
kubectl -n istio-system get pods
```

> **Terraform equivalent**: `helm_release.istio_base` → `istio_cni` → `ztunnel` →
> `istiod` in `infra/terraform/modules/platform/` (the automated track) — the four charts `istioctl`
> installs as one, each pinned to the same Istio version variable.

> **mTLS is now active.** From this moment, ztunnel encrypts all traffic
> between pods in mesh-enrolled namespaces using mutual TLS. This is
> identical to what runs in production. There is no "dev mode" or "local
> mode" — ztunnel does not know it is running inside Docker. The encryption,
> certificate rotation, and SPIFFE identity assignment are all real.
>
> You verify mTLS after workloads are deployed —
> [GITOPS-ROLLOUT.md §11](GITOPS-ROLLOUT.md#11-test-the-authentication-chain)
> includes the checks. The key test: `istioctl ztunnel-config workloads` shows
> each pod's SPIFFE identity and whether its traffic is `HBONE` (encrypted) or
> `NONE` (plaintext).

---

## 4) Install cert-manager

> **What is cert-manager?** cert-manager automates TLS certificate lifecycle:
> requesting certificates, renewing them before expiry, and storing them as
> Kubernetes Secrets. It is needed before any HTTPS ingress is configured.
>
> For local development, cert-manager issues from a **self-signed**
> `ClusterIssuer`; production swaps in ACME/Let's Encrypt. The Gateway and
> HTTPRoute are identical — only the issuer differs.

```bash
# WHAT: add the Jetstack Helm repository (Jetstack maintains cert-manager).
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

# WHAT: install cert-manager into its own namespace.
# --version: the cert-manager row of the Pinned versions table.
# --set crds.enabled=true: installs the CRDs that cert-manager needs
#   (Certificate, Issuer, ClusterIssuer etc.)
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version 1.17.0 \
  --set crds.enabled=true

# VERIFICATION: wait for cert-manager to be fully running.
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
```

> **Terraform equivalent**: `helm_release.cert_manager` in `infra/terraform/modules/platform/` (the automated track).

---

## 5) Install ArgoCD

> **What happens here**: install ArgoCD as a Helm chart. After this, the cluster
> has a GitOps engine, but it is not yet meshed, and not yet watching any
> repository — those are the first steps of
> [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md).
>
> **Where ArgoCD lives and how it communicates**: ArgoCD runs as **pods inside
> the cluster**, in the `argocd` namespace. It has four network relationships:
>
> | Connection | From → To | Encryption |
> |---|---|---|
> | **You → ArgoCD UI/API** | terminal → `kubectl port-forward` → ArgoCD pod | k8s API server's TLS encrypts the tunnel |
> | **ArgoCD → GitHub** | repo-server → github.com | Standard HTTPS |
> | **ArgoCD → k8s API** | controller → k8s API server | ServiceAccount token over API server TLS |
> | **ArgoCD internal** | server ↔ repo-server ↔ controller | mTLS via ztunnel (after mesh enrollment) |
>
> **Understanding `server.insecure=true`**: this disables ArgoCD's own HTTP-listener
> TLS. The word "insecure" is misleading — it means "ArgoCD's own process does
> not do TLS", not "unencrypted to the outside world". Once ArgoCD is inside the
> mesh, ztunnel provides mTLS between pods, so ArgoCD's own TLS listener would be
> redundant. Access from your machine is via `kubectl port-forward`, encrypted by
> the k8s API server's own TLS.

```bash
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update

# --version: the ArgoCD row of the Pinned versions table.
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 7.8.0 \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=ClusterIP

# VERIFICATION: wait for the three core ArgoCD components.
# - argocd-server: the API + web UI
# - argocd-repo-server: clones git repos and renders Helm charts
# - argocd-application-controller: watches for changes and syncs (a StatefulSet)
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s
```

### 5.1 Install ArgoCD Image Updater

> Image Updater polls a container registry for new digests and commits the
> updated tag back to git, closing the automated deploy loop
> ([GITOPS-OPERATIONS.md § The automated deploy loop](GITOPS-OPERATIONS.md#the-automated-deploy-loop)).
> It is part of [Platform Ready](GITOPS-ROLLOUT.md#platform-ready--the-precondition)
> (checklist #7) so both tracks reach the same state. It sits idle locally until
> the image-repo parameter is GHCR; installing it now keeps the local platform a
> faithful mirror of Hetzner.

```bash
# --version: the Image Updater row of the Pinned versions table.
helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --version 0.11.0 \
  --set config.argocd.insecure=true

kubectl -n argocd rollout status deploy/argocd-image-updater --timeout=180s
```

> **Terraform equivalent**: `helm_release.argocd` + `helm_release.argocd_image_updater`
> in `infra/terraform/modules/platform/` (the automated track), same versions and settings.

> **ArgoCD is installed but NOT yet meshed and NOT yet rotated.** Mesh
> enrollment (with its two ambient accommodations) and the admin-password
> rotation are the first two steps of
> [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md#1-enroll-argocd-in-the-mesh) — they are
> identical on both environments, so they live in the shared guide.

---

## Platform Ready — the cut-off point

The platform layer is installed. This is **Platform Ready** — where this track
ends and GitOps takes over. Confirm the cluster against the
[Platform Ready checklist](GITOPS-ROLLOUT.md#platform-ready--the-precondition)
(the full definition, shared by both tracks) before continuing.

```bash
kubectl get nodes                      # one Ready node
kubectl -n kube-system get pods        # Cilium
kubectl -n istio-system get pods       # istiod, ztunnel, istio-cni
kubectl -n cert-manager get pods       # cert-manager
kubectl -n argocd get pods             # ArgoCD + Image Updater
curl -s http://k3d-registry.localhost:5000/v2/_catalog   # registry reachable
```

All pods `Running`/`Completed`, one node `Ready`, registry responding → you are
at Platform Ready.

---

## → Continue with the shared guides

From Platform Ready the path is identical for both tracks and all points:

1. **[SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md)** — create the SOPS/age/YubiKey
   secrets and apply them to the cluster.
2. **[GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)** — enroll ArgoCD in the mesh, rotate
   its password, connect git, push the application images, apply the root
   App-of-Apps, and run the auth-chain tests.

The application images (`register-server`, `irmin`, `frontend`) are built and
pushed to the local registry with the loop in
**[IMAGE-DEPLOY.md](IMAGE-DEPLOY.md)** — the first push is a precondition of
[GITOPS-ROLLOUT.md §5](GITOPS-ROLLOUT.md#5-ensure-application-images-are-in-the-registry),
and the same loop is how you ship every later build. The public upstream images
(Keycloak, PostgreSQL, SpiceDB, OPA, nginx) need no action — the node pulls them
directly.

---

## Teardown

```bash
# WHAT: delete the entire k3d cluster. All pods, data, and secrets are destroyed.
k3d cluster delete register-dev

# WHAT: delete the registry container too (its pushed images go with it).
k3d registry delete k3d-registry.localhost
```

To recreate, run this guide from §1 (prerequisites are already installed), then
re-run [SECRETS-BOOTSTRAP.md §6](SECRETS-BOOTSTRAP.md#6-apply-the-secrets-to-the-cluster)
and [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md), pushing the images again per
[IMAGE-DEPLOY.md](IMAGE-DEPLOY.md). Because all GitOps state is in git, ArgoCD
redeploys everything automatically.

---

## Next steps — the automated track and the other points

When the auth chain, GitOps workflow, and application all work on this by-hand
cluster, the automated track, [TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md),
does the same platform install with Terraform — on a local k3d cluster
(`envs/local`, points 1 and 2) or a Hetzner VM (`envs/hetzner`, point 3),
reaching the same Platform Ready state. From there the **same**
[SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) and [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)
apply unchanged — point ArgoCD at the same git repo and it deploys the identical
stack. The per-point differences are summarised in
[GITOPS-ROLLOUT.md § Environment differences](GITOPS-ROLLOUT.md#environment-differences).

---

## Security considerations for local development

> **Best practice frameworks referenced**: these notes follow the principles
> from the NSA/CISA Kubernetes Hardening Guide and CIS Kubernetes Benchmark,
> adapted for a local dev context.

| Area | Hetzner env (automated track) | Local k3d (this guide) | Why the difference is acceptable |
|---|---|---|---|
| Secrets at rest | k3s `--secrets-encryption` (AES-CBC) | Not available in k3d | Data is in a Docker container on your own machine |
| Secrets in git | SOPS + age (YubiKey + backup) | SOPS + age (same) | Same encrypted files, same workflow |
| Network perimeter | Hetzner firewall, CIDR-restricted SSH | Docker bridge network | No public exposure |
| Supply chain | GHCR + digest pinning (Image Updater) | local k3d registry (`docker push`, `IfNotPresent`) | Same registry-pull path; digest pinning added when the image-repo parameter is GHCR |
| Pod Security | Restricted PSS | `register`: Restricted; `infra`/`argocd`: baseline enforce, restricted audit/warn | infra workloads pass restricted; upgrade pending |
| NetworkPolicy | Default-deny + Cilium (same) | Default-deny + Cilium (same) | Same policies, same enforcement |
| mTLS | Istio ztunnel (same) | Istio ztunnel (same) | Same mesh config |

**What is identical in both paths**: everything in the GitOps layer — Helm
charts, ArgoCD Applications, Istio policies, OPA rules, NetworkPolicies, Pod
Security labels. Those are the security controls that matter for the application.

---

## Troubleshooting

> For shared issues (ArgoCD sync, database crashes, health checks), see
> [GITOPS-OPERATIONS.md — Troubleshooting](GITOPS-OPERATIONS.md#troubleshooting).
> The sections below cover k3d-specific issues only.

### Node stays NotReady after Cilium install

```bash
cilium status
kubectl -n kube-system logs -l k8s-app=cilium --tail=50
```

### Cannot reach app via localhost:8080

```bash
docker ps | grep k3d-register-dev-serverlb   # k3d loadbalancer running?
kubectl -n register get svc                   # service defined?
kubectl -n register get pods                  # pod running?
kubectl -n register describe pod <pod-name>   # detailed pod status
```

### Istio mTLS errors after laptop sleep (certificate expired)

> **What happens**: ztunnel holds SPIFFE mTLS certificates with a 24h TTL.
> It renews them automatically — but only while it is running and can reach
> istiod. When the laptop sleeps, ztunnel is frozen. If the cert expires
> while sleeping, ztunnel starts rejecting all pod-to-pod connections with
> `certificate expired` errors. Symptoms: ArgoCD `connection reset by peer`
> on port 8081, gRPC failures between pods, or any service-to-service call
> inside a mesh-enrolled namespace failing immediately.
>
> How to confirm: check ztunnel logs for the word `expired`:

```bash
kubectl -n istio-system logs -l app=ztunnel --since=5m | grep expired
```

> Fix: restart ztunnel so it reconnects to istiod and gets fresh certificates.
> Then restart the affected pods so they get new identities too.

```bash
# WHAT: ztunnel is a DaemonSet — it runs one instance per node.
# Restarting it causes it to reconnect to istiod and re-fetch all SPIFFE certs.
kubectl -n istio-system rollout restart daemonset/ztunnel
kubectl -n istio-system rollout status daemonset/ztunnel --timeout=60s

# WHAT: restart any pods that had connections rejected due to expired certs.
# Their in-kernel iptables interception rules are rebuilt on pod start.
kubectl -n argocd rollout restart deployment/argocd-server deployment/argocd-repo-server
kubectl -n argocd rollout status deployment/argocd-server --timeout=60s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=60s
```

> **Make this a habit after any long sleep**: if you put the laptop to sleep
> for more than a few hours and then see strange connection errors inside the
> cluster, run the ztunnel restart above before investigating further.

### CoreDNS fails to resolve external names after sleep (`server misbehaving`)

> **What happens**: k3d runs CoreDNS inside the cluster to handle DNS for
> pods. CoreDNS forwards external lookups (e.g. `github.com`) to the
> nameservers it reads from `/etc/resolv.conf` on the node — which is the
> k3s container, not your host. After a laptop sleep/wake, your host's DNS
> resolver (systemd-resolved) may have changed upstream servers or lost
> state, and the k3d container's view of DNS does not update automatically.
> Symptom: `argocd repo add` fails with `lookup github.com: server misbehaving`.
>
> Fix: restart CoreDNS so it re-reads `/etc/resolv.conf` from the node.

```bash
# WHAT: CoreDNS is a Deployment in kube-system.
# Restarting it forces it to re-read the node's /etc/resolv.conf and
# pick up the current upstream nameservers from systemd-resolved.
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n kube-system rollout status deployment/coredns --timeout=60s

# VERIFICATION: DNS should now resolve from inside the cluster.
# NOTE: --rm only deletes the pod on clean exit. If DNS is broken and nslookup
# times out, the pod stays behind. Always clean up first to avoid AlreadyExists.
kubectl delete pod dnstest --ignore-not-found
kubectl run dnstest --rm -i --restart=Never --image=busybox --timeout=15s \
  -- nslookup github.com
```

> If the DNS test still fails, the root cause is that the k3d node container's
> `/etc/resolv.conf` points to the Docker bridge (`172.18.0.1`), which proxies
> to your host's `systemd-resolved`, which has no upstream nameservers after
> sleep. The most reliable fix for a dev laptop is to make CoreDNS forward
> directly to a public resolver instead of through this fragile chain:
>
> ```bash
> kubectl -n kube-system get configmap coredns -o yaml \
>   | sed 's|forward . /etc/resolv.conf|forward . 8.8.8.8 8.8.4.4|' \
>   | kubectl apply -f -
> kubectl -n kube-system rollout restart deployment/coredns
> kubectl -n kube-system rollout status deployment/coredns --timeout=60s
> ```
>
> This change does not persist across `k3d cluster delete` + recreate — k3d
> recreates the CoreDNS ConfigMap from scratch each time.

### Cilium stale `CiliumEndpoint` ownership after sleep

> **What happens**: k3d nodes are Docker containers. After a laptop sleep/wake,
> Docker's bridge network sometimes reassigns IPs to the containers. Each Cilium
> agent stamps its node IP into the `CiliumEndpoint` (CEP) objects it creates.
> After an IP shift, the agent on the new IP sees a CEP whose embedded `hostIP`
> belongs to a different address and refuses to take ownership.
>
> Symptom (`cilium status` and `kubectl -n kube-system logs -l k8s-app=cilium`):
> ```
> controller sync-to-k8s-ciliumendpoint (NNN) is failing since Xm (Yx):
> endpoint sync cannot take ownership of CEP that is not local
> ```
>
> Fix: delete the stale CEP so Cilium recreates it with the current node IP,
> then restart the Cilium DaemonSet so all CEPs are rebuilt cleanly.

```bash
# WHAT: Delete the stale CiliumEndpoint. Cilium recreates it immediately with
# the correct node IP. The pod itself is unaffected.
kubectl delete cep -n istio-system istio-cni-node-$(kubectl -n istio-system get pod -l k8s-app=istio-cni-node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | sed 's/istio-cni-node-//')

# WHAT: Restart the Cilium DaemonSet so it re-registers all endpoints cleanly.
kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=120s

cilium status   # should show 0 errors
```

> This error is cosmetic in isolation (the data-plane still enforces policy) but
> indicates stale cluster state and should be resolved before trusting
> `cilium status` for other diagnostics.

### Pod-to-pod connections time out inside the register namespace (`HBONE port 15008`)

> **What happens**: In Istio ambient mode, ztunnel wraps all pod-to-pod
> connections in an HBONE tunnel on TCP port 15008. Cilium sees port 15008 —
> not the application port. If a `default-deny-all` NetworkPolicy exists but no
> rule allows port 15008 intra-namespace, every pod-to-pod connection in the
> namespace silently times out.
>
> Symptoms: register CrashLoopBackOff with `"Irmin health check timed out"`,
> or any intra-namespace service call timing out.
>
> How to confirm:

```bash
kubectl -n istio-system logs -l app=ztunnel --since=10m \
  | grep -i "hbone\|15008\|network.?policy"
```

> Fix: ensure the `allow-hbone-intra-namespace` NetworkPolicy exists — it is
> committed in `infra/k8s/network-policy/register.yaml`:

```bash
kubectl -n register get networkpolicy allow-hbone-intra-namespace
# If missing, sync the mesh-policy ArgoCD Application:
argocd app sync mesh-policy
```

> **Why per-service rules are not enough**: in ambient mode Cilium enforces
> application-port rules only for *cross-namespace* traffic. Within a namespace,
> all traffic goes through the HBONE tunnel on 15008; intra-namespace access
> control is enforced by ztunnel (SPIFFE identity) and the waypoint (L7). See
> [ADR-INFRA-004](adr/ADR-INFRA-004.md) for the enforcement layer model.

---

## Glossary, tooling overview, and detailed reference

The full glossary, tooling overview, and repository layout are in the shared
operations reference:

- [GITOPS-OPERATIONS.md — Glossary](GITOPS-OPERATIONS.md#glossary)
- [GITOPS-OPERATIONS.md — Tooling overview](GITOPS-OPERATIONS.md#tooling-overview)
- [GITOPS-OPERATIONS.md — Repository layout](GITOPS-OPERATIONS.md#repository-layout)
