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

When a vendor does not publish an official Helm chart, write a local chart under `infra/helm/`. A chart for a single Deployment + Service + Secret reference is 50–100 lines of YAML. The authorship cost is low; the supply chain cost of substituting a community chart is unbounded. The full chart sourcing policy, including the conditions under which an upstream chart is admissible, is ADR-INFRA-016.

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
| `infra/helm/*/` | Local charts — T2 default pattern (ADR §7, ADR-INFRA-016) |
| `infra/argocd/apps/postgresql.yaml` | T1 approved upstream with approval record |
| `infra/argocd/apps/kyverno.yaml` | T1 approved upstream with approval record |
| `infra/argocd/apps/spicedb.yaml` | Local chart — official T1 chart unavailable (ADR-INFRA-016) |
| `.github/workflows/*.yaml` | GitHub Actions — SHA pinning required (T3) |

---

## Alternatives Rejected

### Adopt-on-release (no cooldown)

- **What**: Use the latest available version immediately.
- **Why rejected**: The window between a malicious release and community discovery is hours to days. A cooldown harvests that signal at zero cost. The only exception is a CVE patch for a confirmed vulnerability in a currently deployed artifact.

---

## References

- ADR-INFRA-016 — Helm Chart Sourcing (local charts by default; chart-specific alternatives rejected)
- CISA / NSA: *Defending Against Software Supply Chain Attacks* (2021)
- OpenSSF SLSA framework: https://slsa.dev
- Sigstore / Cosign (container image signing): https://www.sigstore.dev
- GitHub: *Keeping your GitHub Actions and workflows secure* — SHA pinning guidance
