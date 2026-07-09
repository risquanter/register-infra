# ADR-INFRA-014: Multi-Environment GitOps Topology

**Status:** Accepted
**Date:** 2026-07-08
**Tags:** gitops, argocd, helm, multi-cluster, environments, blast-radius

---

## Context

- Configuration that differs only by deployment target (image provenance, hostname,
  TLS issuer) drifts silently when hand-edited in a single shared file per change —
  nothing forces the flip back when the target changes again (ADR-INFRA-001).
- A GitOps control plane holding a live credential for a cluster it does not itself
  run on extends that cluster's blast radius to wherever the control plane lives.
- Two independently-operated clusters with different availability profiles (an
  always-on host vs. a laptop that sleeps) should not have one's reconciliation loop
  depend on the other's uptime.
- The number of genuinely environment-specific resources should determine the
  overlay mechanism's complexity — machinery built for large-scale partial patching
  is wasted on a single wholesale-different file, and the reverse leaves no room to
  grow.

---

## Decision

### 1. One ArgoCD instance per cluster — no cross-cluster credentials

```yaml
# Every Application, in both instances, targets only its own cluster:
spec:
  destination:
    server: https://kubernetes.default.svc   # never a remote cluster URL
```

Local's ArgoCD runs on local; Hetzner's runs on Hetzner. Neither is registered as a
remote cluster in the other (no `argocd cluster add`, no stored kubeconfig/API-server
credential crossing the boundary). The only thing they share is the git repository,
which each pulls independently.

### 2. Helm charts: shared `values.yaml` + one overlay file per environment

```yaml
# infra/argocd/apps/register.yaml (separate copy per cluster's ArgoCD instance)
spec:
  source:
    path: infra/helm/register
    helm:
      valueFiles:
        - values.yaml
        - values-local.yaml      # or values-hetzner.yaml on the Hetzner instance
```

Scope, decided by surveying every chart for genuine environment coupling (image
provenance/pull policy, hostname, realm file) rather than applying overlays
uniformly: `register`, `keycloak`, `frontend`, `irmin`. `opa` and `spicedb` pull
digest-pinned images from a public registry identically in both environments and
need no overlay.

### 3. Raw manifests: `shared/` + one directory per environment

```
infra/k8s/
  shared/istio/..., network-policy/..., rbac/..., kyverno/..., opa/...   # 11 of 12 files today
  local/cert-manager/selfsigned-issuer.yaml
  hetzner/cert-manager/acme-issuer.yaml
```

Each cluster's `mesh-policy` Application (now one per cluster, per Decision 1) uses
ArgoCD's multi-source support to sync `infra/k8s/shared` plus its own `infra/k8s/<env>`.

### 4. Default to `shared/`; split only on real divergence

A new raw manifest starts in `shared/`. It only moves to `local/`/`hetzner/` when an
actual value differs between environments — not pre-emptively, and not for internal
cluster-DNS references (`*.svc.cluster.local` resolves identically on any cluster and
is never environment-specific).

---

## Code Smells

### ❌ Hand-edited single values file, flipped in place per environment

```yaml
# BAD: values.yaml edited directly every time the target environment changes
image:
  repository: register-server   # was local/register-server, flipped back and forth
  tag: prod                     # was dev — easy to forget on the next switch
```

```yaml
# GOOD: environment identified by which overlay file is layered on
# values.yaml (shared): replicaCount, resource limits, non-env app config
# values-local.yaml:   repository: local/register-server, tag: dev, pullPolicy: Never
# values-hetzner.yaml: repository: ghcr.io/risquanter/register-server, pullPolicy: IfNotPresent
```

### ❌ Single ArgoCD instance holding a remote cluster credential

```bash
# BAD: local's ArgoCD instance can now reach Hetzner
argocd cluster add hetzner-context
```

```yaml
# GOOD: each cluster's ArgoCD only ever manages itself
spec:
  destination:
    server: https://kubernetes.default.svc
```

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/argocd/apps/*.yaml` (one set per cluster) | `destination.server: https://kubernetes.default.svc` only — never a remote cluster |
| `infra/helm/register/`, `keycloak/`, `frontend/`, `irmin/` | `values.yaml` + `values-local.yaml` / `values-hetzner.yaml` |
| `infra/k8s/shared/`, `infra/k8s/local/`, `infra/k8s/hetzner/` | Raw-manifest environment split |
| `infra/argocd/apps/mesh-policy.yaml` (one per cluster) | Multi-source: `infra/k8s/shared` + `infra/k8s/<env>` |

---

## Alternatives Rejected

### Single ArgoCD instance managing both clusters

- **What**: register Hetzner as a remote cluster in local's ArgoCD (or the reverse) via `argocd cluster add`, with `Application.spec.destination.server` selecting the target per-resource.
- **Why rejected**: requires a live credential for one cluster to be stored in the other, extending that cluster's blast radius — the same shape of risk ADR-INFRA-011 already rejected for CI (exporting a kubeconfig to GitHub Secrets). Also couples one environment's reconciliation loop to the other's uptime: if the instance lives on local, Hetzner stops self-healing whenever the laptop is off. Appropriate at large-fleet scale (many near-identical clusters managed by one team); not for two independently-operated environments.

### Kustomize overlays for raw manifests (`base/` + `overlays/<env>/`)

- **What**: `kustomization.yaml`-driven base + per-environment patches (strategic-merge or JSON6902), natively supported by ArgoCD.
- **Why rejected**: introduces a third composition mechanism alongside Helm (charts, `values-<env>.yaml`) and the plain-YAML directory split (raw manifests, `shared/`+`<env>/`) — two different answers to "how do I add an environment override" depending on what's being touched. Only 1 of 12 current raw manifests is environment-specific, and it's wholesale-different (a self-signed vs. an ACME `ClusterIssuer`, different `spec` shapes entirely) rather than a small patch — Kustomize's core strength (expressing a delta) doesn't pay for its added conceptual surface here. Revisit if patch-shaped divergence (same resource, one differing field) becomes common.

### Ad-hoc carve-out without a directory convention

- **What**: keep `infra/k8s/` flat; move only the `ClusterIssuer` into an ad-hoc per-environment location with its own dedicated, one-off Application.
- **Why rejected**: doesn't generalize. Each new environment-specific file needs both a new location *and* new Application wiring, versus a `<env>/` directory a per-cluster Application already watches by convention. Reasonable at exactly one divergent file; doesn't scale past it.

---

## References

- [ADR-INFRA-001](ADR-INFRA-001.md) — Configuration Single-Source-of-Truth (the general drift problem this ADR applies at the multi-environment scale)
- [ADR-INFRA-011](ADR-INFRA-011.md) — rejected exporting cluster credentials outside the cluster; same reasoning applied to ArgoCD topology here
- [ADR-INFRA-013](ADR-INFRA-013.md) — External Ingress Datapath; the `ClusterIssuer` is the concrete driver that surfaced this decision
- TODO.md § Multi-Environment Values Overlay
