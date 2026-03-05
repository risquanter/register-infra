# Local k3d Bootstrap — Development Cluster with GitOps

Local development cluster using k3d (k3s-in-Docker). Identical Kubernetes API
to the Hetzner production path, but runs entirely on your machine.

- **Target**: fresh Debian workstation, no cloud account needed
- **Principle**: manually bootstrap the platform layer (k3d, Cilium, Istio, ArgoCD), then let GitOps manage everything above it
- **Time**: ~30 minutes from a fresh Debian install to a working GitOps cluster
- **Security posture**: defence-in-depth from the start — even on localhost

> **New to Kubernetes?** This guide explains every concept as it comes up.
> Skim the [Glossary](GITOPS-OPERATIONS.md#glossary) and
> [Tooling overview](GITOPS-OPERATIONS.md#tooling-overview) in the shared
> operations reference before starting — you do not need to memorise anything,
> but having seen the terms once makes the rest easier to follow.

---

## How this guide relates to the other docs

| Document | Purpose | When to use |
|---|---|---|
| **This guide** | Local dev cluster on your machine | Now — first step |
| [K3S-GITOPS-BOOTSTRAP.md](K3S-GITOPS-BOOTSTRAP.md) | Production deploy to Hetzner Cloud via Terraform | After local validation works |
| [GITOPS-OPERATIONS.md](GITOPS-OPERATIONS.md) | Shared GitOps reference (ArgoCD apps, workflow, glossary) | After bootstrap completes |
| [K3S-MANUAL-INSTALL.md](K3S-MANUAL-INSTALL.md) | Educational — every command explained imperatively | Reference / learning |
| [K8S-TESTING.md](K8S-TESTING.md) | Validation and CI pipeline | After cluster is running |
| [SECURITY-FLOW.md](SECURITY-FLOW.md) | Auth chain architecture | Reference during auth testing |

The Hetzner GitOps guide is **Hetzner-specific** — it uses Terraform with the
Hetzner Cloud provider, cloud-init, and Hetzner firewalls/networking. It remains
the production deployment path. This guide replaces only the "how do I get a
cluster" part. The GitOps layer (ArgoCD, App of Apps, Helm charts, policies) is
identical and portable between both.

---

## The bootstrap boundary

This is the most important concept in this guide. There are exactly two layers
in any GitOps-managed Kubernetes setup:

1. **Bootstrap layer** — things you install by hand, because the automation
   engine (ArgoCD) does not exist yet. You run shell commands for this.
2. **GitOps layer** — everything ArgoCD manages. You change these by editing
   files in git and pushing. ArgoCD detects the change and applies it to the
   cluster automatically.

The boundary between them is the moment you apply the "root App-of-Apps" — the
single ArgoCD Application that tells ArgoCD to watch your git repository.

```
╔═══════════════════════════════════════════════════════════════╗
║  GITOPS LAYER — ArgoCD manages these from your git repo      ║
║                                                               ║
║  Namespaces + Pod Security    ← infra/helm/namespaces/        ║
║  PostgreSQL                   ← infra/argocd/apps/postgresql  ║
║  Keycloak                     ← infra/argocd/apps/keycloak    ║
║  Istio auth policies          ← infra/k8s/istio/              ║
║  OPA policies                 ← infra/k8s/opa/                ║
║  Network policies             ← infra/k8s/network-policy/     ║
║  Register application         ← infra/helm/register/          ║
║                                                               ║
║  To change any of the above: edit file → commit → push        ║
╠═══════════════════════════════════════════════════════════════╣
║  BOOTSTRAP LAYER — manual, one-time                           ║
║                                                               ║
║  ① k3d cluster create                                         ║
║  ② Cilium (CNI — pod networking)                              ║
║  ③ Istio ambient (service mesh — mTLS + L7 policy)            ║
║  ④ cert-manager (TLS certificate automation)                  ║
║  ⑤ ArgoCD (GitOps engine)                                     ║
║  ⑥ Secrets bootstrap (SOPS + age — same as production)        ║
║  ⑦ Connect ArgoCD → git repo                                  ║
║  ⑧ Apply root App-of-Apps     ← the handoff moment            ║
║                                                               ║
║  Done once. After ⑧, you stop running kubectl/helm manually.  ║
╚═══════════════════════════════════════════════════════════════╝
```

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
> database with one command.

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
curl -L https://istio.io/downloadIstio | sh -
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
> Both the local and production guides use the same SOPS + age workflow.
> This is intentional — the encrypted secret files in `infra/secrets/` are
> the single source of truth for both environments.

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
> The flags below match the hardened k3s install from the manual guide:
> - flannel disabled (Cilium replaces it)
> - built-in network policy controller disabled (Cilium replaces it)
> - traefik disabled (not needed — Istio handles ingress)
> - servicelb disabled (not needed locally)
>
> **Security note**: k3d does not support the `--secrets-encryption` flag that
> bare k3s provides (etcd secret encryption at rest). This is acceptable for a
> local dev cluster where the "etcd" data lives inside a Docker container on
> your own machine. The production Hetzner guide enables this — see
> [K3S-GITOPS-BOOTSTRAP.md](K3S-GITOPS-BOOTSTRAP.md).

```bash
k3d cluster create register-dev \
  --k3s-arg "--flannel-backend=none@server:0" \
  --k3s-arg "--disable-network-policy@server:0" \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--disable=servicelb@server:0" \
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
istioctl install -y --set profile=ambient

# VERIFICATION: all Istio pods should be Running.
# You should see: istiod, istio-cni, and ztunnel pods.
kubectl -n istio-system get pods
```

> **mTLS is now active.** From this moment, ztunnel encrypts all traffic
> between pods in mesh-enrolled namespaces using mutual TLS. This is
> identical to what runs in production. There is no "dev mode" or "local
> mode" — ztunnel does not know it is running inside Docker. The encryption,
> certificate rotation, and SPIFFE identity assignment are all real.
>
> You can verify mTLS is working after workloads are deployed (§11 below
> includes verification commands). The key test: `istioctl ztunnel-config
> workloads` shows each pod's SPIFFE identity and whether its traffic is
> `HBONE` (encrypted) or `NONE` (plaintext).

---

## 4) Install cert-manager

> **What is cert-manager?** cert-manager automates TLS certificate lifecycle:
> requesting certificates, renewing them before expiry, and storing them as
> Kubernetes Secrets. It is needed before any HTTPS ingress is configured.
>
> For local development, cert-manager is mostly a placeholder — you are
> accessing services via `localhost` port-forwards. It becomes essential in
> production where you need real TLS certificates from Let's Encrypt or
> a private CA.

```bash
# WHAT: add the Jetstack Helm repository (Jetstack maintains cert-manager).
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

# WHAT: install cert-manager into its own namespace.
# --set crds.enabled=true: installs the CRDs that cert-manager needs
#   (Certificate, Issuer, ClusterIssuer etc.)
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true

# VERIFICATION: wait for cert-manager to be fully running.
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
```

---

## 5) Install ArgoCD

> **What happens here**: We install ArgoCD as a Helm chart. After this, the
> cluster has a GitOps engine, but it is not yet watching any repository.
> Steps 6–8 connect it.
>
> **Where ArgoCD lives and how it communicates**:
>
> ArgoCD runs as **pods inside the cluster**, in the `argocd` namespace. It
> is not an external service connecting from outside. It has four network
> relationships:
>
> | Connection | From → To | Encryption |
> |---|---|---|
> | **You → ArgoCD UI/API** | Your terminal → `kubectl port-forward` → ArgoCD pod | k8s API server's own TLS encrypts the port-forward tunnel |
> | **ArgoCD → GitHub** | ArgoCD repo-server → github.com | Standard HTTPS (ArgoCD is an HTTPS client) |
> | **ArgoCD → k8s API** | ArgoCD controller → k8s API server | ServiceAccount token over the API server's own TLS |
> | **ArgoCD internal** | server ↔ repo-server ↔ controller (pod-to-pod) | mTLS via ztunnel (after namespace enrollment below) |
>
> **ArgoCD is a high-value target — treat it accordingly.**
> ArgoCD holds the SOPS age private key (can decrypt every secret in git),
> the GitHub PAT (source code access), and its `application-controller` has
> broad cluster-wide RBAC (it can create/delete resources in any namespace).
> The `repo-server` component **executes arbitrary code**: it renders Helm
> templates, runs Kustomize, and evaluates config-management plugins. A
> supply-chain attack that poisons a Helm chart or git repo gets code
> execution inside `repo-server`.
>
> **Bootstrapping gap — ArgoCD starts outside the mesh.** The `helm install`
> below creates the `argocd` namespace with `--create-namespace` before the
> namespace chart or any ArgoCD Application exists. That namespace does not
> yet have the `istio.io/dataplane-mode: ambient` label, so ztunnel does
> not intercept ArgoCD's traffic. ArgoCD's internal pod-to-pod communication
> (server ↔ repo-server ↔ controller) is **plaintext on the pod network**.
>
> **This is a gap, not a design choice.** From a defense-in-depth / threat-
> modeling perspective, leaving a component with this attack surface outside
> the mesh is not acceptable — regardless of single-node vs. multi-node.
> The threat model is not "who can sniff the physical wire" but "what
> happens if a pod is compromised." A supply-chain attack (poisoned Helm
> chart, malicious git hook, RCE in a config plugin) gives an attacker a
> shell inside `repo-server`. Without the mesh, all three components talk
> over the pod network in plaintext. From inside `repo-server`, the attacker
> can:
>
> - **Sniff controller traffic** — `application-controller` continuously
>   sends sync status and resource manifests to `argocd-server`. Plaintext
>   means the attacker reads every resource being applied to the cluster,
>   including Secrets that flow through sync.
> - **Impersonate the controller** — without mTLS there are no cryptographic
>   identities. The attacker can send forged gRPC messages to `argocd-server`
>   (e.g. "mark this app as Synced" or "trigger a sync of a different app").
> - **Harvest tokens** — `argocd-server` exchanges ServiceAccount tokens and
>   session credentials over these internal connections. Plaintext means those
>   are readable.
>
> With the mesh enrolled (`kubectl label namespace argocd istio.io/dataplane-mode=ambient`):
>
> - Every pod gets a SPIFFE certificate. The controller and server mutually
>   authenticate before any byte is exchanged.
> - Even if `repo-server` is fully compromised, it cannot impersonate the
>   controller — it does not have the controller's private key.
> - mTLS + mesh policy limits what a compromised `repo-server` can reach,
>   reducing blast radius from "own the whole cluster" to "own
>   `repo-server`'s own ServiceAccount permissions."
>
> **The fix has two parts:**
>
> 1. **Imperative (closes the bootstrap window):** The `kubectl label`
>    command below the `helm install` enrolls the namespace immediately.
>    Ztunnel is a **node-level DaemonSet**, not a sidecar — it watches
>    namespace labels via the Kubernetes API and dynamically updates its
>    eBPF/iptables interception rules. Already-running ArgoCD pods are
>    picked up without a restart. Existing gRPC connections between
>    controller ↔ repo-server may briefly reset; ArgoCD reconnects
>    automatically.
>
> 2. **Declarative (prevents drift):** The `argocd` namespace is declared
>    in `infra/helm/namespaces/values.yaml` with `meshEnroll: true`. When
>    ArgoCD syncs the namespace chart for the first time (and every sync
>    after), it applies the Namespace resource with the ambient label.
>    ArgoCD's self-heal ensures the label cannot be removed without git
>    changing first — the mesh enrollment is under GitOps governance,
>    identical to every other namespace.
>
> Part 1 closes the ~60-second window between `helm install` and ArgoCD's
> first sync. Part 2 makes the enrollment permanent and drift-proof.
>
> **Understanding `server.insecure=true`**: ArgoCD has a built-in option to
> add TLS to its own HTTP listener (the web UI / API). Setting
> `server.insecure=true` disables this. The word "insecure" is misleading —
> it means "ArgoCD's own process does not do TLS", not "unencrypted to the
> outside world". With ArgoCD now inside the mesh, ztunnel provides mTLS
> between pods, so ArgoCD's own TLS listener would be redundant
> double-encryption. Access from your machine is via `kubectl port-forward`,
> which is encrypted by the k8s API server's own TLS.

```bash
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=ClusterIP

# VERIFICATION: wait for all three core ArgoCD components.
# - argocd-server: the API + web UI
# - argocd-repo-server: clones git repos and renders Helm charts
# - argocd-application-controller: watches for changes and syncs
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s
# application-controller is a StatefulSet since ArgoCD v2.8
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s
```

```bash
# SECURITY: enroll the argocd namespace in the Istio ambient mesh.
# This is Part 1 of the fix — closes the bootstrap window immediately.
# WHY: ArgoCD is a high-value target (cluster-wide RBAC, secret access,
#   code execution in repo-server). Without this label, ArgoCD's internal
#   pod-to-pod traffic is plaintext.
# HOW IT WORKS: ztunnel is a node-level DaemonSet, not a sidecar. It watches
#   for namespace label changes via the k8s API and dynamically updates its
#   eBPF/iptables interception rules. The already-running ArgoCD pods are
#   picked up WITHOUT a restart — this is the key advantage of ambient mode.
# Part 2 of the fix: the namespace chart (infra/helm/namespaces/values.yaml)
#   declares argocd with meshEnroll: true. Once ArgoCD syncs that chart,
#   the label is under GitOps governance and cannot drift.
kubectl label namespace argocd istio.io/dataplane-mode=ambient

# VERIFICATION: confirm the label is set.
kubectl get namespace argocd --show-labels | grep dataplane-mode
```

### 5.1 Log in and rotate admin password

> **Why rotate?** ArgoCD generates a random admin password on first install and
> stores it as a Kubernetes Secret. This password should be rotated immediately
> and the auto-generated secret deleted. This is a standard security practice:
> auto-generated bootstrap credentials should never persist.

```bash
# WHAT: port-forward makes the ArgoCD API available at localhost:9090.
# This creates a tunnel from your machine into the cluster. Nothing is exposed
# to the network — only your local machine can reach it.
kubectl -n argocd port-forward svc/argocd-server 9090:80 &
PF_PID=$!
sleep 3

# WHAT: retrieve the auto-generated admin password from the cluster.
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

argocd login localhost:9090 \
  --username admin \
  --password "$ARGOCD_PASS" \
  --insecure   # "insecure" here means "skip TLS check to the ArgoCD server"
               # — we are connecting via plain HTTP through the port-forward,
               #   not over the network. This is expected.

# WHAT: choose a new password and rotate immediately.
# SECURITY: read -s hides your input from the terminal (no shoulder surfing).
read -r -s -p "New ArgoCD admin password: " NEW_PASS; echo
argocd account update-password \
  --account admin \
  --current-password "$ARGOCD_PASS" \
  --new-password "$NEW_PASS"

# WHAT: clear secrets from shell memory and delete the bootstrap secret.
# SECURITY: unset removes the variable from memory. Deleting the Secret removes
#   the auto-generated password from the cluster. Only your new password exists.
unset ARGOCD_PASS NEW_PASS
kubectl -n argocd delete secret argocd-initial-admin-secret

kill $PF_PID 2>/dev/null || true
```

---

## 6) Secrets bootstrap (SOPS + age)

> **What is this about?** The ArgoCD Application manifests for PostgreSQL and
> Keycloak reference Kubernetes Secrets by name (e.g. `postgres-credentials`).
> When ArgoCD tries to deploy PostgreSQL, it expects this Secret to already
> exist so it can read the database password from it.
>
> We use the **same SOPS + age workflow** as the production Hetzner guide.
> The encrypted files in `infra/secrets/` are the single source of truth —
> both environments decrypt from the same files. This eliminates secret name
> drift and ensures the SOPS workflow is tested locally before production.
>
> **On first bootstrap** you generate the age keypair and create the encrypted
> files. On subsequent cluster recreations (`k3d cluster delete` + re-create),
> the keypair and encrypted files already exist — skip to "Decrypt and apply".

### 6.1 Generate age keypair (first time only)

> **Skip this** if you already have a keypair at `~/.config/sops/age/keys.txt`
> (e.g. from the production guide).

```bash
# WHAT: create an age keypair. The private key is written to the file.
#   The public key is printed to stdout (and stored in the file's header comment).
# SECURITY: this private key unlocks ALL secrets. Back it up immediately.
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt

# NOTE: copy the public key from the output — it looks like:
#   age1xxxxxxxxxxxxxxxxxxxxxxxxx
# You will need it for .sops.yaml below.
```

### 6.2 Configure SOPS (first time only)

> **Skip this** if `.sops.yaml` in the repo root already has your public key.

```bash
# WHAT: tell SOPS which encryption key to use for files matching a path pattern.
# HOW IT WORKS: when you run `sops infra/secrets/foo.yaml`, SOPS checks
#   .sops.yaml, finds the matching path_regex, and encrypts with the specified
#   age public key. Decryption uses the private key at ~/.config/sops/age/keys.txt.
cat > .sops.yaml <<YAML
creation_rules:
  - path_regex: infra/secrets/.*\.yaml$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxx   # ← replace with YOUR public key
YAML
```

### 6.3 Create and encrypt secret files (first time only)

> **Skip this** if `infra/secrets/postgres.enc.yaml` and
> `infra/secrets/keycloak.enc.yaml` already exist (from a previous bootstrap
> or from the production guide).

```bash
# WHAT: sops opens your $EDITOR with a plain YAML file.
#   Write the secret values in plain text, save and close.
#   SOPS encrypts the values on exit — keys stay human-readable.
sops infra/secrets/postgres.enc.yaml
```

Example content (plain text — SOPS encrypts this on save):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: infra
type: Opaque
stringData:
  postgres-password: "POSTGRES_SUPERUSER_PASSWORD"      # PostgreSQL superuser (postgres)
  keycloak-db-password: "KEYCLOAK_DB_USER_PASSWORD"      # Keycloak's dedicated DB user — distinct from the superuser and from the Keycloak admin UI password
```

```bash
sops infra/secrets/keycloak.enc.yaml
```

Example content:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-credentials
  namespace: infra
type: Opaque
stringData:
  admin-password: "KEYCLOAK_ADMIN_UI_PASSWORD"           # Keycloak web admin console — unrelated to the database passwords above
```

```bash
# VERIFICATION: view the encrypted file — values are ciphertext, keys are plain.
cat infra/secrets/postgres.enc.yaml

# Safe to commit — ciphertext is meaningless without the age private key.
git add .sops.yaml infra/secrets/
git commit -m "chore: add SOPS config and encrypted secrets"
git push
```

### 6.4 Install SOPS decryption key into the cluster

> **What is this?** ArgoCD needs the age private key to decrypt
> `infra/secrets/*.enc.yaml` at sync time. We store it as a Kubernetes Secret
> in the `argocd` namespace where the SOPS plugin can read it.
>
> **Identical to production** — the Hetzner guide does the same step in §4.2.
>
> **What `--secrets-encryption` does and why k3d lacks it:**
>
> On a real k3s node, you can pass `--secrets-encryption` in the server start
> flags. This tells k3s to encrypt every Kubernetes `Secret` object with
> AES-CBC before writing it to etcd (the key-value store that persists all
> cluster state). The encryption key is derived from a key file on the node's
> disk. Without this flag, Kubernetes Secrets are stored as **base64 in
> plaintext** in etcd — not encrypted, just encoded. Anyone who can read the
> etcd data file on the node's filesystem can extract every Secret in the
> cluster with a simple base64 decode.
>
> k3d does not expose this flag because k3d itself is a wrapper that starts k3s
> inside a Docker container. The k3d CLI abstracts the k3s server arguments, and
> `--secrets-encryption` is not one of the arguments k3d passes through. Even
> if you attempted to inject it, k3d's container lifecycle management would
> not handle the required key file bootstrap correctly.
>
> **Why this is acceptable locally, and what actually protects the secret here:**
>
> The threat that `--secrets-encryption` defends against is: *an attacker gains
> read access to the etcd data files on the node's disk*. On a Hetzner VM with
> a public IP, there are realistic paths to this: a misconfigured API server,
> a stolen disk image, or physical access to the datacenter. On your local
> machine, the etcd data lives inside a Docker container's overlay filesystem —
> a directory on your own disk, not exposed to any network.
>
> The relevant threat model locally is not "someone reads the etcd data files"
> but "someone has access to my machine". If your machine is compromised to the
> point where an attacker can reach the Docker container's filesystem, they
> already have broader access than any single Kubernetes Secret provides.
>
> What does protect the age key here:
>
> | Layer | What it does |
> |---|---|
> | SOPS + age encryption in git | The key itself is never in git. The *secrets it decrypts* are encrypted in git. |
> | Kubernetes RBAC | Only the `argocd` namespace ServiceAccounts can read `sops-age-key`. Pods in `register` or `infra` cannot. |
> | NetworkPolicy (Cilium) | Pod-to-pod traffic is restricted. No pod can query the Kubernetes API directly unless its ServiceAccount is explicitly granted it. |
> | Istio mTLS | internal argocd pod-to-pod traffic (including when the SOPS plugin reads the key) is mTLS encrypted between authenticated workloads. |
>
> **The accepted risk** is: if someone has root on your machine while the cluster
> is running, they can reach the Docker container, find the etcd data directory,
> and extract the base64-encoded `sops-age-key` Secret. This is an accepted
> local dev risk because: (a) the local cluster holds dev-only throwaway
> credentials, not production values, and (b) machine compromise at that level
> is outside the scope of any Kubernetes security control. The production Hetzner
> guide mitigates this with `--secrets-encryption` + Hetzner's disk encryption
> option — see [K3S-GITOPS-BOOTSTRAP.md §7](K3S-GITOPS-BOOTSTRAP.md#7-security-boundaries-and-accepted-risks).

```bash
kubectl -n argocd create secret generic sops-age-key \
  --from-file=keys.txt="$HOME/.config/sops/age/keys.txt" \
  --dry-run=client -o yaml | kubectl apply -f -

# VERIFICATION: the secret should exist.
kubectl -n argocd get secret sops-age-key
```

### 6.5 Decrypt and apply secrets to the cluster

> **This is the step you repeat** (along with §6.4) on every cluster
> recreation. Steps 6.1–6.3 are one-time setup.

```bash
# WHAT: pre-create the infra namespace.
# WHY: the Secrets applied in the next step must exist before ArgoCD syncs
#   the PostgreSQL and Keycloak Applications — those workloads read the
#   Secrets at startup and will fail if they are absent. The namespace must
#   exist before Secrets can be created inside it. ArgoCD will later adopt
#   and manage this namespace via the namespaces Helm chart; creating it here
#   first is simply the required ordering.
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -

# WHAT: decrypt the SOPS files and apply them as Kubernetes Secrets.
# HOW IT WORKS: `sops -d` decrypts to stdout using the age key at
#   ~/.config/sops/age/keys.txt. The output is plain YAML that kubectl applies.
# SECURITY: the decrypted values only exist in the pipe — they are not written
#   to disk or stored in shell variables.
sops -d infra/secrets/postgres.enc.yaml | kubectl apply -f -
sops -d infra/secrets/keycloak.enc.yaml | kubectl apply -f -

# VERIFICATION: secrets exist with the expected keys.
kubectl -n infra get secret postgres-credentials -o jsonpath='{.data}' | jq keys
kubectl -n infra get secret keycloak-credentials -o jsonpath='{.data}' | jq keys
```

---

## 7) Connect ArgoCD to your git repo

> **What are we doing?** Two things:
> 1. Updating the ArgoCD Application YAML files in the repo to point to YOUR
>    GitHub URL (they ship with `<org>` placeholders)
> 2. Telling ArgoCD CLI "here is the git repo you should watch"
>
> **GitOps principle — single source of truth**: the git repository is the
> authoritative declaration of what should run in the cluster. ArgoCD never
> applies anything that is not in git. If you change something in the cluster
> manually, ArgoCD reverts it (self-healing). If you add a new file to git,
> ArgoCD applies it (reconciliation). This means git history IS your audit
> trail — every cluster change is a commit with an author and timestamp.

### 7.1 Update Application manifests with your repo URL

```bash
# WHAT: replace the placeholder <org> with your actual GitHub username/org
# in all ArgoCD Application files that reference this repository.
# NOTE: files that reference external chart repos (e.g. postgresql.yaml
# pointing at charts.bitnami.com) do not need this change.
cd /path/to/register-infra   # cd to the repo root

REPO_URL="https://github.com/<your-user>/register-infra"   # ← edit this

sed -i "s|https://github.com/<org>/register-infra|${REPO_URL}|g" \
  infra/argocd/apps/root.yaml \
  infra/argocd/apps/namespaces.yaml \
  infra/argocd/apps/register.yaml \
  infra/argocd/apps/mesh-policy.yaml

# WHAT: commit this change so ArgoCD sees the correct URLs when it clones.
# BEST PRACTICE: in a team workflow, this would be a PR with review.
git add infra/argocd/apps/
git commit -m "chore: set actual repo URL in ArgoCD Applications"
git push
```

### 7.2 Register the repo with ArgoCD

> **Why do we need to "register" the repo?** ArgoCD maintains an internal list
> of trusted repositories. This is a security feature — it prevents someone
> from crafting an Application manifest that points to a malicious repo.
> The `argocd repo add` command adds your repo to this allow list.

```bash
kubectl -n argocd port-forward svc/argocd-server 9090:80 &
PF_PID=$!
sleep 3

# WHAT: register the repository with ArgoCD.
# --insecure: skips TLS certificate verification TO THE ARGOCD SERVER (which
#   is on localhost via port-forward, so there is no TLS). This does NOT affect
#   the security of the connection to GitHub (which uses HTTPS normally).
argocd repo add "$REPO_URL" --insecure

# For a PRIVATE repository, you must provide credentials:
# read -r -p "GitHub username: " GH_USER
# read -r -s -p "GitHub PAT (repo read): " GH_PAT; echo
# argocd repo add "$REPO_URL" --username "$GH_USER" --password "$GH_PAT" --insecure
# unset GH_USER GH_PAT

kill $PF_PID 2>/dev/null || true
```

---

## 8) Apply root App-of-Apps — the handoff moment

> **This is the single most important command in the entire guide.**
>
> The "App of Apps" pattern is an ArgoCD convention:
> - You create ONE ArgoCD Application (the "root") that points to a directory
>   in your git repo (`infra/argocd/apps/`)
> - That directory contains more Application YAML files (one per service)
> - ArgoCD reads the root, discovers the child Applications, and deploys them
> - Adding a new service to the cluster = adding one YAML file to that
>   directory and pushing to git
>
> After this command, you stop running `kubectl apply` or `helm install`
> for anything in the GitOps layer.

```bash
# WHAT: this is the LAST kubectl apply you run.
# After this, ArgoCD manages everything declared in infra/argocd/apps/.
kubectl apply -f infra/argocd/apps/root.yaml
```

ArgoCD will now discover and deploy these Applications automatically:

| ArgoCD Application | What it deploys | Source location |
|---|---|---|
| `namespaces` | `argocd`, `register`, `infra`, `observability` namespaces with Pod Security labels, mesh enrollment, and LimitRanges | `infra/helm/namespaces/` |
| `postgresql` | PostgreSQL database in `infra` namespace | Bitnami Helm chart (remote) |
| `keycloak` | Keycloak identity provider in `infra` namespace | Bitnami Helm chart (remote) |
| `opa` | OPA ext_authz server (2 replicas + PDB) in `register` namespace | `infra/helm/opa/` |
| `mesh-policy` | Istio JWT/auth, PeerAuthentication, NetworkPolicies, RBAC | `infra/k8s/` (raw YAML) |
| `register` | Application Deployment in `register` namespace | `infra/helm/register/` |

> For the detailed reference (AppProject scoping, security policies, repo
> layout), see [GITOPS-OPERATIONS.md — What ArgoCD manages](GITOPS-OPERATIONS.md#what-argocd-manages).

### 8.1 Watch the sync

```bash
kubectl -n argocd port-forward svc/argocd-server 9090:80 &
PF_PID=$!
sleep 3

# WHAT: list all ArgoCD Applications and their sync/health status.
# "Synced" + "Healthy" means the cluster matches git and the pods are running.
argocd app list

# WHAT: wait for each app to become healthy.
# PostgreSQL and Keycloak are heavier — allow up to 5 minutes.
argocd app wait namespaces --health --timeout 60
argocd app wait postgresql --health --timeout 300
argocd app wait keycloak --health --timeout 300
argocd app wait mesh-policy --health --timeout 60

kill $PF_PID 2>/dev/null || true
```

### 8.2 Browse the ArgoCD UI

```bash
# WHAT: open the ArgoCD web dashboard.
kubectl -n argocd port-forward svc/argocd-server 9090:80
# Open http://localhost:9090 in your browser.
# Log in with username "admin" and the password you set in §5.1.
```

> The ArgoCD UI shows a visual graph of every Application, its sync status
> (does the cluster match git?), and health status (are the pods running?).
> This is your primary feedback loop during development. If something breaks
> after a git push, the UI shows exactly which resource failed and why.

---

## 9) Install the Istio waypoint

> **What is a waypoint?** In Istio ambient mode, there are two proxy layers:
> - **ztunnel** (L4): handles mTLS encryption for all pod traffic. Already
>   running from §3. Transparent — no policy decisions, just encryption.
> - **Waypoint proxy** (L7): a per-namespace Envoy proxy that inspects HTTP
>   headers, validates JWTs, and enforces authorization policies.
>
> The auth chain described in [SECURITY-FLOW.md](SECURITY-FLOW.md) runs
> entirely in the waypoint: JWT validation, header stripping, OPA ext_authz.
> Without a waypoint, Istio only provides mTLS — no L7 policy enforcement.
>
> **Why is this not in the GitOps layer?** The waypoint is an Istio runtime
> object that istioctl creates as a Gateway resource. It could be declared as
> static YAML in git, but `istioctl waypoint apply` is the officially supported
> method and handles internal wiring that is complex to replicate manually.
> This is an accepted imperative step alongside the bootstrap layer.

```bash
# PREREQUISITE: the register namespace must exist (created by the namespaces
# Application in step 8). Verify:
kubectl get ns register --show-labels | grep ambient

# WHAT: install a waypoint proxy for the register namespace.
# --enroll-namespace: tells all pods in the namespace to route through this
#   waypoint for L7 policy evaluation.
istioctl waypoint apply -n register --enroll-namespace

# VERIFICATION: a Gateway object should exist in the register namespace.
kubectl -n register get gateway
```

---

## 10) Configure Keycloak

> **What is Keycloak?** Keycloak is an open-source identity provider (IdP).
> It handles user login, issues JWTs (JSON Web Tokens), and exposes a JWKS
> (JSON Web Key Set) endpoint that Istio uses to validate token signatures
> without calling Keycloak on every request.
>
> Keycloak was deployed by ArgoCD in step 8. Now we configure it: create a
> "realm" (a tenant), register client applications, and create test users.
> This configuration happens through Keycloak's admin UI — it is stored in
> PostgreSQL, not in git.

```bash
# WHAT: forward Keycloak's port so you can access the admin UI from your browser.
kubectl -n infra port-forward svc/keycloak 8081:80
# Open http://localhost:8081 in your browser.
```

Configure in the admin UI:

1. **Realm**: `register` (a realm is an isolated tenant — like a separate
   user database. The default "master" realm is for Keycloak admin only.)
2. **Client: `register-api`** — confidential client, service account enabled
   (for server-to-server auth)
3. **Client: `register-web`** — public client, PKCE enabled (for browser-based
   login. PKCE is a security extension to OAuth2 that prevents authorization
   code interception.)
4. **User**: create a test user with a password
5. **Realm roles**: create roles that OPA will evaluate:
   - `analyst` — can read data
   - `editor` — can read and write data
   - `team_admin` — can manage team settings and cache
6. **Protocol mappers**: ensure the JWT contains the claims that the mesh
   and OPA expect:
   - `sub` claim (user ID) — Istio maps this to `x-user-id`
   - `email` claim — mapped to `x-user-email`
   - `realm_access.roles` — OPA evaluates these for role-based gating

Verify OIDC is working:

```bash
# WHAT: check the OIDC discovery endpoint. This is the URL that Istio's
#   RequestAuthentication uses as "issuer" to find the JWKS endpoint.
curl -s http://localhost:8081/realms/register/.well-known/openid-configuration | jq .issuer
# Expected: "http://keycloak.infra.svc.cluster.local/realms/register"

# WHAT: check the JWKS endpoint — the public keys Istio caches for JWT validation.
curl -s http://localhost:8081/realms/register/protocol/openid-connect/certs | jq .keys[0].kid

# WHAT: get a test JWT by logging in as the test user.
# This simulates what happens when a user logs in via the application.
curl -s -X POST "http://localhost:8081/realms/register/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=register-web" \
  -d "username=<test-user>" \
  -d "password=<test-password>" \
  | jq -r .access_token
```

---

## 11) Test the authentication chain

> **What are we testing?** The security invariants from
> [SECURITY-FLOW.md](SECURITY-FLOW.md). These tests verify that the mesh
> rejects invalid tokens, strips forged headers, and blocks direct pod access.
> Run them after every Istio policy change.

```bash
# SETUP: get a valid JWT from Keycloak (use your test user from §10).
TOKEN=$(curl -s -X POST \
  "http://localhost:8081/realms/register/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=register-web" \
  -d "username=<test-user>" \
  -d "password=<test-password>" \
  | jq -r .access_token)
```

### T2: invalid JWT must be rejected (401)

```bash
# WHAT: send a garbage JWT to the cluster.
# WHY: the waypoint's RequestAuthentication should validate the signature
#   against Keycloak's JWKS and reject this. If it returns 200, the policy
#   is broken.
curl -si -H "Authorization: Bearer this.is.not.a.valid.jwt" \
  http://localhost:8080/health \
  | head -1
# Expected: HTTP/1.1 401 Unauthorized
```

### T3: forged identity header must not bypass auth (401)

```bash
# WHAT: send a request with a forged x-user-id header but no JWT.
# WHY: the EnvoyFilter strips this header, and the AuthorizationPolicy requires
#   a valid JWT. The app should never see a forged x-user-id.
curl -si -H "x-user-id: 00000000-0000-0000-0000-000000000001" \
  http://localhost:8080/health \
  | head -1
# Expected: HTTP/1.1 401 Unauthorized
```

### Valid request with real JWT

```bash
# WHAT: send a request with a real JWT from Keycloak.
# WHY: the waypoint validates it, strips any forged headers, injects the real
#   x-user-id from the JWT sub claim, and forwards to the app.
curl -si -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/health \
  | head -1
# Expected: HTTP/1.1 200 OK (once the register app is deployed and running)
```

### T1: direct pod access must be blocked

```bash
# WHAT: try to reach the app pod directly, bypassing the waypoint.
# WHY: Cilium's NetworkPolicy should block all ingress to the app pod except
#   from the waypoint. This is the network-layer enforcement that prevents
#   forged headers even if Istio is misconfigured.
POD_IP=$(kubectl -n register get pods \
  -l app.kubernetes.io/name=register \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

if [ -n "$POD_IP" ]; then
  kubectl run curltest --rm -i --restart=Never \
    --image=curlimages/curl -- \
    curl -s --connect-timeout 5 "http://${POD_IP}:8080/health" \
    && echo "FAIL: direct pod access succeeded — NetworkPolicy not enforced" \
    || echo "PASS: direct pod access blocked"
else
  echo "SKIP: no register pod found yet"
fi
```

### Verify mTLS is active (encryption check)

> **Why this matters**: mTLS is the foundation of the security architecture.
> Every other security control (JWT validation, header stripping, OPA policy)
> runs on top of the encrypted mTLS channel. If mTLS is not active, an
> attacker on the same network could sniff pod-to-pod traffic in plain text.
>
> These commands prove that the local k3d cluster has the same encryption
> guarantees as production.

```bash
# WHAT: list all workloads known to ztunnel and their encryption status.
# LOOK FOR: "HBONE" in the protocol column means traffic is encrypted via mTLS.
#   "NONE" or "TCP" means plaintext — that workload is NOT in the mesh.
# WHY: this is the definitive proof that ztunnel is intercepting and encrypting
#   traffic for your pods.
istioctl ztunnel-config workloads

# WHAT: check which namespaces are enrolled in the mesh.
# Enrolled namespaces have "istio.io/dataplane-mode=ambient" label.
# All pods in enrolled namespaces get mTLS automatically.
kubectl get ns --show-labels | grep ambient

# WHAT: verify a specific pod has a SPIFFE identity.
# A SPIFFE identity (like spiffe://cluster.local/ns/register/sa/register)
# means ztunnel has issued a cryptographic certificate to this pod.
# Without a SPIFFE identity, mTLS cannot happen.
istioctl ztunnel-config workloads --namespace register

# WHAT: proxy-status shows the connection between istiod (control plane) and
# every ztunnel instance. "SYNCED" means ztunnel is receiving configuration.
# If this shows "NOT CONNECTED", mTLS policies are not being applied.
istioctl proxy-status
```

> **What does "identical to production" mean concretely?**
> - Same ztunnel version, same eBPF interception, same certificate rotation
> - Same SPIFFE identity format (`spiffe://cluster.local/ns/<ns>/sa/<sa>`)
> - Same HBONE protocol (HTTP/2-based mTLS tunnel)
> - Same `istio.io/dataplane-mode: ambient` namespace labels
> - If a test passes here, it will pass on the Hetzner cluster

---

## 12) The GitOps workflow — making changes

The day-to-day GitOps workflow (editing files, committing, previewing changes)
is documented in [GITOPS-OPERATIONS.md — Making changes](GITOPS-OPERATIONS.md#making-changes--the-gitops-workflow).
The workflow is identical regardless of whether the cluster is local or
production.

The automated deploy loop (CI → GHCR → Image Updater → ArgoCD) is also
described there at [The automated deploy loop](GITOPS-OPERATIONS.md#the-automated-deploy-loop).

---

## 13) Loading your application image (no GHCR needed locally)

> **What is this about?** In production, your CI pipeline builds a Docker
> image, pushes it to GHCR (GitHub Container Registry), and ArgoCD Image
> Updater detects the new version. Locally, you skip the registry entirely —
> `k3d image import` loads the image directly into the cluster.

```bash
# WHAT: build your application Docker image on your host machine.
docker build -t ghcr.io/<org>/<image>:dev .

# WHAT: import the image into k3d. This makes it available to pods without
# pulling from any registry.
k3d image import ghcr.io/<org>/<image>:dev -c register-dev
```

Update `infra/helm/register/values.yaml` to use the `dev` tag:

```yaml
image:
  repository: ghcr.io/<org>/<image>
  tag: dev
  pullPolicy: IfNotPresent
```

Commit and push — ArgoCD deploys it.

---

## 14) Teardown

```bash
# WHAT: delete the entire k3d cluster. All pods, data, and secrets are destroyed.
k3d cluster delete register-dev
```

To recreate, run this guide from §1 (prerequisites are already installed).
Because all GitOps state is in git, recreating a cluster from scratch takes
only the bootstrap steps — ArgoCD redeploys everything automatically.

---

## 15) Next steps — graduating to production

When the auth chain, GitOps workflow, and application all work locally:

1. **Get a Hetzner Cloud account** (or any managed Kubernetes provider)
2. Follow [K3S-GITOPS-BOOTSTRAP.md](K3S-GITOPS-BOOTSTRAP.md) — Terraform
   provisions the VM and installs the same bootstrap layer (Cilium, Istio,
   ArgoCD) that you installed manually here
3. Point ArgoCD at the **same git repo** — it deploys the identical stack
4. The only things that change: VM provisioning (Terraform) and secret
   encryption at rest (`--secrets-encryption` on k3s). Secrets are already
   managed with SOPS + age in both environments

Your Helm charts, ArgoCD Applications, Istio policies, OPA rules, and
NetworkPolicies are **portable as-is** — they do not know or care whether
the cluster is k3d on your laptop or k3s on a Hetzner VM.

---

## Security considerations for local development

> **Best practice frameworks referenced**: these notes follow the principles
> from the NSA/CISA Kubernetes Hardening Guide and CIS Kubernetes Benchmark,
> adapted for a local dev context.

| Area | Production (Hetzner guide) | Local dev (this guide) | Why the difference is acceptable |
|---|---|---|---|
| Secrets at rest | k3s `--secrets-encryption` (AES-CBC) | Not available in k3d | Data is in a Docker container on your own machine |
| Secrets in git | SOPS + age encryption | SOPS + age encryption (same) | Same encrypted files, same workflow |
| Network perimeter | Hetzner firewall, CIDR-restricted SSH | Docker bridge network | No public exposure |
| Supply chain | GHCR + digest pinning | `k3d image import` | No registry in the loop |
| Pod Security | Restricted PSS (same) | Restricted PSS (same) | Same labels, same enforcement |
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

---

## Glossary, tooling overview, and detailed reference

The full glossary (Kubernetes concepts, networking, authentication, GitOps),
tooling overview, and repository layout are in the shared operations reference:

- [GITOPS-OPERATIONS.md — Glossary](GITOPS-OPERATIONS.md#glossary)
- [GITOPS-OPERATIONS.md — Tooling overview](GITOPS-OPERATIONS.md#tooling-overview)
- [GITOPS-OPERATIONS.md — Repository layout](GITOPS-OPERATIONS.md#repository-layout)

> **Tip for new Kubernetes users**: skim the glossary in the shared doc before
> starting this guide. You do not need to memorise anything, but having seen
> the terms once makes the rest easier to follow.
