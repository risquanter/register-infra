# Start Here — bringing up the register platform

This is the map. It explains the two choices you make, the three supported
combinations, and which documents you read for your combination. Every path is
educational; none is "production" versus "learning".

---

## The two choices (two independent axes)

Bringing the platform up involves two decisions that do **not** depend on each
other:

1. **Image repo** — where the application pods pull their container images from:
   - **local-registry** — a k3d-managed registry container on your machine.
   - **GHCR** — GitHub Container Registry (`ghcr.io`), which needs auth.
2. **Cluster** — where Kubernetes runs:
   - **local k3d** — k3s-in-Docker on your machine.
   - **Hetzner** — a single-node k3s VM on a Hetzner Cloud server.

The image-repo axis lives in the GitOps layer (a Helm values overlay, the same
on any cluster — see [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md)). The cluster axis is what
the bootstrap tracks below differ on.

## The three supported combinations (points)

Only three of the four axis combinations are supported and end-to-end tested. The
fourth (local-registry + Hetzner) is excluded — a cloud VM cannot reach a registry
on your laptop.

| Point | Image repo | Cluster | What it exercises |
|---|---|---|---|
| **1** | local-registry | local k3d | The whole stack on your machine, no cloud, no external registry auth. |
| **2** | GHCR | local k3d | GHCR auth (PAT, package visibility, `ghcr-pull` secret) on a cluster you already understand. |
| **3** | GHCR | Hetzner | The full remote path: cloud VM + GHCR. |

## The two bootstrap tracks

You reach a running cluster + platform one of two ways. Both end at the same
tool-agnostic state, **Platform Ready**, after which every path is identical.

- **By-hand track** — [MANUAL-BOOTSTRAP.md](MANUAL-BOOTSTRAP.md): you create a
  local k3d cluster and install the platform (Cilium, Istio, cert-manager,
  ArgoCD) by typing the commands. This is the "learn each component by installing
  it" path. Local cluster only (points 1 and 2).
- **Automated track** — [TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md): one
  Terraform codebase creates the cluster and installs the same platform. It has
  two env roots: `envs/local` (points 1 and 2) and `envs/hetzner` (point 3).

## The pipeline (where the tracks meet)

```
choose a point
      │
      ▼
get a cluster + platform  ──►  Platform Ready  ──►  load secrets  ──►  GitOps rollout  ──►  deploy images
   (differs by track)          (shared cut-off)      (shared)          (shared)            (shared; image-repo axis)
```

Everything to the right of **Platform Ready** is the same document set for all
five reading paths below.

---

## Reading paths

Pick your track and point, then read the documents in order. The shared spine
(secrets → rollout → images) is identical everywhere; only the bootstrap document
and two gated steps (the local registry, and the GHCR auth) change.

**① By-hand · local-registry + local (point 1)**
[MANUAL-BOOTSTRAP.md](MANUAL-BOOTSTRAP.md) *(do the create-local-registry step)*
→ Platform Ready → [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) *(skip ghcr-pull)*
→ [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)
→ [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md) *(local-registry variant)*

**② By-hand · GHCR + local (point 2)**
[MANUAL-BOOTSTRAP.md](MANUAL-BOOTSTRAP.md) *(skip the local-registry step)*
→ Platform Ready → [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) *(create ghcr-pull)*
→ [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)
→ [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md) *(GHCR variant)*

**③ Automated · local-registry + local (point 1)**
[TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md) *(`envs/local`, `create_local_registry=true`)*
→ Platform Ready → [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) *(skip ghcr-pull)*
→ [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)
→ [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md) *(local-registry variant)*

**④ Automated · GHCR + local (point 2)**
[TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md) *(`envs/local`, `create_local_registry=false`)*
→ Platform Ready → [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) *(create ghcr-pull)*
→ [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)
→ [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md) *(GHCR variant)*

**⑤ Automated · GHCR + Hetzner (point 3)**
[TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md) *(`envs/hetzner`)*
→ Platform Ready → [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) *(create ghcr-pull)*
→ [GITOPS-ROLLOUT.md](GITOPS-ROLLOUT.md)
→ [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md) *(GHCR variant)*

---

## Reference (consult as needed, not a path)

| Document | What it is |
|---|---|
| [GITOPS-OPERATIONS.md](GITOPS-OPERATIONS.md) | Platform component concepts (what each layer is and why), day-2 GitOps workflow, repo layout, glossary |
| [TESTING.md](TESTING.md) | The regression pipeline and the by-hand validation toolbox |
| [SECURITY-FLOW.md](SECURITY-FLOW.md) | How a request is authenticated and authorized |
| [SOPS-YUBIKEY-MODEL.md](SOPS-YUBIKEY-MODEL.md) | The two-recipient SOPS/YubiKey secret model |
| [THREAT-CATALOG.md](THREAT-CATALOG.md) | Security audit findings |
| [adr/](adr/) | Architecture Decision Records |
| [archive/](archive/) | Superseded guides kept for reference (bare-k3s manual install, earlier image-deploy notes) |
