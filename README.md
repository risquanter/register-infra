# register-infra

Infrastructure as Code and GitOps configuration for the **register** platform.

## What this repository owns

| Layer | Tooling | Location |
|---|---|---|
| Cloud infrastructure (VM, network, firewall) | Terraform + Hetzner Cloud provider | `infra/terraform/` |
| CNI, service mesh, ingress, cert-manager | Terraform Helm provider | `infra/terraform/main.tf` |
| GitOps controller (ArgoCD) | Terraform Helm provider | `infra/terraform/main.tf` |
| Namespace declarations + Pod Security + LimitRanges | Helm chart, ArgoCD-managed | `infra/helm/namespaces/` |
| Application Helm chart | Helm, ArgoCD-managed | `infra/helm/register/` |
| OPA ext_authz server | Helm chart, ArgoCD-managed | `infra/helm/opa/` |
| ArgoCD Application manifests + AppProjects | YAML, App of Apps pattern | `infra/argocd/apps/`, `infra/argocd/projects/` |
| Istio JWT, AuthorizationPolicy, PeerAuthentication | YAML, ArgoCD-managed | `infra/k8s/istio/` |
| OPA ext_authz EnvoyFilter | YAML, ArgoCD-managed | `infra/k8s/opa/` |
| Cilium NetworkPolicies | YAML, ArgoCD-managed | `infra/k8s/network-policy/` |
| RBAC roles | YAML, ArgoCD-managed | `infra/k8s/rbac/` |
| Encrypted secrets | SOPS + age | `infra/secrets/` |

## What this repository does NOT own

- Application source code → [`register`](https://github.com/<org>/register)
- Container image builds → GitHub Actions in the app repo

## Getting started

| Path | Guide | Prerequisite |
|---|---|---|
| **Local development** (start here) | [docs/LOCAL-K3D-BOOTSTRAP.md](docs/LOCAL-K3D-BOOTSTRAP.md) | Fresh Debian + Docker |
| Production deploy (Hetzner Cloud) | [docs/K3S-GITOPS-BOOTSTRAP.md](docs/K3S-GITOPS-BOOTSTRAP.md) | Hetzner account + Terraform |
| **GitOps operations reference** | [docs/GITOPS-OPERATIONS.md](docs/GITOPS-OPERATIONS.md) | — |
| Learning / reference (archived) | [docs/archive/K3S-MANUAL-INSTALL.md](docs/archive/K3S-MANUAL-INSTALL.md) | — |
| Validation / CI | [docs/K8S-TESTING.md](docs/K8S-TESTING.md) | Running cluster |
| Security architecture | [docs/SECURITY-FLOW.md](docs/SECURITY-FLOW.md) | — |

Quick-reference tool versions:

| Tool | Minimum version |
|---|---|
| Terraform | 1.10 |
| Helm | 3.x |
| ArgoCD CLI | latest stable |
| SOPS | 3.x |
| age | 1.x |

## Bootstrap — local development (recommended starting point)

```bash
# see docs/LOCAL-K3D-BOOTSTRAP.md for the full walkthrough
k3d cluster create register-dev \
  --k3s-arg "--flannel-backend=none@server:0" \
  --k3s-arg "--disable-network-policy@server:0" \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--disable=servicelb@server:0" \
  --port "8443:443@loadbalancer" \
  --port "8080:80@loadbalancer"

# then follow LOCAL-K3D-BOOTSTRAP.md §2–§8:
#   install Cilium → Istio → cert-manager → ArgoCD → create secrets → connect repo
#   → apply root App-of-Apps → ArgoCD manages everything from git
```

## Bootstrap — Hetzner Cloud (production)

```bash
# 1. provision VM + install cluster platform components
cd infra/terraform
export TF_VAR_hcloud_token="<token>"
export TF_VAR_ssh_key_name="<key-name>"
export TF_VAR_operator_cidr="$(curl -fsSL https://api4.my-ip.io/ip)/32"
terraform init && terraform apply

# 2. export kubeconfig
export KUBECONFIG="$PWD/kubeconfig.yaml"

# 3. one-time post-terraform bootstrap (ArgoCD password, SOPS key, repo registration)
# follow docs/K3S-GITOPS-BOOTSTRAP.md §4

# 4. apply root App of Apps — ArgoCD takes over from here
kubectl apply -f infra/argocd/apps/root.yaml
```

## Day-to-day operations

All cluster state changes after bootstrap are made by editing files in this repo and pushing. ArgoCD syncs automatically within ~3 minutes, or immediately if a webhook is configured.

| Task | Action |
|---|---|
| Deploy new app image | Image Updater commits tag automatically after CI push |
| Change app config | Edit `infra/helm/register/values.yaml`, push |
| Add a new service | Add `infra/argocd/apps/<service>.yaml`, push |
| Rotate an encrypted secret | `sops infra/secrets/<file>.enc.yaml`, edit, save, push |
| Scale/resize VM | Edit `infra/terraform/main.tf`, `terraform apply` |

## Secret management

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age).

- Encrypted files (`*.enc.yaml`) are safe to commit — values are ciphertext
- The age private key lives at `~/.config/sops/age/keys.txt` on the operator's machine
- ArgoCD decrypts at sync time using the `sops-age-key` Kubernetes Secret (installed in bootstrap §4.2)
- **Never commit the age private key or any plaintext secret**

```bash
# edit an existing encrypted secret
sops infra/secrets/postgres.enc.yaml

# create a new encrypted secret
sops infra/secrets/my-new-secret.enc.yaml
```
