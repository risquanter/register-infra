# ADR-INFRA-016: Helm Chart Sourcing — Local Charts by Default

**Status:** Accepted
**Date:** 2026-07-05
**Tags:** supply-chain, helm, gitops, security, dependencies

---

## Context

- A Helm chart is executable infrastructure: it renders into Kubernetes manifests that create workloads, RBAC, webhooks, and network policy on the cluster. Pulling a chart from an uncontrolled source is equivalent to executing unreviewed code with cluster-admin reach.
- The software vendor and the chart maintainer are often different entities. A community chart hosted by an individual (e.g. `pschichtel/spicedb`) carries no guarantee of alignment with the vendor's security posture, no SLA for CVE response, and no auditable commit history from the authoritative source.
- Writing a local Helm chart for a single Deployment + Service + Secret reference is 50–100 lines of YAML. The cost of authorship is low; the cost of a compromised chart dependency is unbounded.
- The container image is the only irreducible external artifact. Everything else — chart templates, values, network policy, RBAC — can and should be authored in this repo, reviewed in pull requests, and pinned to a specific git SHA.
- Alert fatigue caused by ad-hoc sourcing decisions normalises the behaviour of accepting unreviewed external inputs, which is the precondition for supply chain compromise.

---

## Decision

### 1. Local Chart by Default

Every new workload deployed via ArgoCD uses a local Helm chart under `infra/helm/`. The chart is authored here, reviewed here, and version-controlled here. The external artifact is the container image only, pinned by digest. Tier classification, cooldown periods, and the approval-record format for that image are governed by ADR-INFRA-012.

```
infra/helm/<workload>/
  Chart.yaml
  values.yaml
  templates/
    deployment.yaml
    service.yaml
    ...
```

### 2. Official Vendor Chart as Named Exception

An upstream Helm chart may be used **only** when all three conditions are met:

| Condition | What it means |
|---|---|
| **Official maintainer** | The chart repository is owned and published by the software's primary vendor organisation — the same entity that publishes the container image and signs releases. Community forks, mirrors, and individual-maintained charts do not qualify regardless of popularity or version coverage. |
| **Accessible and pinned** | The chart repository URL resolves and returns a valid `index.yaml`. The chart version is pinned to an exact `targetRevision` — never a range or `latest`. |
| **Documented rationale** | The ArgoCD Application manifest includes a comment stating the vendor org, why a local chart is not preferred, and the date the decision was reviewed. |

The authoritative registry of approved upstream charts is the table in ADR-INFRA-012 §7; any new upstream chart requires a new entry there before it may be added. Rationale for the current entries:

| Chart | Vendor repo | Rationale |
|---|---|---|
| `bitnami/postgresql` | `https://charts.bitnami.com/bitnami` | Bitnami is the authoritative chart publisher for this image; chart complexity (StatefulSet, PVC, initdb, PDB, metrics) exceeds cost of local replication |
| `kyverno/kyverno` | `https://kyverno.github.io/kyverno/` | CNCF-graduated project; chart publisher is the primary maintainer org; CRD count (22) makes local chart maintenance impractical |

### 3. No Community Charts, Ever

A chart published by anyone other than the primary vendor organisation is rejected unconditionally. This includes:

- Community mirrors (`pschichtel/spicedb`, `bitnami-labs/*`, etc.)
- Aggregator repositories (`helm/charts`, `stakater/*`, etc.)
- Individual forks regardless of GitHub stars, age, or apparent maintenance quality

The correct response when an official chart is unavailable is to write a local chart. This takes less time than the security review that a community chart would require — and that review would still be insufficient without access to the vendor's CI pipeline.

### 4. Mandatory Verification Before Adding Any Upstream Source

Before adding a `repoURL` pointing to a Helm registry:

```bash
# 1. Confirm the URL is owned by the vendor org (check GitHub/docs)
# 2. Confirm it resolves
curl -sI <repoURL>/index.yaml | head -3   # must return HTTP 200
# 3. Pin the exact version
helm search repo <chart> --versions | head -5
```

If the URL returns non-200, the official chart does not exist. Write a local chart.

---

## Code Smells

### ❌ Community Chart in ArgoCD Application

```yaml
# BAD: pschichtel is not the SpiceDB vendor (authzed.com is).
# This chart has no relationship to authzed's release pipeline.
source:
  repoURL: https://pschichtel.github.io/spicedb/
  chart: spicedb
  targetRevision: "1.2.3"
```

```yaml
# GOOD: local chart — vendor is the container image only.
source:
  repoURL: git@github.com:risquanter/register-infra.git
  path: infra/helm/spicedb
  targetRevision: HEAD
```

### ❌ Upstream Chart Without Verification Comment

```yaml
# BAD: no rationale — future readers cannot distinguish
# approved upstream from unapproved.
source:
  repoURL: https://charts.bitnami.com/bitnami
  chart: postgresql
```

```yaml
# GOOD: vendor identity and approval rationale documented.
source:
  # Bitnami is the authoritative chart publisher for this image.
  # Approved upstream per ADR-INFRA-016 §2. Reviewed: 2026-07-05.
  repoURL: https://charts.bitnami.com/bitnami
  chart: postgresql
  targetRevision: "18.5.5"   # pinned — never a range
```

### ❌ Unpinned Chart Version

```yaml
# BAD: floating version — next ArgoCD sync may pull a different chart.
targetRevision: ">=1.0.0"
# or
targetRevision: latest
```

```yaml
# GOOD: exact pin reviewed and recorded.
targetRevision: "18.5.5"
```

---

## Implementation

| Location | Pattern |
|---|---|
| `infra/helm/*/` | All local charts — default pattern |
| `infra/argocd/apps/postgresql.yaml` | Approved upstream with rationale comment |
| `infra/argocd/apps/kyverno.yaml` | Approved upstream with rationale comment |
| `infra/argocd/apps/spicedb.yaml` | Local chart — official chart unavailable |

---

## Alternatives Rejected

### Official authzed Helm chart (`https://authzed.github.io/helm-charts`)

- **What**: The SpiceDB vendor publishes a chart at this URL.
- **Why rejected at time of writing**: The URL returns HTTP 200 with HTML (GitHub Pages placeholder) — no `index.yaml` is served. The chart does not exist as a usable registry. When this changes, the URL can be re-evaluated against the §2 conditions and the implementation table updated.

### Community chart (`pschichtel/spicedb`)

- **What**: An individual-maintained chart for SpiceDB hosted at `https://pschichtel.github.io/spicedb/`.
- **Why rejected**: The maintainer is not affiliated with authzed. The chart repository has no relationship to authzed's release pipeline, signing, or CVE process. Pulling it introduces an uncontrolled code execution path on the cluster. Rejected unconditionally per Decision §3.

---

## References

- ADR-INFRA-012 — Supply Chain Defence (blast-radius tiers, cooldowns, pinning, approval records; approved-upstream chart registry in §7)
