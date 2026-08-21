# register-infra

Infrastructure as Code and GitOps configuration for the **register** platform.

## What this repository owns

| Layer | Tooling | Location |
|---|---|---|
| Cloud infrastructure (VM, network, firewall) | Terraform + Hetzner Cloud provider | `infra/terraform/envs/hetzner/` |
| Local cluster (k3d) + optional local registry | Terraform, k3d CLI | `infra/terraform/envs/local/` |
| CNI, service mesh, ingress, cert-manager | Terraform Helm provider | `infra/terraform/modules/platform/` |
| GitOps controller (ArgoCD) | Terraform Helm provider | `infra/terraform/modules/platform/` |
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

**[docs/START-HERE.md](docs/START-HERE.md) is the map** — the two axes (image
repo × cluster), the three supported points, and the reading path for each. The
rest of the doc set:

| Path | Guide | Prerequisite |
|---|---|---|
| **Start here** (the map) | [docs/START-HERE.md](docs/START-HERE.md) | — |
| Bootstrap — by hand (local) | [docs/MANUAL-BOOTSTRAP.md](docs/MANUAL-BOOTSTRAP.md) | Fresh Debian + Docker |
| Bootstrap — Terraform (local or Hetzner) | [docs/TERRAFORM-BOOTSTRAP.md](docs/TERRAFORM-BOOTSTRAP.md) | Terraform (+ Hetzner account for point 3) |
| Secrets (shared, all paths) | [docs/SECRETS-BOOTSTRAP.md](docs/SECRETS-BOOTSTRAP.md) | YubiKey (PIV) |
| GitOps rollout (shared, all paths) | [docs/GITOPS-ROLLOUT.md](docs/GITOPS-ROLLOUT.md) | Platform Ready |
| Image deploy (image-repo axis, shared) | [docs/IMAGE-DEPLOY.md](docs/IMAGE-DEPLOY.md) | Platform Ready |
| Operations reference + platform concepts | [docs/GITOPS-OPERATIONS.md](docs/GITOPS-OPERATIONS.md) | — |
| Testing (regression + validation toolbox) | [docs/TESTING.md](docs/TESTING.md) | — (live tier needs a cluster) |
| Security architecture | [docs/SECURITY-FLOW.md](docs/SECURITY-FLOW.md) | — |
| Archived (superseded, for reference) | [docs/archive/](docs/archive/) | — |

Quick-reference tool versions:

| Tool | Minimum version |
|---|---|
| Terraform | 1.10 |
| Helm | 3.x |
| ArgoCD CLI | latest stable |
| SOPS | 3.x |
| age | 1.x |

## Bootstrap — by hand (local, point 1)

```bash
# see docs/MANUAL-BOOTSTRAP.md for the full walkthrough
# 1. local image registry the cluster pulls from (point 1 only; skip for GHCR/point 2)
k3d registry create registry.localhost --port 5000
grep -q 'k3d-registry.localhost' /etc/hosts \
  || echo '127.0.0.1 k3d-registry.localhost' | sudo tee -a /etc/hosts

# 2. the cluster, pinned to the k3s version and wired to the registry (§1.2)
k3d cluster create register-dev \
  --image rancher/k3s:v1.30.0-k3s1 \
  --registry-use k3d-registry.localhost:5000 \
  --k3s-arg "--flannel-backend=none@server:0" \
  --k3s-arg "--disable-network-policy@server:0" \
  --k3s-arg "--disable=traefik@server:0" \
  --port "8443:443@loadbalancer" \
  --port "8080:80@loadbalancer" \
  --wait

# then follow MANUAL-BOOTSTRAP.md §2–§5:
#   install Cilium → Istio → cert-manager → ArgoCD (+ Image Updater)
# then the shared guides:
#   SECRETS-BOOTSTRAP.md (create + apply SOPS/age/YubiKey secrets)
#   GITOPS-ROLLOUT.md    (mesh-enroll ArgoCD → connect repo → root App-of-Apps)
#   IMAGE-DEPLOY.md      (build → push the three app images to the registry)
```

The Terraform equivalent of this same local build is
`cd infra/terraform/envs/local && terraform apply` (point 1 with
`create_local_registry=true`, point 2 with `=false`). See
[docs/TERRAFORM-BOOTSTRAP.md](docs/TERRAFORM-BOOTSTRAP.md).

## Bootstrap — Terraform, Hetzner (point 3)

```bash
# 1. provision VM + install cluster platform components
cd infra/terraform/envs/hetzner
export TF_VAR_hcloud_token="<token>"
export TF_VAR_ssh_key_name="<key-name>"
export TF_VAR_operator_cidr="$(curl -fsSL https://api4.my-ip.io/ip)/32"
terraform init && terraform apply

# 2. export kubeconfig
export KUBECONFIG="$PWD/kubeconfig.yaml"

# 3. create + apply the SOPS/age/YubiKey secrets
# follow docs/SECRETS-BOOTSTRAP.md

# 4. one-time rollout: mesh-enroll ArgoCD, rotate password, connect repo,
#    apply root App of Apps — ArgoCD takes over from here
# follow docs/GITOPS-ROLLOUT.md (ends with):
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
| Scale/resize VM | Edit `infra/terraform/envs/hetzner/main.tf`, `terraform apply` |

## Secret management

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age).

- Encrypted files (`*.enc.yaml`) are safe to commit — values are ciphertext
- Two recipients: the **primary key lives on the YubiKey PIV chip** (non-exportable, touch-to-use); an **offline backup age key** is the recovery path (off-machine, never in a cluster)
- Decryption is **manual** — the operator runs `sops -d | kubectl apply` with a YubiKey touch. ArgoCD has no SOPS plugin and never decrypts, so no age private key is in the cluster
- **Never commit an age private key or any plaintext secret** — see [docs/SECRETS-BOOTSTRAP.md](docs/SECRETS-BOOTSTRAP.md)

```bash
# edit an existing encrypted secret
sops infra/secrets/postgres.enc.yaml

# create a new encrypted secret
sops infra/secrets/my-new-secret.enc.yaml
```
