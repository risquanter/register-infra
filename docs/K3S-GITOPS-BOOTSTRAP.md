# k3s GitOps Bootstrap — Hetzner Cloud Production Deployment

Declarative, reproducible cluster provisioning for Hetzner Cloud using
Terraform, Cilium, Istio ambient, and ArgoCD.

- **Target**: single-node k3s on a Hetzner Cloud VM (adaptable to any bare Linux VM)
- **Principle**: every cluster state change is a `git push` or a `terraform apply` — no imperative commands after bootstrap
- **Secret strategy**: SOPS + age — secrets encrypted in git, no external secret manager
- **GitOps engine**: ArgoCD with App of Apps pattern

> **New to Kubernetes?** Start with the
> [LOCAL-K3D-BOOTSTRAP.md](LOCAL-K3D-BOOTSTRAP.md) guide first — it runs the
> identical GitOps stack on your machine without needing a cloud account, and
> explains every concept in tutorial style. Come back here when you are ready
> to deploy to a remote server.

---

## How this guide relates to the other docs

| Document | Purpose | When to use |
|---|---|---|
| [LOCAL-K3D-BOOTSTRAP.md](LOCAL-K3D-BOOTSTRAP.md) | Local dev cluster on your machine | First step — learn and validate |
| **This guide** | Production deploy to Hetzner Cloud via Terraform | After local validation works |
| [K3S-MANUAL-INSTALL.md](K3S-MANUAL-INSTALL.md) | Educational — every command explained imperatively | Reference / learning |
| [K8S-TESTING.md](K8S-TESTING.md) | Validation and CI pipeline | After cluster is running |
| [SECURITY-FLOW.md](SECURITY-FLOW.md) | Auth chain architecture | Reference during auth testing |

> **What is Hetzner-specific here?** Terraform provider configuration,
> cloud-init, Hetzner firewall rules, and VM provisioning. Everything in the
> GitOps layer (ArgoCD Applications, Helm charts, Istio policies, OPA rules,
> NetworkPolicies) is **portable** — identical between this guide and the local
> k3d guide.

---

## The bootstrap boundary

> **This concept is explained fully in the local guide.** Here is the summary.

There are exactly two layers:

1. **Bootstrap layer** — Terraform provisions the VM and installs the platform
   (k3s, Cilium, Istio, cert-manager, ArgoCD) via the Helm provider. This is
   run once by the operator.
2. **GitOps layer** — ArgoCD manages everything above the platform. Changes
   happen through git commits. ArgoCD detects and applies them automatically.

The boundary is the moment you `kubectl apply -f infra/argocd/apps/root.yaml`.

```
╔═══════════════════════════════════════════════════════════════╗
║  GITOPS LAYER — ArgoCD manages from git                      ║
║                                                               ║
║  Namespaces + Pod Security    ← infra/helm/namespaces/        ║
║  PostgreSQL / Keycloak        ← infra/argocd/apps/            ║
║  Istio auth policies          ← infra/k8s/istio/              ║
║  OPA policies                 ← infra/k8s/opa/                ║
║  NetworkPolicies              ← infra/k8s/network-policy/     ║
║  Register application         ← infra/helm/register/          ║
╠═══════════════════════════════════════════════════════════════╣
║  BOOTSTRAP LAYER — Terraform + one-time manual steps          ║
║                                                               ║
║  Terraform: Hetzner VM, firewall, network, cloud-init         ║
║  Terraform Helm provider: Cilium, Istio, cert-manager, ArgoCD ║
║  Manual: password rotation, SOPS key, git repo, root app      ║
╚═══════════════════════════════════════════════════════════════╝
```

---

## Repository layout

> **Why this layout?** ArgoCD watches specific paths in the repo. Organizing
> by tool (Terraform, Helm, ArgoCD apps, raw k8s manifests) keeps the concerns
> separated and makes ArgoCD path filters work cleanly.

```
infra/
  terraform/              # VM provisioning + bootstrap Helm releases
    main.tf               #   all Terraform resources (network, firewall, VM, Helm)
    variables.tf          #   input variables with defaults
    outputs.tf            #   output values (server IP etc.)
    cloud-init.yaml       #   first-boot script: installs k3s
  helm/
    register/             # application Helm chart
      Chart.yaml
      values.yaml
      templates/
    namespaces/           # namespace declarations with PSS + mesh labels
      Chart.yaml
      values.yaml
      values-infra-no-mesh.yaml   # fallback: removes infra from mesh
      templates/
  argocd/
    apps/                 # App of Apps directory — ArgoCD watches this
      root.yaml           #   the single root Application
      namespaces.yaml     #   namespace chart Application
      postgresql.yaml     #   PostgreSQL Application (Bitnami remote chart)
      keycloak.yaml       #   Keycloak Application (Bitnami remote chart)
      register.yaml       #   Application Deployment + Image Updater annotations
      mesh-policy.yaml    #   Istio/OPA/NetworkPolicy manifests
  k8s/
    istio/                # RequestAuthentication, AuthorizationPolicy, EnvoyFilter
    network-policy/       # Cilium NetworkPolicies (default-deny + allow rules)
    opa/                  # OPA deployment + ext-authz EnvoyFilter
  secrets/                # SOPS-encrypted Secret manifests (committed safely)
  opa/
    policies/             # Rego source files
.sops.yaml                # SOPS config (age recipient public key)
```

---

## 0) Workstation setup

> **These tools run on YOUR machine**, not on the cluster. They talk to Hetzner
> Cloud (hcloud, Terraform) and to the Kubernetes API (kubectl, ArgoCD CLI).

> **Security note — `curl | bash` pattern**: tool installers below use the
> convenience `curl <url> | bash` pattern. For CI/production pipelines, prefer
> pinned binary downloads with checksum verification (shown where available).

```bash
# ── Terraform ── infrastructure provisioner
# WHAT: tfswitch lets you pin Terraform versions per-project, preventing
#   version drift between team members.
# WHY: Terraform 1.10+ is required for provider features used in main.tf.
curl -fsSL https://tfswitch.warrensbox.com/install.sh | bash
tfswitch 1.10.0

# ── Hetzner Cloud CLI ── API token management and SSH key upload
# macOS:
brew install hcloud
# Linux: download from https://github.com/hetznercloud/cli/releases
#   HCLOUD_VERSION=$(curl -fsSL https://api.github.com/repos/hetznercloud/cli/releases/latest | jq -r .tag_name)
#   curl -fsSLO "https://github.com/hetznercloud/cli/releases/download/${HCLOUD_VERSION}/hcloud-linux-amd64.tar.gz"
#   tar xzf hcloud-linux-amd64.tar.gz && sudo install -m755 hcloud /usr/local/bin/hcloud

# ── age ── modern encryption tool; replaces GPG for SOPS
# WHAT: age generates keypairs for encrypting/decrypting secrets in git.
# WHY: simpler and more auditable than GPG. One keypair, no keychain complexity.
sudo apt install -y age     # Debian/Ubuntu

# ── SOPS ── encrypts/decrypts secret files using age keys
# WHAT: SOPS encrypts YAML values while leaving keys visible (for auditability).
# WHY: secrets can be committed to git safely — only the encrypted ciphertext
#   is stored. Decryption requires the age private key.
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

## 1) Secrets bootstrap (age + SOPS)

> **What is happening here?** You generate an encryption keypair. Secrets in
> git will be encrypted with the public key — anyone can encrypt. Only the
> holder of the private key can decrypt. The private key goes on your machine
> and into the cluster (as a Kubernetes Secret) so ArgoCD can decrypt at sync
> time.
>
> **Why not HashiCorp Vault or AWS KMS?** At this scale (single operator,
> single cluster), SOPS + age provides equivalent security for secrets at rest
> without the operational overhead of a running secrets service. Graduate to
> Vault when you have multiple teams or compliance requirements that mandate
> centralized secret management.

### 1.1 Generate age keypair

```bash
# WHAT: create an age keypair. The private key is written to the file.
#   The public key is printed to stdout (and stored in the file's header comment).
# SECURITY: this private key is the SINGLE CREDENTIAL that unlocks all secrets.
#   Back it up to a password manager immediately. Treat it like a root password.
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt

# NOTE: copy the public key from the output — it looks like:
#   age1xxxxxxxxxxxxxxxxxxxxxxxxx
# You will need it for .sops.yaml below.
```

### 1.2 Configure SOPS

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

### 1.3 Create and encrypt secrets

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
  postgres-password: "REPLACE_WITH_STRONG_PASSWORD"
  keycloak-db-password: "REPLACE_WITH_STRONG_PASSWORD"
```

```bash
# WHAT: create and encrypt the Keycloak admin credentials file.
sops infra/secrets/keycloak.enc.yaml
```

```bash
# VERIFICATION: view the encrypted file — values are ciphertext, keys are plain.
cat infra/secrets/postgres.enc.yaml

# Safe to commit — ciphertext is meaningless without the age private key.
git add .sops.yaml infra/secrets/
git commit -m "chore: add SOPS config and encrypted secret stubs"
```

> **Key custody summary**: the age private key at `~/.config/sops/age/keys.txt`
> unlocks ALL secrets. It lives in two places:
> 1. Your machine (for encrypting/decrypting locally)
> 2. The cluster (as a Kubernetes Secret, installed in §4.2, so ArgoCD can decrypt)
>
> If this key is lost, you cannot decrypt the secrets in git. You would need
> to re-create all secrets from scratch.

---

## 2) Hetzner Cloud setup

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

## 3) Terraform — VM, k3s, Cilium, Istio, ArgoCD

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

The Terraform files live at [infra/terraform/](../infra/terraform/). Key files:

| File | Purpose |
|---|---|
| [main.tf](../infra/terraform/main.tf) | All resources: providers, network, firewall, VM, kubeconfig retrieval, Helm releases |
| [variables.tf](../infra/terraform/variables.tf) | Input variables with defaults (versions, locations, CIDRs) |
| [outputs.tf](../infra/terraform/outputs.tf) | Output values (server IP etc.) |
| [cloud-init.yaml](../infra/terraform/cloud-init.yaml) | First-boot script: installs k3s with hardening flags |

### 3.1 What the Terraform code does (walk-through)

Rather than duplicating the Terraform files here (which creates drift risk),
this section explains what each resource block does. Read the actual files for
the definitive source.

**Providers** ([main.tf](../infra/terraform/main.tf)):
- `hcloud` — creates Hetzner Cloud resources (VMs, networks, firewalls)
- `helm` — installs Helm charts into the cluster Terraform just created
- `cloudinit` — renders the cloud-init template with variables (k3s version)

**Network** ([main.tf](../infra/terraform/main.tf)):
- `hcloud_network` + `hcloud_network_subnet` — private network for pod traffic.
  All node-to-node communication stays off the public internet.

**Firewall** ([main.tf](../infra/terraform/main.tf)):
- SSH (port 22): restricted to `var.operator_cidr` — your IP only
- HTTPS (port 443): open to the internet (application ingress)
- k8s API (port 6443): restricted to `var.operator_cidr`
- **Security note**: update `operator_cidr` if your ISP changes your IP.
  Forgetting this locks you out of SSH and the k8s API.

**VM + cloud-init** ([main.tf](../infra/terraform/main.tf) + [cloud-init.yaml](../infra/terraform/cloud-init.yaml)):
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

**Kubeconfig retrieval** ([main.tf](../infra/terraform/main.tf)):
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

**Helm releases** ([main.tf](../infra/terraform/main.tf)):
- Cilium → Istio (base → cni → ztunnel → istiod) → cert-manager → ArgoCD →
  Image Updater, each `depends_on` the previous
- All versions are parameterized in [variables.tf](../infra/terraform/variables.tf)
- Key flag: `cni.exclusive=false` on Cilium (allows Istio CNI coexistence)
- Key flag: `server.insecure=true` on ArgoCD — disables ArgoCD's own TLS
  listener. Ztunnel provides mTLS between ArgoCD pods once the namespace is
  enrolled, making ArgoCD's built-in TLS redundant.
  **Bootstrapping gap**: `helm install` creates the `argocd` namespace
  without the mesh label. §4.1 closes this with an imperative `kubectl
  label`. The permanent fix is declarative: `argocd` is declared in
  `infra/helm/namespaces/values.yaml` with `meshEnroll: true`, so ArgoCD's
  own self-heal maintains the label after first sync

### 3.2 Apply

```bash
cd infra/terraform

# WHAT: pass credentials via environment variables — never in .tfvars or CLI flags.
# WHY: environment variables are not stored in shell history (unlike CLI args)
#   and are not committed to git (unlike .tfvars files).
# SECURITY: TF_VAR_hcloud_token has full Hetzner project access. Treat carefully.
export TF_VAR_hcloud_token="<your-hetzner-api-token>"
export TF_VAR_ssh_key_name="register-dev-key"
export TF_VAR_operator_cidr="$(curl -fsSL https://api4.my-ip.io/ip)/32"

# WHAT: terraform init downloads providers and modules.
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
```

---

## 4) Post-Terraform bootstrap (one-time)

> **What is this section?** After `terraform apply`, the cluster has Cilium,
> Istio, cert-manager, and ArgoCD running. But ArgoCD is not yet watching any
> repository. These one-time manual steps connect ArgoCD to your git repo and
> hand off control.
>
> After this section, you stop running manual commands. Everything is GitOps.

### 4.1 Enroll ArgoCD in the mesh and rotate admin password

> **Close the bootstrapping gap — two parts.**
>
> Terraform's `helm install` created the `argocd` namespace without the Istio
> ambient label. ArgoCD is a high-value target (cluster-wide RBAC, SOPS age
> key, GitHub PAT, code execution in repo-server). From a defense-in-depth
> perspective, leaving it outside the mesh is an unacceptable gap.
>
> **Part 1 (below):** label the namespace now. Ztunnel is a node-level
> DaemonSet — it watches namespace labels and updates eBPF/iptables rules
> dynamically. Already-running ArgoCD pods are enrolled without a restart.
>
> **Part 2:** the `argocd` namespace is declared in
> `infra/helm/namespaces/values.yaml` with `meshEnroll: true`. When ArgoCD
> syncs the namespace chart (~60 s after the root App of Apps is applied in
> §4.4), it applies the Namespace resource with the ambient label. From
> that point, ArgoCD's self-heal prevents label drift — the enrollment is
> under GitOps governance.

```bash
# SECURITY: enroll the argocd namespace in the Istio ambient mesh.
# Part 1 of 2 — closes the bootstrap window immediately.
# Part 2 is declarative: values.yaml declares argocd with meshEnroll: true.
kubectl label namespace argocd istio.io/dataplane-mode=ambient

# VERIFICATION: confirm the label is set.
kubectl get namespace argocd --show-labels | grep dataplane-mode
```

> **Why rotate immediately?** ArgoCD generates a random admin password on
> install and stores it as a Kubernetes Secret. Auto-generated bootstrap
> credentials should never persist — this is a standard security practice.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
PF_PID=$!
sleep 3

# WHAT: retrieve the auto-generated admin password.
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

# WHAT: --insecure skips TLS verification to the ArgoCD server.
# The port-forward runs plain HTTP locally — there is no TLS to verify.
# This does NOT affect the security of any other connection.
argocd login localhost:8080 \
  --username admin \
  --password "$ARGOCD_PASS" \
  --insecure

# WHAT: set a new password. read -s hides terminal input.
read -r -s -p "New ArgoCD admin password: " NEW_PASS; echo
argocd account update-password \
  --account admin \
  --current-password "$ARGOCD_PASS" \
  --new-password "$NEW_PASS"

# SECURITY: clear passwords from shell memory. Delete the bootstrap secret.
unset ARGOCD_PASS NEW_PASS
kubectl -n argocd delete secret argocd-initial-admin-secret

kill $PF_PID 2>/dev/null || true
```

### 4.2 Install SOPS decryption key into the cluster

> **What is this?** ArgoCD needs the age private key to decrypt
> `infra/secrets/*.enc.yaml` at sync time. We store it as a Kubernetes Secret
> in the `argocd` namespace where the SOPS plugin can read it.
>
> **Security note**: this is the only time the age private key leaves your
> machine and enters the cluster. The Secret is encrypted at rest by k3s's
> `--secrets-encryption` flag (configured in cloud-init).

```bash
kubectl -n argocd create secret generic sops-age-key \
  --from-file=keys.txt="$HOME/.config/sops/age/keys.txt" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 4.3 Connect the GitHub repository

> **Why register the repo?** ArgoCD maintains an allow list of trusted
> repositories. Only registered repos can be referenced in Application
> manifests. This prevents someone from pointing an Application at a
> malicious repo.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
PF_PID=$!
sleep 3

read -r -p "GitHub repo URL (https://github.com/org/repo): " GH_REPO
read -r -p "GitHub username: " GH_USER
read -r -s -p "GitHub PAT (read:repo scope): " GH_PAT; echo

argocd repo add "$GH_REPO" \
  --username "$GH_USER" \
  --password "$GH_PAT" \
  --insecure   # skips TLS check to ArgoCD server on localhost, not to GitHub

# SECURITY: wipe credentials from shell memory immediately.
unset GH_USER GH_PAT
kill $PF_PID 2>/dev/null || true
```

### 4.4 Apply the root App of Apps — the handoff moment

> **This is the single most important step.** The root Application tells
> ArgoCD to watch `infra/argocd/apps/` in your git repo. ArgoCD discovers all
> child Application files in that directory and deploys them.
>
> After this, adding a new service to the cluster = adding one YAML file to
> `infra/argocd/apps/` and pushing to git.
>
> **Note**: the previous version of this guide had a separate step to create
> the `namespaces` app imperatively via `argocd app create`. That is
> unnecessary — the root App of Apps already includes
> [namespaces.yaml](../infra/argocd/apps/namespaces.yaml). The App of Apps
> pattern means you declare everything in git, not via CLI commands.

```bash
# WHAT: apply the root Application manifest. This is the LAST kubectl apply.
kubectl apply -f infra/argocd/apps/root.yaml
```

ArgoCD will now discover and deploy these Applications automatically:

| ArgoCD Application | What it deploys | Source |
|---|---|---|
| `namespaces` | Namespaces (`argocd`, `register`, `infra`, `observability`) with Pod Security labels + mesh enrollment | [infra/helm/namespaces/](../infra/helm/namespaces/) |
| `postgresql` | PostgreSQL database (StatefulSet) | Bitnami Helm chart (remote) — see [postgresql.yaml](../infra/argocd/apps/postgresql.yaml) |
| `keycloak` | Keycloak identity provider | Bitnami Helm chart (remote) — see [keycloak.yaml](../infra/argocd/apps/keycloak.yaml) |
| `mesh-policy` | Istio JWT/auth policies, OPA role gating, NetworkPolicies | [infra/k8s/](../infra/k8s/) — see [mesh-policy.yaml](../infra/argocd/apps/mesh-policy.yaml) |
| `register` | Application Deployment + Image Updater config | [infra/helm/register/](../infra/helm/register/) — see [register.yaml](../infra/argocd/apps/register.yaml) |

### 4.5 Watch the sync

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
PF_PID=$!
sleep 3

# WHAT: list all ArgoCD Applications and their sync/health status.
argocd app list

# WHAT: wait for each app to reach healthy state.
argocd app wait namespaces --health --timeout 60
argocd app wait postgresql --health --timeout 300
argocd app wait keycloak --health --timeout 300
argocd app wait mesh-policy --health --timeout 60

kill $PF_PID 2>/dev/null || true
```

---

## 5) What ArgoCD manages (reference)

> **These files are in the repository** — not duplicated here. This section
> provides brief descriptions so you know what each file controls. Edit the
> actual files and push to git; ArgoCD applies the changes.

### Application declarations (`infra/argocd/apps/`)

| File | What it declares | Key configuration |
|---|---|---|
| [root.yaml](../infra/argocd/apps/root.yaml) | Root App of Apps | Watches `infra/argocd/apps/`, automated sync + prune + self-heal, cascade finalizer |
| [namespaces.yaml](../infra/argocd/apps/namespaces.yaml) | Namespace Helm chart | Points at `infra/helm/namespaces/`, creates namespaces with PSS labels and mesh enrollment |
| [postgresql.yaml](../infra/argocd/apps/postgresql.yaml) | PostgreSQL database | Bitnami chart v16.4.0, references `postgres-credentials` Secret for auth, 10Gi PVC |
| [keycloak.yaml](../infra/argocd/apps/keycloak.yaml) | Keycloak IdP | Bitnami chart, connects to PostgreSQL via internal DNS, references encrypted credentials |
| [register.yaml](../infra/argocd/apps/register.yaml) | Application Deployment | Image Updater annotations for automated GHCR → git → cluster deploy loop |
| [mesh-policy.yaml](../infra/argocd/apps/mesh-policy.yaml) | Security policies | Istio RequestAuthentication, AuthorizationPolicy, OPA Deployment, NetworkPolicies |

### Namespace chart (`infra/helm/namespaces/`)

The namespace Helm chart at [infra/helm/namespaces/](../infra/helm/namespaces/)
declares each namespace with:
- **Pod Security Standards labels**: `enforce`, `audit`, `warn` — controls what
  pods are allowed to run (e.g. `restricted` prohibits root containers)
- **Mesh enrollment label**: `istio.io/dataplane-mode: ambient` — tells Istio's
  ztunnel to intercept traffic for this namespace

See [values.yaml](../infra/helm/namespaces/values.yaml) for the namespace
definitions. A fallback file
[values-infra-no-mesh.yaml](../infra/helm/namespaces/values-infra-no-mesh.yaml)
removes the `infra` namespace from the mesh (useful if database pods have probe
issues with ztunnel).

### Security policies (`infra/k8s/`)

| File | What it enforces |
|---|---|
| [istio/request-authentication.yaml](../infra/k8s/istio/request-authentication.yaml) | Validates JWT signatures against Keycloak's JWKS endpoint |
| [istio/authorization-policy.yaml](../infra/k8s/istio/authorization-policy.yaml) | Requires valid JWT on all requests to the register namespace |
| [istio/envoy-filter-strip-headers.yaml](../infra/k8s/istio/envoy-filter-strip-headers.yaml) | Strips forged identity headers (`x-user-id`, `x-user-email`) before they reach the app |
| [opa/deployment.yaml](../infra/k8s/opa/deployment.yaml) | OPA gRPC server evaluating Rego role-based policies |
| [opa/ext-authz-filter.yaml](../infra/k8s/opa/ext-authz-filter.yaml) | Routes waypoint authorization checks to OPA |
| [network-policy/register.yaml](../infra/k8s/network-policy/register.yaml) | Default-deny + allow rules: only waypoint can reach app pods |

---

## 6) The automated deploy loop

> **This is the end-state workflow** — how code changes reach the running
> cluster without any manual intervention.

```
git push (application code change)
  → GitHub Actions (CI):
      - sbt test (compile + unit tests)
      - docker buildx build --push ghcr.io/<org>/<image>:<git-sha>
  → ArgoCD Image Updater (runs in-cluster, polls GHCR every ~2 min):
      - detects new image digest at ghcr.io/<org>/<image>
      - commits updated tag to infra/helm/register/.argocd-source-register.yaml
  → ArgoCD (polls git every ~3 min, or via webhook for instant sync):
      - detects the commit on HEAD
      - renders Helm chart with new image tag
      - performs rolling update in the register namespace
  → new pod running within ~90 seconds of git push
```

> **Webhook for instant sync**: for faster feedback, configure a GitHub webhook
> pointing at the ArgoCD API server. This requires the ArgoCD server to be
> reachable from the internet (via an Ingress or Cloudflare Tunnel).

---

## 7) Teardown

```bash
cd infra/terraform

# WHAT: destroy all Hetzner Cloud resources (VM, network, firewall).
# Terraform reads its state file and deletes every resource it created.
# Data on the VM (etcd, PVCs) is permanently destroyed.
terraform destroy

# WHAT: remove the local kubeconfig — it is no longer valid.
rm -f kubeconfig.yaml
```

> **Reconstruction**: the cluster is fully recreated by running `terraform apply`
> again. Because all state lives in git (Helm charts, ArgoCD apps, SOPS-encrypted
> secrets), nothing is lost. The only external dependency is the age private key.

---

## 8) Security boundaries and accepted risks

> **Reference frameworks**: these boundaries are informed by the
> [CIS Kubernetes Benchmark](https://www.cisecurity.org/benchmark/kubernetes)
> and [NSA/CISA Kubernetes Hardening Guide](https://media.defense.gov/2022/Aug/29/2003066362/-1/-1/0/CTR_KUBERNETES_HARDENING_GUIDANCE_1.2_20220829.PDF).

| Boundary | Protection | Accepted risk |
|---|---|---|
| **Secrets at rest** | k3s `--secrets-encryption` (AES-CBC) | Single-node: node compromise = key compromise. Mitigate with disk encryption. |
| **Secrets in git** | SOPS + age encryption | Age private key is the single point of failure. Loss = locked out of all secrets. |
| **Container images** | GHCR private registry, digest pinning via Image Updater | Image Updater PAT has `read:packages` scope only. |
| **API server access** | Hetzner firewall restricts port 6443 to `operator_cidr` | Must update CIDR when ISP changes your IP. |
| **SSH access** | Key-only auth, firewall-restricted to `operator_cidr` | No bastion host — direct SSH from operator IP. |
| **Pod-to-pod traffic** | Istio mTLS (ambient) + NetworkPolicy (Cilium) | ztunnel may break PostgreSQL/Keycloak liveness probes (see below). Rollback file exists. |
| **ArgoCD** | Enrolled in mesh (§4.1), admin password rotated, UI behind port-forward | No SSO in this baseline. Add Dex + OIDC for team use. |
| **Supply chain** | k3s installed via `curl \| bash` | Trusts k3s download server at provision time. Mitigate with custom VM images. |
| **First SSH connection** | `StrictHostKeyChecking=no` for kubeconfig retrieval | One-time risk during fresh VM provisioning. Pin host key afterward. |

### Known limitation: ztunnel + PostgreSQL liveness probes

> **Be honest about this.** The `infra` namespace is enrolled in the mesh
> (`meshEnroll: true` in [values.yaml](../infra/helm/namespaces/values.yaml)).
> This means ztunnel intercepts **all** L4 traffic, including kubelet health
> check probes. PostgreSQL uses a custom binary wire protocol (not HTTP). When
> the kubelet sends a TCP liveness probe to port 5432, ztunnel wraps it in
> HBONE (its mTLS tunnel). Some PostgreSQL images (particularly Bitnami's
> StatefulSet) fail the liveness check because the probe traffic arrives
> through ztunnel's interception rather than as a direct TCP connection.
>
> **This is a technical limitation of ztunnel's transparent L4 interception
> with non-HTTP protocols, not a security design choice.** The correct
> response to it is:
>
> 1. **Try it first** — many versions and configurations work fine. The
>    default config has `meshEnroll: true`.
> 2. **If probes fail**, use `probeExcludePorts` to exclude port 5432 from
>    ztunnel interception (see the comment in
>    [values.yaml](../infra/helm/namespaces/values.yaml)).
> 3. **If that doesn't work**, use the full rollback file
>    [values-infra-no-mesh.yaml](../infra/helm/namespaces/values-infra-no-mesh.yaml)
>    to remove infra from the mesh entirely.
>
> **If you use the rollback, state it clearly as an accepted risk**: `app →
> postgres` and `app → keycloak` traffic becomes plaintext TCP. Do not
> rationalize this as "infra doesn't need encryption" — the reason is a
> specific technical limitation, and it should be tracked as a gap to close
> when Istio ambient mode improves its non-HTTP protocol handling.

---

## Troubleshooting

### Terraform fails at kubeconfig retrieval

The `sleep 90` may be too short if Hetzner is under load or package mirrors
are slow. Wait 2 minutes and re-run:

```bash
terraform apply
```

Terraform is idempotent — it will skip completed resources and retry the
kubeconfig step.

### ArgoCD Application stuck at OutOfSync

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
argocd app sync <app-name>
argocd app get <app-name>

# check events in the target namespace
kubectl -n <namespace> get events --sort-by=.lastTimestamp | tail -20
```

### SOPS decryption fails

```bash
# verify the age key is installed in the cluster
kubectl -n argocd get secret sops-age-key

# verify the key content matches your local key
kubectl -n argocd get secret sops-age-key -o jsonpath='{.data.keys\.txt}' \
  | base64 -d | head -1
# should match: head -1 ~/.config/sops/age/keys.txt
```

### Locked out — operator IP changed

```bash
# update your IP and re-apply the firewall rule
export TF_VAR_operator_cidr="$(curl -fsSL https://api4.my-ip.io/ip)/32"
terraform plan -out=tfplan
terraform apply tfplan
```

### PostgreSQL or Keycloak crash after mesh enrollment

Database liveness probes can conflict with ztunnel interception. Rollback:

```bash
kubectl label namespace infra istio.io/dataplane-mode- --overwrite
```

Or use the fallback values file — edit the namespaces Application to use
`values-infra-no-mesh.yaml`.

### Quick health check

```bash
kubectl get nodes -o wide
kubectl get ns --show-labels
kubectl -n kube-system get pods         # Cilium
kubectl -n istio-system get pods        # Istio
kubectl -n cert-manager get pods        # cert-manager
kubectl -n argocd get pods              # ArgoCD + Image Updater
kubectl -n infra get pods               # PostgreSQL, Keycloak
kubectl -n register get pods            # Application + OPA
kubectl -n register get gateway         # Waypoint proxy
```

---

## Glossary

### Core Kubernetes concepts

| Term | Definition |
|---|---|
| **Cluster** | A set of machines (nodes) running Kubernetes. Here, a single Hetzner VM. |
| **Node** | A machine in the cluster. Runs pods. |
| **Pod** | Smallest deployable unit — one or more containers sharing network. |
| **Namespace** | Logical partition inside a cluster. Pods in different namespaces are isolated. |
| **Deployment** | Declares "run N copies of this pod". Kubernetes ensures the count matches. |
| **StatefulSet** | Like Deployment, but for databases: stable names and persistent storage. |
| **DaemonSet** | Runs one pod on every node. Used by Cilium and ztunnel. |
| **Service** | Stable DNS name + IP routing traffic to pods. |
| **Secret** | Kubernetes resource for sensitive data. Encrypted at rest with `--secrets-encryption`. |
| **ConfigMap** | Like Secret, but for non-sensitive configuration. |
| **CRD** | Custom Resource Definition — extends the Kubernetes API with new types. |
| **kubeconfig** | File with cluster connection details. Never commit to git. |
| **RBAC** | Role-Based Access Control — Kubernetes permission system. |
| **PVC** | Persistent Volume Claim — request for disk storage that survives pod restarts. |

### Networking and security

| Term | Definition |
|---|---|
| **CNI** | Container Network Interface — pod networking plugin. Cilium is ours. |
| **eBPF** | Linux kernel technology Cilium uses for high-performance NetworkPolicy. |
| **NetworkPolicy** | Firewall rules between pods. Default-deny blocks all traffic unless allowed. |
| **Service mesh** | Infrastructure layer managing service-to-service traffic (mTLS, L7 policy). |
| **mTLS** | Mutual TLS — both sides present certificates. Istio does this automatically. |
| **ztunnel** | Istio ambient mode's L4 proxy. DaemonSet on every node. Handles mTLS. |
| **Waypoint proxy** | Istio ambient's L7 proxy. Per-namespace Envoy for JWT validation and auth. |
| **Envoy** | High-performance proxy used by Istio. |
| **EnvoyFilter** | Istio CRD for low-level Envoy config. Strips forged headers. |
| **Pod Security Standards** | K8s-native profiles: `privileged`, `baseline`, `restricted`. |

### Authentication

| Term | Definition |
|---|---|
| **JWT** | JSON Web Token — signed claims (user ID, roles, expiry). Mesh validates signature. |
| **JWKS** | JSON Web Key Set — public keys for JWT verification. Keycloak publishes, Istio caches. |
| **OIDC** | OpenID Connect — auth protocol on top of OAuth2. Keycloak implements it. |
| **OPA** | Open Policy Agent — evaluates Rego rules for role-based gating. |
| **Rego** | OPA's policy language. Declarative rules like "allow if user has editor role". |

### GitOps and infrastructure

| Term | Definition |
|---|---|
| **GitOps** | Operations model: git is the single source of truth. Controller applies changes. |
| **IaC** | Infrastructure as Code — managing infrastructure via code, not manual commands. |
| **Terraform** | IaC tool. Declares cloud resources (VMs, networks, firewalls). `terraform apply` creates them. |
| **Terraform state** | File tracking what Terraform has created. Required for updates and teardown. |
| **cloud-init** | First-boot automation for VMs. Runs commands, writes files, installs packages. |
| **App of Apps** | ArgoCD pattern: one root Application manages a directory of child Applications. |
| **Reconciliation** | ArgoCD comparing git (desired) to cluster (actual) every ~3 minutes. |
| **Self-healing** | ArgoCD reverting manual cluster changes to match git. |
| **Drift** | Cluster state diverging from git. ArgoCD detects and corrects automatically. |
| **Helm chart** | Package of Kubernetes YAML templates + configuration values. |
| **SOPS** | Secrets OPerationS — encrypts/decrypts files. Values encrypted, keys visible. |
| **age** | Modern encryption tool. SOPS uses age keypairs for secret encryption. |
| **GHCR** | GitHub Container Registry — hosts Docker images. Image Updater polls it. |

---

## Tooling overview

Every tool used in this guide:

| Tool | What it does | Used in | Runs on |
|---|---|---|---|
| **Terraform** | Provisions cloud infrastructure declaratively | §3 | Your machine |
| **hcloud** | Hetzner Cloud CLI — API token + SSH key management | §2 | Your machine |
| **age** | Generates encryption keypairs for SOPS | §1 | Your machine |
| **SOPS** | Encrypts/decrypts secret files in git | §1 | Your machine + cluster (ArgoCD plugin) |
| **kubectl** | Kubernetes CLI — talks to the cluster API | §4 | Your machine |
| **ArgoCD CLI** | Bootstrap-time ArgoCD management | §4 | Your machine |
| **ArgoCD** | GitOps controller — syncs cluster state to git | §4 onward | In-cluster |
| **Image Updater** | Polls GHCR for new images, commits tag to git | §6 | In-cluster |
| **Cilium** | CNI — pod networking + NetworkPolicy enforcement | Installed by Terraform | In-cluster |
| **Istio** | Service mesh — mTLS + L7 policy + waypoint proxies | Installed by Terraform | In-cluster |
| **cert-manager** | TLS certificate automation | Installed by Terraform | In-cluster |
| **k3s** | Lightweight Kubernetes distribution | Installed by cloud-init | On the VM |
| **OPA** | Policy engine — role-based gating via Rego rules | Deployed by ArgoCD | In-cluster |
| **Keycloak** | Identity provider — issues JWTs, JWKS endpoint | Deployed by ArgoCD | In-cluster |
| **PostgreSQL** | Database for Keycloak + application | Deployed by ArgoCD | In-cluster |
