# ADR-INFRA-010: SpiceDB Infrastructure — Helm Deployment, Network Isolation, and Schema Lifecycle

**Status:** Accepted  
**Date:** 2026-03-17  
**Tags:** spicedb, authorization, zanzibar, gitops, fail-closed

---

## Context

- Layer 2 (fine-grained authorization) requires a Zanzibar-style relationship store that evaluates `check(userId, permission, resource)` against an explicit relationship graph
- SpiceDB is the selected PDP (ADR-024); the application is a pure PEP that calls `check()` and `listAccessible()` — it never writes tuples except a single `seed()` at workspace creation
- SpiceDB is fail-closed: unavailability → 403, not 503 — ADR-INFRA-002 mandates ≥ 2 replicas and a PodDisruptionBudget for any fail-closed component
- The schema (`schema.zed`) lives in the application repo alongside the Scala code that references permission names — infrastructure manages the runtime, not the schema content
- Schema provisioning requires a trigger (git push → schema apply) and network access to SpiceDB inside the cluster — external CI leaks cluster credentials; in-cluster runners keep the blast radius contained
- PostgreSQL is already deployed in the `infra` namespace (Bitnami chart via ArgoCD); SpiceDB uses it as its backing datastore

---

## Decision

### 1. External Helm Chart in `infra` Namespace via ArgoCD

SpiceDB deploys as an ArgoCD Application using the official `authzed/spicedb` chart, into the `infra` namespace alongside PostgreSQL and Keycloak. This follows the same pattern as the PostgreSQL deployment.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: spicedb
  namespace: argocd
spec:
  project: infra
  source:
    repoURL: https://authzed.github.io/helm-charts
    chart: spicedb
    targetRevision: "<pinned-version>"
    helm:
      releaseName: spicedb
      valuesObject:
        replicaCount: 2
        dispatch:
          enabled: true
        datastore:
          engine: postgres
          connUri:
            secretRef: spicedb-datastore-uri
        grpc:
          presharedKey:
            secretRef: spicedb-preshared-key
  destination:
    server: https://kubernetes.default.svc
    namespace: infra
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

### 2. Fail-Closed Availability — Two Replicas + PDB

Per ADR-INFRA-002, every `failure_mode_deny: true` component requires ≥ 2 replicas and a PodDisruptionBudget. SpiceDB is fail-closed (app treats any SpiceDB error as 403), so:

```yaml
replicaCount: 2

podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

### 3. NetworkPolicy — Explicit Cross-Namespace Flows

SpiceDB accepts gRPC from the register namespace and connects to PostgreSQL within infra. All other traffic is blocked by the existing default-deny policy in infra.

```yaml
# register → spicedb:50051 (gRPC CheckPermission / LookupResources)
- from:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: register
  ports:
  - protocol: TCP
    port: 50051

# spicedb → postgresql:5432 (datastore)
- to:
  - podSelector:
      matchLabels:
        app.kubernetes.io/name: postgresql
  ports:
  - protocol: TCP
    port: 5432
```

### 4. Secrets — SOPS-Encrypted, Per-Namespace

Two secrets follow the ADR-INFRA-006 pattern (SOPS + age/YubiKey):

| Secret | Content | Consumers |
|--------|---------|-----------|
| `spicedb-preshared-key` | Pre-shared gRPC API token | SpiceDB pods, register app |
| `spicedb-datastore-uri` | `postgres://spicedb:...@postgresql.infra:5432/spicedb` | SpiceDB pods |

```bash
# Encrypt with SOPS (same keyring as keycloak.enc.yaml / postgres.enc.yaml)
sops --encrypt --age <age-public-key> spicedb.enc.yaml > infra/secrets/spicedb.enc.yaml
```

### 5. Schema Lifecycle — Application Repo Owns Schema, In-Cluster Runner Applies

The schema file (`schema.zed`) lives in the **application repo** — not this infrastructure repo. Schema changes ship in the same PR as the Scala code that references new permissions, enabling atomic CI validation.

The architectural decision is **in-cluster CI runner** — a runner pod registered with the CI system, running inside the Kubernetes cluster. The runner checks out the repo, runs `zed schema write` against `spicedb.infra:50051` over the cluster network, and reports results back to the CI system UI. No cluster credentials leave the cluster.

GitHub Actions (via actions-runner-controller / ARC) is the current **implementation vehicle**, not the decision itself. Any CI system that supports in-cluster runners is a conformant implementation:

```
Architectural pattern (vendor-agnostic):
  git push → CI system webhook → in-cluster runner pod → zed schema write

Conformant implementations:
  GitHub Actions    → actions-runner-controller (ARC)
  Gitea / Forgejo   → act_runner as Deployment
  Woodpecker CI     → woodpecker-agent as Deployment
  Tekton            → EventListener → TaskRun
  Drone / Gitness   → runner-kube
  Jenkins           → kubernetes-plugin (pod-template agents)

Invariant across all implementations:
  1. Runner pod has network access to spicedb.infra:50051 (NetworkPolicy)
  2. Runner pod has repo checkout (CI-native, e.g. actions/checkout)
  3. SpiceDB pre-shared key is injected as CI secret or mounted volume
  4. No kubeconfig or cluster credentials stored outside the cluster
  5. Schema + code atomicity: same CI run that compiles the code applies the schema
```

```
Application repo CI workflow (GitHub Actions example):
  runs-on: [self-hosted, k3s-prod]
  steps:
    1. actions/checkout
    2. zed schema write --endpoint spicedb.infra:50051 < infra/spicedb/schema.zed
    3. zed schema read → diff against expected → fail on drift
    4. Integration tests exercise check() against updated schema

Infrastructure repo:
  - Deploys SpiceDB runtime only (Helm + ArgoCD)
  - Deploys runner controller (ARC Helm chart + RunnerDeployment)
  - NetworkPolicy: runner namespace → infra:50051
  - Does NOT contain or manage schema.zed
```

---

## Code Smells

### ❌ Schema Managed by Infrastructure Helm Chart

```yaml
# BAD: schema.zed baked into the Helm chart values.
# Schema changes require infra PR instead of app PR — decouples
# permission names from the Scala code that references them.
valuesObject:
  bootstrap:
    schema: |
      definition user {}
      definition workspace { ... }
```

```yaml
# GOOD: Helm chart deploys runtime only. Schema applied by CI job
# in the application repo where permission names are compile-checked.
valuesObject:
  bootstrap:
    schema: ""   # empty — CI applies schema via zed CLI
```

### ❌ Single Replica for Fail-Closed Component

```yaml
# BAD: one replica means a single pod restart causes 403 for all users.
replicaCount: 1
```

```yaml
# GOOD: ADR-INFRA-002 — fail-closed components need ≥ 2 replicas + PDB.
replicaCount: 2
podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

### ❌ Shared Pre-Shared Key Across Environments

```yaml
# BAD: same presharedKey in dev and prod.
# Compromised dev key grants prod access.
grpc:
  presharedKey: "same-key-everywhere"
```

```yaml
# GOOD: per-environment SOPS-encrypted secret, distinct key per cluster.
grpc:
  presharedKey:
    secretRef: spicedb-preshared-key    # decrypted by ArgoCD SOPS plugin
```

### ❌ External CI Applies Schema via Port-Forward

```yaml
# BAD: CI runner outside cluster opens a tunnel to apply schema.
# Requires kubeconfig in CI secrets — cluster credentials leave the cluster.
# Port-forward window is an attack surface during every CI run.
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

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/argocd/apps/spicedb.yaml` | ArgoCD Application — external chart (Decision §1) |
| `infra/k8s/network-policy/infra.yaml` | Add ingress rule: register → spicedb:50051 (Decision §3) |
| `infra/secrets/spicedb.enc.yaml` | SOPS-encrypted pre-shared key + datastore URI (Decision §4) |
| `infra/argocd/projects/infra.yaml` | Verify SpiceDB CRDs / resources are whitelisted |
| `infra/argocd/apps/arc.yaml` (planned) | ARC controller — in-cluster runner (Decision §5) |
| `infra/k8s/network-policy/runner.yaml` (planned) | Runner namespace → infra:50051 (Decision §5) |
| register repo: `infra/spicedb/schema.zed` | Schema source of truth (Decision §5) |
| register repo: CI workflow | `zed schema write` on self-hosted runner (Decision §5) |

---

## Alternatives Rejected

### SpiceDB Operator (authzed/spicedb-operator)

- **What**: deploy SpiceDB via the official Kubernetes operator and `SpiceDBCluster` CRD
- **Why rejected**: adds an operator lifecycle (CRD upgrades, RBAC for operator SA, controller availability). The Helm chart is simpler — one ArgoCD Application with pinned version. Operator benefits (automated migration, version rollout) are not needed at current scale (single cluster, 2 replicas).

### In-Memory Datastore

- **What**: run SpiceDB with `--datastore-engine=memory` to avoid PostgreSQL dependency
- **Why rejected**: in-memory mode loses all relationships on restart. Schema and tuples must survive pod restarts. PostgreSQL is already deployed, incurs no additional infrastructure cost.

### Schema Managed in Infrastructure Repo

- **What**: store `schema.zed` in `infra/spicedb/` and apply via Helm bootstrap or ArgoCD hook
- **Why rejected**: permission names in the schema (`design_write`, `analyze_run`, `view_tree`) are referenced by the Scala application code. Splitting them across repos means a permission rename requires coordinated PRs in two repos with no compile-time safety. Keeping schema in the app repo enables atomic changes and CI validation.

### External CI with kubectl port-forward

- **What**: GitHub Actions (cloud-hosted runner) opens `kubectl port-forward` to SpiceDB, then runs `zed schema write` locally
- **Why rejected**: requires kubeconfig stored in GitHub Secrets — cluster credentials leave the cluster. Port-forward window is an attack surface during each CI run. Acceptable as a temporary bootstrap step but not as the steady-state schema lifecycle.

### In-Cluster Kubernetes Job Triggered by Webhook Receiver

- **What**: deploy Argo Events or Tekton Triggers to receive a GitHub webhook, which creates a K8s Job running `zed schema write`
- **Why rejected**: the Job still needs repo access (deploy key or ConfigMap push from external CI), reintroducing the credential-export problem it was meant to solve. Adds an eventing subsystem (webhook endpoint + event source + sensor/trigger) without eliminating external cluster credentials. The in-cluster CI runner pattern achieves the same network locality with native repo checkout and CI UI integration.

---

## References

- [ADR-024](../../register/docs/ADR-024.md) — app is pure PEP, SpiceDB is PDP
- [ADR-INFRA-002](ADR-INFRA-002.md) — fail-closed availability guarantees (≥ 2 replicas + PDB)
- [ADR-INFRA-006](ADR-INFRA-006.md) — SOPS-encrypted secrets pattern
- [ADR-INFRA-009](ADR-INFRA-009.md) — BeyondCorp identity model (OPA reads headers, SpiceDB receives userId)
- SpiceDB Helm Charts: https://github.com/authzed/helm-charts
- Google Zanzibar (2019): https://research.google/pubs/pub48190/
