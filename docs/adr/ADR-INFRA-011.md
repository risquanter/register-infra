# ADR-INFRA-011: SpiceDB Schema Lifecycle — In-Cluster CI Runner Pattern

**Status:** Accepted  
**Date:** 2026-03-17  
**Tags:** spicedb, schema, ci-runner, gitops, vendor-agnostic

---

## Context

- The SpiceDB schema (`schema.zed`) lives in the application repo alongside the Scala code that references permission names — atomic changes within a single PR ensure compile-time safety
- Schema provisioning requires a trigger (git push → schema apply) and network access to SpiceDB inside the cluster — external CI leaks cluster credentials; in-cluster runners keep the blast radius contained
- The `ci-authz` RBAC role was designed for a K8s Job + ConfigMap pattern that is superseded by this decision — the in-cluster runner checks out the repo natively and calls SpiceDB over gRPC, not via the K8s API
- The SpiceDB pre-shared key must reach the runner pod without leaving the cluster — ADR-INFRA-006 mandates per-namespace SOPS secrets, so the runner namespace gets its own encrypted copy
- This decision is vendor-agnostic: GitHub Actions is the current implementation vehicle, not the architectural commitment

---

## Decision

### 1. In-Cluster CI Runner — Architectural Pattern

A CI runner pod runs inside the Kubernetes cluster, registered with the CI system. On git push, the CI system dispatches the job to the runner. The runner checks out the repo, runs `zed schema write` against `spicedb.infra:50051` over the cluster network, and reports results to the CI UI. No cluster credentials leave the cluster.

```
Architectural pattern (vendor-agnostic):
  git push → CI system webhook → in-cluster runner pod → zed schema write

Invariants (must hold regardless of CI vendor):
  1. Runner pod has network access to spicedb.infra:50051 (NetworkPolicy)
  2. Runner pod has repo checkout (CI-native, e.g. actions/checkout)
  3. SpiceDB pre-shared key delivered via CI secret or mounted SOPS volume
  4. No kubeconfig or cluster credentials stored outside the cluster
  5. Schema + code atomicity: same CI run that compiles the code applies the schema
```

### 2. Conformant CI Implementations

GitHub Actions (ARC) is the current vehicle. Replacement with any system below requires no changes to the SpiceDB runtime, NetworkPolicy, or secret delivery pattern — only the runner controller Helm chart changes.

```
Conformant implementations:
  GitHub Actions    → actions-runner-controller (ARC)
  Gitea / Forgejo   → act_runner as Deployment
  Woodpecker CI     → woodpecker-agent as Deployment
  Tekton            → EventListener → TaskRun
  Drone / Gitness   → runner-kube
  Jenkins           → kubernetes-plugin (pod-template agents)
```

### 3. Application Repo Owns Schema, CI Applies

The schema file (`schema.zed`) lives in the **application repo**. Schema changes ship in the same PR as the Scala code that references new permissions. The infra repo deploys the SpiceDB runtime only (ADR-INFRA-010).

```
Application repo CI workflow (GitHub Actions example):
  runs-on: [self-hosted, k3s-prod]
  steps:
    1. actions/checkout
    2. zed schema write --endpoint spicedb.infra:50051 < infra/spicedb/schema.zed
    3. zed schema read → diff against expected → fail on drift
    4. Integration tests exercise check() against updated schema
```

### 4. Secret Delivery — Per-Namespace SOPS Copy

The SpiceDB pre-shared key is duplicated as a SOPS-encrypted secret in the runner namespace, consistent with ADR-INFRA-006's per-namespace pattern. The runner's ServiceAccount needs no K8s API RBAC for schema apply — only gRPC network access to SpiceDB.

```yaml
# infra/secrets/runner-spicedb-token.enc.yaml
apiVersion: v1
kind: Secret
metadata:
  name: spicedb-preshared-key
  namespace: runner
type: Opaque
stringData:
  token: ENC[AES256_GCM,...]    # SOPS-encrypted, same age key
```

### 5. Runner NetworkPolicy — Scoped Egress to SpiceDB

The runner namespace gets a default-deny policy. The only allowed egress is to `spicedb.infra:50051` and DNS.

```yaml
# runner → spicedb:50051 (gRPC schema write + tuple reconcile)
egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: infra
      podSelector:
        matchLabels:
          app.kubernetes.io/name: spicedb
    ports:
    - protocol: TCP
      port: 50051
```

---

## Code Smells

### ❌ Schema Managed by Infrastructure Helm Chart

```yaml
# BAD: schema.zed baked into the Helm chart values.
# Schema changes require infra PR — decouples permission names
# from the Scala code that references them.
valuesObject:
  bootstrap:
    schema: |
      definition user {}
      definition workspace { ... }
```

```yaml
# GOOD: Helm chart deploys runtime only (ADR-INFRA-010).
# Schema applied by in-cluster CI runner from app repo checkout.
valuesObject:
  bootstrap:
    schema: ""   # empty — CI applies schema via zed CLI
```

### ❌ External CI Applies Schema via Port-Forward

```yaml
# BAD: CI runner outside cluster opens a tunnel to apply schema.
# Requires kubeconfig in CI secrets — credentials leave the cluster.
steps:
  - run: kubectl port-forward svc/spicedb 50051:50051 &
  - run: zed schema write --endpoint localhost:50051
```

```yaml
# GOOD: in-cluster runner has direct network access. No credentials exported.
runs-on: [self-hosted, k3s-prod]
steps:
  - run: zed schema write --endpoint spicedb.infra:50051
```

### ❌ Runner Has Broad K8s API RBAC

```yaml
# BAD: runner SA has configmap/job/pod RBAC for a superseded pattern.
# The in-cluster runner uses gRPC to SpiceDB, not K8s API calls.
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "create", "delete"]
```

```yaml
# GOOD: runner SA needs no K8s API RBAC for schema apply.
# Access is enforced by NetworkPolicy (gRPC to spicedb:50051)
# and SpiceDB pre-shared key (mounted as secret).
# Only minimal RBAC for ARC internal bookkeeping, if any.
```

---

## Implementation

| Location | Pattern |
|----------|--------|
| `infra/argocd/apps/arc.yaml` (planned) | ARC controller — in-cluster runner (Decision §1) |
| `infra/k8s/network-policy/runner.yaml` (planned) | Runner namespace → infra:50051 egress (Decision §5) |
| `infra/secrets/runner-spicedb-token.enc.yaml` (planned) | SOPS-encrypted pre-shared key for runner namespace (Decision §4) |
| `infra/k8s/rbac/roles.yaml` | `ci-authz` role to be redesigned — see Code Smells §3 |
| register repo: `infra/spicedb/schema.zed` | Schema source of truth (Decision §3) |
| register repo: `.github/workflows/authz.yaml` | `zed schema write` on self-hosted runner (Decision §1) |

---

## Alternatives Rejected

### External CI with kubectl port-forward

- **What**: GitHub Actions (cloud-hosted runner) opens `kubectl port-forward` to SpiceDB, then runs `zed schema write` locally
- **Why rejected**: requires kubeconfig stored in GitHub Secrets — cluster credentials leave the cluster. Port-forward window is an attack surface during each CI run. Acceptable as a temporary bootstrap step but not as the steady-state schema lifecycle.

### In-Cluster Kubernetes Job Triggered by Webhook Receiver

- **What**: deploy Argo Events or Tekton Triggers to receive a GitHub webhook, which creates a K8s Job running `zed schema write`
- **Why rejected**: the Job still needs repo access (deploy key or ConfigMap push from external CI), reintroducing the credential-export problem it was meant to solve. Adds an eventing subsystem (webhook endpoint + event source + sensor/trigger) without eliminating external cluster credentials. The in-cluster CI runner pattern achieves the same network locality with native repo checkout and CI UI integration.

### Schema in ConfigMap, K8s Job Reads It

- **What**: external CI pushes `schema.zed` into a ConfigMap; a K8s CronJob or triggered Job reads the ConfigMap and runs `zed schema write`
- **Why rejected**: two-step dependency (CI updates ConfigMap → Job reads it) with no atomicity guarantee. The `ci-authz` RBAC role was designed for this pattern but it's superseded by the in-cluster runner which gets the schema from `git checkout` directly.

---

## References

- [ADR-INFRA-010](ADR-INFRA-010.md) — SpiceDB runtime deployment (Helm + ArgoCD + NetworkPolicy)
- [ADR-INFRA-006](ADR-INFRA-006.md) — SOPS-encrypted secrets, per-namespace pattern
- [ADR-INFRA-003](ADR-INFRA-003.md) — AppProject scoping (ARC needs project coverage)
- [ADR-INFRA-005](ADR-INFRA-005.md) — Testing strategy (dual CI topology: cloud for static, in-cluster for schema)
- [ADR-024](../../register/docs/ADR-024.md) — app is pure PEP, PAP is ops tooling (`AuthzProvisioning` + `zed` CLI)
- ARC: https://github.com/actions/actions-runner-controller
