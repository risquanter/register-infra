---
name: infra-adr-constraints
description: "Agent-efficient distillation of all accepted ADRs for the register-infra project. Load during any planning or implementation phase that introduces new Helm charts, ArgoCD apps, Istio manifests, NetworkPolicies, SOPS secrets, or Kyverno policies. Use for: ADR compliance review, pre-implementation planning, architecture alignment checks, security boundary questions."
user-invokable: true
---

# ADR Constraints Reference — Register Infra

## Boundary Ownership

| Concern | Owner | Never in |
|---|---|---|
| Policy source of truth | `infra/helm/<chart>/policies/*.rego` loaded via `Files.Get` | ConfigMap inline YAML |
| JWT validation | Istio waypoint (`RequestAuthentication` + JWKS) | Application code |
| Identity header injection | `RequestAuthentication.outputClaimToHeaders` | Application code |
| Identity header stripping | `EnvoyFilter` (HttpConnectionManager, step 1 in chain) | `AuthorizationPolicy` DENY rule |
| Coarse authorization gate | OPA ext_authz (`allow.rego`) | Application service layer |
| Fine-grained authorization | SpiceDB via app `AuthorizationService.check()` | OPA policy |
| SpiceDB tuple writes | `zed` CLI / K.6 provisioning job | Application runtime |
| Credential delivery | SOPS-encrypted Secret, per namespace | Plain Secret, env inline value |
| Namespace PSS labels + LimitRange | namespaces Helm chart (`infra/helm/namespaces/`) | `kubectl label` manual, ArgoCD `CreateNamespace=true` alone |
| Fail-closed component replicas | `replicaCount: ≥2` + PDB `minAvailable: 1` | Single-replica deployment |
| ArgoCD blast-radius scoping | Dedicated AppProject with explicit resource whitelists | `project: default` |
| Kyverno operator resources (CRDs, webhooks, ClusterRoles) | `kyverno` AppProject | `platform` AppProject |
| Kyverno policy instances (ClusterPolicy) | `platform` AppProject | `kyverno` AppProject |

---

## Positive Invariants — Reach for These

| Pattern | Where | ADR |
|---|---|---|
| `Files.Get "policies/allow.rego"` in ConfigMap template | Any chart that mounts a policy file | ADR-INFRA-001 §1 |
| `register-infra/issuer-sync` annotation on raw manifests that cross-reference Helm values | `request-authentication.yaml` and any new cross-file coupling | ADR-INFRA-001 §2 |
| `replicaCount: 2` + `PodDisruptionBudget minAvailable: 1` | Any component with `failure_mode_deny: true` or fail-closed semantics | ADR-INFRA-002 |
| `targetRef: { kind: Gateway, name: waypoint }` on AuthorizationPolicy | All HTTP-level ALLOW/DENY policies in ambient mode | ADR-INFRA-004 §3 |
| Default-deny-all + HBONE port 15008 open intra-namespace | Every new ambient-enrolled namespace | ADR-INFRA-004 §2 |
| DNS egress rule (UDP+TCP port 53) | Every default-deny namespace | ADR-INFRA-004 §5 |
| SOPS-encrypted Secret per namespace | Every credential delivered to a pod | ADR-INFRA-006 |
| `syncOptions: [ServerSideApply=true]` | Any Application whose chart creates CRDs > 256KB | ADR-INFRA-008 §3 |
| OPA reads `x-user-roles` header via `json.unmarshal` | `allow.rego` role extraction | ADR-INFRA-009 §2 |
| `deny` conditions integrated via `not denied` inside `allow` | `allow.rego` decision path | ADR-INFRA-009 §3 |
| `failure_mode_deny: true` with consequence comment referencing ADR-INFRA-002 | Every ext_authz EnvoyFilter | ADR-INFRA-002 §3 |
| Two focused AuthorizationPolicies: `require-jwt` + `allow-capability-urls` | `register` namespace L7 policy | ADR-INFRA-007 §3 |

---

## Negative Constraints

### Supply Chain Defence (ADR-INFRA-012)

**Blast radius tiers — classify before adopting anything:**

| Tier | What | Examples |
|---|---|---|
| T1 | Cluster-privileged | Charts installing CRDs/webhooks/ClusterRoles; Terraform providers; in-cluster CI runner actions |
| T2 | Cluster-scoped | Application container images; single-namespace Helm charts |
| T3 | CI build-time | GitHub Actions on hosted runners; linters; build tools |
| T4 | Dev environment | IDE extensions; local CLI plugins |

❌ NEVER source any artifact from a community fork, mirror, or third-party distribution at any tier.
✅ INSTEAD: primary vendor org only. If no official chart exists — write a local chart. Never substitute a community chart.

❌ NEVER use a mutable reference: `latest` tag, version range, or mutable GitHub Action tag.
✅ INSTEAD: container image digest (`sha256:...`), exact chart version, GitHub Action commit SHA.

❌ NEVER adopt a new T1/T2 artifact on its release date.
✅ INSTEAD: minimum cooldown from public release date before adoption:
- T1: 90 days new / 14 days patch / 30 days minor / 90 days major
- T2: 30 days new / 7 days patch / 14 days minor / 30 days major
- T3: 14 days new / 3 days patch / 7 days minor / 14 days major
- T4: 7 days new / immediate patch
- Exception only: CVE patch for a confirmed vulnerability in a deployed artifact — document CVE ID in commit.

❌ NEVER add a T1/T2 artifact without an approval record comment in the manifest:
```yaml
# Vendor: <org> — <URL>
# Security disclosure: <URL>
# Pinned: <exact version or digest>
# Cooldown elapsed: <release date> → adopted <date> (<N days>)
# Approved: ADR-INFRA-012. Reviewed: <date>
```

**Currently approved upstream Helm charts** (all others require a new entry in ADR-INFRA-012 §7):
| Chart | Vendor repo |
|---|---|
| `bitnami/postgresql` | `https://charts.bitnami.com/bitnami` |
| `kyverno/kyverno` | `https://kyverno.github.io/kyverno/` |

---

### Configuration Single-Source-of-Truth (ADR-INFRA-001)

❌ NEVER embed a policy file inline in a ConfigMap.
✅ INSTEAD: `{{ .Files.Get "policies/allow.rego" | indent 4 }}` from canonical source in the chart.

❌ NEVER hardcode the same value (issuer URL, hostname, port) in both a Helm chart and a raw manifest without a cross-reference annotation.
✅ INSTEAD: annotate the raw manifest with `register-infra/issuer-sync: "<value>"` and document both locations.

---

### Fail-Closed Availability (ADR-INFRA-002)

❌ NEVER deploy a fail-closed component (`failure_mode_deny: true` or equivalent) with a single replica.
✅ INSTEAD: `replicaCount: 2` + PDB `minAvailable: 1`.

❌ NEVER set `failure_mode_deny: true` without a comment stating the consequence and referencing ADR-INFRA-002.
✅ INSTEAD:
```yaml
# failure_mode_deny: true means OPA unavailability → 403, not allow.
# This is the fail-closed posture required by the threat model.
# Consequence: OPA must have ≥2 replicas + PDB (ADR-INFRA-002).
failure_mode_deny: true
```

---

### AppProject Scoping (ADR-INFRA-003)

❌ NEVER use `project: default` for any Application except the root App of Apps.
✅ INSTEAD: assign each Application to its scoped project (`platform`, `infra`, `app`, `kyverno`).

❌ NEVER use wildcards in `namespaceResourceWhitelist` or `clusterResourceWhitelist`.
✅ INSTEAD: enumerate exactly the kinds the chart creates. Audit with `helm template | grep "^kind:"`.

---

### Network and Identity Controls (ADR-INFRA-004)

❌ NEVER apply an AuthorizationPolicy with HTTP rules using `selector: {}` in Istio ambient mode.
✅ INSTEAD: `targetRef: { group: gateway.networking.k8s.io, kind: Gateway, name: waypoint }`.
*Rationale: ztunnel cannot evaluate HTTP attributes; `selector` silently drops all rules → default deny at L4 blocks all east-west traffic.*

❌ NEVER add only per-service port rules (e.g. allow register→irmin on 8080) without the HBONE rule.
✅ INSTEAD: HBONE port 15008 open intra-namespace is mandatory; per-service rules are documentation.

❌ NEVER create a default-deny namespace without a DNS egress rule.
✅ INSTEAD: include `allow-egress-dns` (UDP+TCP port 53) in every default-deny namespace.

---

### Secrets (ADR-INFRA-006)

❌ NEVER commit a plaintext Secret manifest.
✅ INSTEAD: `sops --encrypt` before committing; only `.enc.yaml` files in `infra/secrets/`.

❌ NEVER share a Secret across namespaces via a cross-namespace reference or Reflector.
✅ INSTEAD: per-namespace SOPS-encrypted Secret with a dedicated credential (not shared superuser).

❌ NEVER add DB_* env vars for a service that uses in-memory storage.
✅ INSTEAD: defer DB_* wiring until the backing store is implemented; document with ADR-INFRA-006 comment.

---

### Kyverno Isolation (ADR-INFRA-008)

❌ NEVER put Kyverno operator resources (CRDs, MutatingWebhookConfiguration, ClusterRole) in the `platform` project.
✅ INSTEAD: dedicated `kyverno` AppProject for the operator; `platform` holds ClusterPolicy instances only.

❌ NEVER set `failurePolicy: Fail` on a mutation-only Kyverno policy.
✅ INSTEAD: `failurePolicy: Ignore` — PSS admission is the enforcement backstop.

---

### BeyondCorp Identity Model (ADR-INFRA-009)

❌ NEVER write OPA policy that reads `input.parsed_jwt` as the primary identity source.
✅ INSTEAD: read `input.request.http.headers["x-user-roles"]` via `json.unmarshal`.
*Rationale: `parsed_jwt` is base64-decoded without signature verification — trusts unvalidated claims if RequestAuthentication is removed.*

❌ NEVER define `deny` as a standalone OPA rule evaluated independently of `allow`.
✅ INSTEAD: gate deny conditions inside `allow`: `allow if { has_recognized_role; not denied }`.
*Rationale: ext_authz evaluates only the `register/authz/allow` decision path; standalone `deny` rules are silently ignored.*

❌ NEVER use string-split to parse `x-user-roles` header values.
✅ INSTEAD: `json.unmarshal(header_val)` — Istio serializes array claims as JSON.

---

## Escape-Hatch Triggers — Stop and Ask

Any of the following require a `⚠️ Decision Required` before proceeding:

1. Any change to `namespaceResourceWhitelist` or `clusterResourceWhitelist` in an AppProject
2. **Any new external `repoURL`** — apply ADR-INFRA-012 §2 three-condition test before raising; if any condition fails, the answer is a local chart, not a question
3. Widening any security resource: removing a NetworkPolicy rule, relaxing PeerAuthentication mode, adding a public path exception to AuthorizationPolicy
4. Changing a SOPS secret key name (all consumers break on next sync)
5. Setting `failure_mode_deny: false` or switching an ext_authz filter to fail-open
6. Adding `syncOptions: [Replace=true]` (destructive — deletes and recreates the resource)
7. Deploying a new Application that installs cluster-scoped resources without a dedicated AppProject
8. Removing or weakening any conftest `deny` rule, bats assertion, or OPA unit test
9. Any solution with trade-offs or caveats — including "it works but..."

Format:
```
⚠️ Decision Required
Context: [what was being implemented]
Issue: [what problem arose]
Options: A) … B) … C) …
Trade-off: [value judgement only the user can weigh]
Decision needed: [single specific closed question]
```

---

## ADR Status Interpretation

All ADRs present in `docs/adr/` are live regardless of their "Status:" field.
Deletion is the only form of archival — a file that exists is in force.
Treat every existing ADR document as accepted for alignment purposes.

Current ADRs in force: ADR-INFRA-001 through ADR-INFRA-012.
