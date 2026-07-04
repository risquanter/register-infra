# ADR-INFRA-010: SpiceDB Runtime — Helm Deployment, Network Isolation, and Fail-Closed Availability

**Status:** Accepted  
**Date:** 2026-03-17  
**Tags:** spicedb, authorization, zanzibar, gitops, fail-closed

---

## Context

- Layer 2 (fine-grained authorization) requires a Zanzibar-style relationship store that evaluates `check(userId, permission, resource)` against an explicit relationship graph
- SpiceDB is the selected PDP (ADR-024); the application is a pure PEP that calls `check()` and `listAccessible()` — it never writes tuples except a single `seed()` at workspace creation
- SpiceDB is fail-closed: unavailability → 403, not 503 — ADR-INFRA-002 mandates ≥ 2 replicas and a PodDisruptionBudget for any fail-closed component
- PostgreSQL is already deployed in the `infra` namespace (Bitnami chart via ArgoCD); SpiceDB uses it as its backing datastore
- This ADR covers the runtime deployment only; schema lifecycle is a separate concern (ADR-INFRA-011)

---

## Decision

### 1. External Helm Chart in `infra` Namespace via ArgoCD

SpiceDB deploys as an ArgoCD Application using the official `authzed/spicedb` chart, into the `infra` namespace alongside PostgreSQL and Keycloak. This follows the same pattern as the PostgreSQL deployment.

> **⚠ Implementation note (2026-03-18):** The official Helm repo
> `https://authzed.github.io/helm-charts` currently returns 404. Before
> implementing, verify chart availability or evaluate alternatives
> (community chart `pschichtel/spicedb`, local chart wrapping the container
> image, or raw manifests).

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

SpiceDB accepts connections from the register namespace and connects to PostgreSQL within infra. All other traffic is blocked by the existing default-deny policy in infra.

Two distinct ports are needed by different consumers:
- **8443** (HTTPS, gRPC-gateway REST API): used by `AuthorizationServiceSpiceDB` in the register app. `SpiceDbConfig.url` enforces `SecureUrl` (HTTPS-only constraint) — the app connects via SpiceDB's REST transcoding layer, not native gRPC.
- **50051** (gRPC): used by the `zed` CLI in the ARC runner for `zed schema write` (ADR-INFRA-011).

```yaml
# register → spicedb:8443 (HTTPS REST — app AuthorizationServiceSpiceDB via SecureUrl)
- from:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: register
  ports:
  - protocol: TCP
    port: 8443

# runner → spicedb:50051 (gRPC — zed CLI schema write, ADR-INFRA-011)
- from:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: runner
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

---

## Code Smells

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

---

## Implementation

| Location | Pattern |
|----------|--------|
| `infra/argocd/apps/spicedb.yaml` | ArgoCD Application — external chart (Decision §1) |
| `infra/k8s/network-policy/infra.yaml` | Add ingress rules: `register → spicedb:8443` (app HTTPS REST) + `runner → spicedb:50051` (zed CLI gRPC, ADR-INFRA-011) (Decision §3) |
| `infra/secrets/spicedb.enc.yaml` | SOPS-encrypted pre-shared key + datastore URI (Decision §4) |
| `infra/argocd/projects/infra.yaml` | Verify SpiceDB CRDs / resources are whitelisted |

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
- **Why rejected**: permission names in the schema (`design_write`, `analyze_run`, `view_tree`) are referenced by the Scala application code. Splitting them across repos means a permission rename requires coordinated PRs in two repos with no compile-time safety. Schema lifecycle is covered by ADR-INFRA-011.

---

## References

- [ADR-024](../../register/docs/ADR-024.md) — app is pure PEP, SpiceDB is PDP
- [ADR-INFRA-002](ADR-INFRA-002.md) — fail-closed availability guarantees (≥ 2 replicas + PDB)
- [ADR-INFRA-006](ADR-INFRA-006.md) — SOPS-encrypted secrets pattern
- [ADR-INFRA-009](ADR-INFRA-009.md) — BeyondCorp identity model (OPA reads headers, SpiceDB receives userId)
- [ADR-INFRA-011](ADR-INFRA-011.md) — Schema lifecycle: in-cluster runner pattern
- SpiceDB Helm Charts: https://github.com/authzed/helm-charts
- Google Zanzibar (2019): https://research.google/pubs/pub48190/
