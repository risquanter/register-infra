# ADR-INFRA-012: Supply Chain Defence — External Dependency Governance

**Status:** Accepted
**Date:** 2026-07-05
**Tags:** supply-chain, security, dependencies, helm, container-images, github-actions

---

## Context

- Every external artifact pulled into the project — container image, Helm chart, GitHub Action, Terraform provider, IDE extension, CLI plugin — is a potential code execution vector. The attack surface is not limited to the artifact itself; a compromised publisher account or a malicious update to a trusted artifact is sufficient for a full compromise.
- Three distinct supply chain attack vectors operate independently: (1) **account takeover** — the legitimate publisher's credentials are stolen and a malicious version is published under the trusted name; (2) **dependency confusion** — an attacker publishes a package with the same name on a public registry that a private registry would resolve first; (3) **typosquatting** — a package named close enough to a trusted one that humans miss the difference.
- The blast radius of a compromised artifact scales with what it executes on and what it can reach. A Helm chart that installs cluster-level webhooks has unbounded reach. A container image that runs as a non-root pod in a default-deny namespace has scoped reach. A local CLI tool used only in dev has no cluster reach. The verification requirements must scale accordingly.
- Vendor identity and chart/package maintainership are frequently decoupled. The entity that writes the software is often not the entity that maintains the most popular community distribution package. Popularity, GitHub stars, and age are not proxies for security.
- Cooldown periods exist because compromised artifacts and accidental breaking changes are typically discovered within days to weeks of release by the broader community. Delayed adoption harvests that community signal at zero cost.
- Alert fatigue from ad-hoc sourcing normalises accepting unreviewed external inputs. Once that norm is established, distinguishing a deliberate policy exception from a lazy shortcut becomes impossible.

---

## Decision

### 1. Blast Radius Tiers

Every external artifact is classified before adoption. Classification determines the verification requirements and cooldown period.

| Tier | What qualifies | Examples |
|---|---|---|
| **T1 — Cluster-privileged** | Executes on the cluster with access to secrets, network, or cluster-level RBAC | Helm charts installing CRDs / webhooks / ClusterRoles; Terraform providers with cloud credentials; GitHub Actions on self-hosted in-cluster runners |
| **T2 — Cluster-scoped** | Executes on the cluster within a namespace boundary, no cluster-level permissions | Application container images; Helm charts for single-namespace workloads |
| **T3 — CI / build-time** | Executes in CI on hosted runners; no direct cluster access | GitHub Actions on hosted runners; build tools; linters |
| **T4 — Dev environment** | Executes only on a developer machine; no cluster or CI access | IDE extensions; local CLI plugins; dev scripts |

### 2. Vendor Identity Requirement (all tiers)

An artifact may only be sourced from the **primary vendor organisation** — the entity that owns the software and publishes its container image or canonical release. For each artifact, answer: "If this publisher were compromised, who would I call?" If the answer is not the software vendor, the source is wrong.

- Community forks, mirrors, and third-party distributions are rejected at all tiers.
- Aggregator repositories (e.g. `helm/charts`, npm mirror registries) are rejected at all tiers.
- For T1/T2 Helm charts: if the vendor does not publish an official chart, write a local chart. This is always the correct fallback — never substitute a community chart.

### 3. Pinning Requirement (all tiers)

Every artifact is pinned to an immutable reference. Mutable tags (`latest`, `main`, version ranges) are prohibited.

| Artifact type | Pin target |
|---|---|
| Container image | Digest (`sha256:...`). Tag is documentation only. Image Updater writes digests. |
| Helm chart | Exact `targetRevision` string (`"18.5.5"`, `"3.7.1"`) |
| GitHub Action | Full commit SHA (`uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683`) |
| Terraform provider | Exact version constraint (`version = "= 1.9.8"`) in `versions.tf` |
| IDE extension | Specific version in `.vscode/extensions.json` or equivalent lockfile |

### 4. Cooldown Periods

No artifact is adopted at the moment of its release. The following minimum waiting periods apply from the artifact's public release date before it may be introduced or upgraded in this repo:

| Tier | New adoption | Patch update | Minor update | Major update |
|---|---|---|---|---|
| **T1** | 90 days | 14 days | 30 days | 90 days + explicit review |
| **T2** | 30 days | 7 days | 14 days | 30 days |
| **T3** | 14 days | 3 days | 7 days | 14 days |
| **T4** | 7 days | immediate | 7 days | 14 days |

The clock starts when the release is publicly available, not when we become aware of it. The purpose is to harvest community-reported issues (CVEs, breaking changes, malicious commits) before they reach this repo.

Exception: a security patch for a confirmed CVE in a currently deployed artifact may bypass the cooldown. The bypass must be documented in the commit message with the CVE identifier.

### 5. Security Disclosure Requirement (T1 and T2)

Before adopting any T1 or T2 artifact, confirm the vendor has a documented security disclosure process: a `SECURITY.md`, a CVE programme, or a named security contact. An artifact with no disclosure path cannot be monitored for vulnerabilities. Document the disclosure URL in the approval record.

### 6. Approval Record

Every newly introduced or upgraded external artifact at T1 or T2 requires a comment in the consuming manifest or lockfile stating:

```yaml
# Vendor: <org name> — <URL confirming vendor identity>
# Security disclosure: <URL>
# Pinned: <exact version or digest>
# Cooldown elapsed: <release date> → adopted <date> (<N days>)
# Approved: ADR-INFRA-012. Reviewed: <date>
```

### 7. Local Chart as Default for Helm (T1/T2 specific)

When a vendor does not publish an official Helm chart, write a local chart under `infra/helm/`. A chart for a single Deployment + Service + Secret reference is 50–100 lines of YAML. The authorship cost is low; the supply chain cost of substituting a community chart is unbounded.

Currently approved upstream Helm charts (all others require a new entry in this table):

| Chart | Vendor repo | Cooldown elapsed | Reviewed |
|---|---|---|---|
| `bitnami/postgresql` | `https://charts.bitnami.com/bitnami` | Pre-ADR | 2026-07-05 |
| `kyverno/kyverno` | `https://kyverno.github.io/kyverno/` | Pre-ADR | 2026-07-05 |

---

## Code Smells

### ❌ Community Chart Instead of Local Chart

```yaml
# BAD: pschichtel is not the SpiceDB vendor (authzed is).
# Fails vendor identity requirement. Rejected unconditionally.
source:
  repoURL: https://pschichtel.github.io/spicedb/
  chart: spicedb
```

```yaml
# GOOD: local chart. Official chart unavailable → write our own.
# Container image from ghcr.io/authzed/spicedb is the only external artifact.
source:
  repoURL: git@github.com:risquanter/register-infra.git
  path: infra/helm/spicedb
  targetRevision: HEAD
```

### ❌ Mutable Reference

```yaml
# BAD: floating chart version — silent drift on next sync.
targetRevision: ">=18.0.0"

# BAD: mutable image tag — cannot verify what was deployed.
image: ghcr.io/authzed/spicedb:latest
```

```yaml
# GOOD: immutable references.
targetRevision: "18.5.5"
image: ghcr.io/authzed/spicedb@sha256:a1b2c3...
```

### ❌ GitHub Action Pinned to Tag

```yaml
# BAD: the tag can be moved to point at a different commit.
- uses: actions/checkout@v4
```

```yaml
# GOOD: SHA pin — tag is documentation only.
# actions/checkout v4.2.2
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
```

### ❌ No Approval Record on New Dependency

```yaml
# BAD: no trace of who approved this, when, or why it was trusted.
source:
  repoURL: https://charts.bitnami.com/bitnami
  chart: postgresql
  targetRevision: "18.5.5"
```

```yaml
# GOOD: approval record present.
source:
  # Vendor: Bitnami (VMware) — https://github.com/bitnami/charts
  # Security disclosure: https://github.com/bitnami/charts/security/policy
  # Pinned: 18.5.5 (exact)
  # Cooldown elapsed: pre-ADR baseline
  # Approved: ADR-INFRA-012. Reviewed: 2026-07-05.
  repoURL: https://charts.bitnami.com/bitnami
  chart: postgresql
  targetRevision: "18.5.5"
```

---

## Implementation

| Location | Pattern |
|---|---|
| `infra/helm/*/` | Local charts — T2 default pattern (ADR §7) |
| `infra/argocd/apps/postgresql.yaml` | T1 approved upstream with approval record |
| `infra/argocd/apps/kyverno.yaml` | T1 approved upstream with approval record |
| `infra/argocd/apps/spicedb.yaml` (planned) | Local chart — official T1 chart unavailable |
| `.github/workflows/*.yaml` | GitHub Actions pinned to SHA (T3) |

---

## Alternatives Rejected

### Official authzed Helm chart (`https://authzed.github.io/helm-charts`)

- **What**: The SpiceDB vendor publishes a chart at this URL.
- **Why not used at time of writing**: URL returns HTTP 200 with HTML (GitHub Pages placeholder) — no `index.yaml` served. The chart does not exist as a usable registry. Re-evaluate if this changes; it would satisfy the vendor identity requirement.

### Community chart (`pschichtel/spicedb`)

- **What**: An individual-maintained Helm chart for SpiceDB.
- **Why rejected**: Fails vendor identity requirement (Decision §2). Not the primary vendor org. Rejected unconditionally regardless of quality or coverage.

### Adopt-on-release (no cooldown)

- **What**: Use the latest available version immediately.
- **Why rejected**: The window between a malicious release and community discovery is hours to days. A cooldown harvests that signal at zero cost. The only exception is a CVE patch for a confirmed vulnerability in a currently deployed artifact.

---

## References

- CISA / NSA: *Defending Against Software Supply Chain Attacks* (2021)
- OpenSSF SLSA framework: https://slsa.dev
- Sigstore / Cosign (container image signing): https://www.sigstore.dev
- GitHub: *Keeping your GitHub Actions and workflows secure* — SHA pinning guidance


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

Every new workload deployed via ArgoCD uses a local Helm chart under `infra/helm/`. The chart is authored here, reviewed here, and version-controlled here. The external artifact is the container image only, pinned by digest.

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

**Currently approved upstream charts:**

| Chart | Vendor repo | Rationale |
|---|---|---|
| `bitnami/postgresql` | `https://charts.bitnami.com/bitnami` | Bitnami is the authoritative chart publisher for this image; chart complexity (StatefulSet, PVC, initdb, PDB, metrics) exceeds cost of local replication |
| `kyverno/kyverno` | `https://kyverno.github.io/kyverno/` | CNCF-graduated project; chart publisher is the primary maintainer org; CRD count (22) makes local chart maintenance impractical |

Any new upstream chart requires an ADR amendment or a new ADR entry in this table before it may be added.

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
  # Approved upstream per ADR-INFRA-012 §2. Reviewed: 2026-07-05.
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
| `infra/argocd/apps/spicedb.yaml` (planned) | Local chart — official chart unavailable |

---

## Alternatives Rejected

### Official authzed Helm chart (`https://authzed.github.io/helm-charts`)

- **What**: The SpiceDB vendor publishes a chart at this URL.
- **Why rejected at time of writing**: The URL returns HTTP 200 with HTML (GitHub Pages placeholder) — no `index.yaml` is served. The chart does not exist as a usable registry. When this changes, the URL can be re-evaluated against the §2 conditions and the implementation table updated.

### Community chart (`pschichtel/spicedb`)

- **What**: An individual-maintained chart for SpiceDB hosted at `https://pschichtel.github.io/spicedb/`.
- **Why rejected**: The maintainer is not affiliated with authzed. The chart repository has no relationship to authzed's release pipeline, signing, or CVE process. Pulling it introduces an uncontrolled code execution path on the cluster. Rejected unconditionally per Decision §3.
