# register-infra

Infrastructure as Code and GitOps configuration for the **register** platform.

## What this repository owns

| Layer | Tooling | Location |
|---|---|---|
| Cloud infrastructure (VM, network, firewall) | Terraform + Hetzner Cloud provider | `infra/terraform/` |
| CNI, service mesh, ingress, cert-manager | Terraform Helm provider | `infra/terraform/main.tf` |
| GitOps controller (ArgoCD) | Terraform Helm provider | `infra/terraform/main.tf` |
| Namespace declarations + Pod Security labels | Helm chart, ArgoCD-managed | `infra/helm/namespaces/` |
| Application Helm chart | Helm, ArgoCD-managed | `infra/helm/register/` |
| ArgoCD Application manifests | YAML, App of Apps pattern | `infra/argocd/apps/` |
| Istio JWT + AuthorizationPolicy | YAML, ArgoCD-managed | `infra/k8s/istio/` |
| Encrypted secrets | SOPS + age | `infra/secrets/` |

## What this repository does NOT own

- Application source code → [`register`](https://github.com/<org>/register)
- Container image builds → GitHub Actions in the app repo

## Prerequisites

See [docs/K3S-GITOPS-BOOTSTRAP.md](docs/K3S-GITOPS-BOOTSTRAP.md) for the full provisioning walkthrough.

Quick-reference tool versions:

| Tool | Minimum version |
|---|---|
| Terraform | 1.10 |
| Helm | 3.x |
| ArgoCD CLI | latest stable |
| SOPS | 3.x |
| age | 1.x |

## Bootstrap (new cluster)

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
