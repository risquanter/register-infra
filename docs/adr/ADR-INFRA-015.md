# ADR-INFRA-015: SpiceDB Write-Scoping Enforcement

**Status:** Accepted (awaiting implementation)
**Date:** 2026-07-08
**Tags:** spicedb, authorization, least-privilege, opa, ext-authz, mesh-identity, defense-in-depth

---

## Context

- A shared bearer credential authenticates identically regardless of which caller
  holds it; SpiceDB has no concept of scoping a preshared key to a subset of
  relations or operations — a valid key grants the entire API.
- Components with different exposure levels — an internet-facing service versus an
  internally-triggered job — present different attack surfaces. A credential that
  grants both the same privilege erases that distinction.
- Least-privilege between service components bounds the blast radius of a
  compromise to what that component legitimately needs, independent of how many
  end users or tenants exist above it.
- One SpiceDB instance can serve multiple product trust boundaries at once (a
  public capability-URL tier, small-team accounts, and full multi-org enterprise
  accounts). A compromise of the component serving the least-trusted tier must not
  reach relations belonging to a more trusted tier.
- Read-side authorization checks legitimately span the entire relationship graph by
  design; write-side operations do not. The two require different scoping treatment.
- Mesh-verified workload identity (mTLS/SPIFFE) is bound to the pod presenting it
  and cannot be replayed after exfiltration, unlike a bearer token.

---

## Decision

### 1. One preshared key per calling component, not one shared key

```yaml
# infra/secrets/spicedb.enc.yaml — SpiceDB's own view: one field, two valid values
stringData:
  preshared-key: "<register-key>,<runner-key>"   # --grpc-preshared-key accepts a
                                                   # comma-separated list; either is valid
```

```yaml
# infra/secrets/spicedb-register.enc.yaml — only what register-server holds
stringData:
  spicedb-preshared-key: "<register-key>"

# infra/secrets/runner-spicedb-token.enc.yaml — only what the runner holds (ADR-INFRA-011 §4)
stringData:
  token: "<runner-key>"
```

Each caller gets its own secret, scoped to its own namespace. A leaked key is
identified and revocable independently of the other.

### 2. An ext_authz gateway scopes writes by workload identity, not by token

```yaml
# infra/k8s/opa/spicedb-write-gate.yaml — EnvoyFilter on a waypoint for `infra`
grpc_service:
  envoy_grpc:
    cluster_name: outbound|9191||opa.register.svc.cluster.local
  timeout: 0.1s
failure_mode_deny: true   # OPA unavailable → deny, matching the K.5 gate's posture
```

Positioned in front of SpiceDB, on a dedicated waypoint for the `infra` namespace
(does not exist yet — `register` is the only namespace with one today). Every
`WriteRelationships` call is evaluated against the caller's mTLS-verified SPIFFE
identity, never the bearer token — proving *which workload* sent the request, not
just that some valid token was presented.

> register-server calls SpiceDB over HTTP/REST (port 8080); the runner calls over
> gRPC (port 50051, per ADR-INFRA-011 §3). Body inspection differs by protocol —
> HTTP/JSON is straightforward for Envoy/OPA to parse, gRPC/protobuf requires either
> gRPC-JSON transcoding or the runner also speaking SpiceDB's HTTP API. Which
> mechanism covers the gRPC path is an implementation detail to resolve when this
> is built, not decided here.

### 3. A static per-identity relation allowlist

```rego
# infra/helm/opa/policies/spicedb_write_gate.rego
allowed_relations := {
  "spiffe://cluster.local/ns/register/sa/register-runtime": {"owner_user", "owner_team"},
  "spiffe://cluster.local/ns/runner/sa/runner":              {"editor", "analyst", "viewer",
                                                                "team_admin", "org_member"},
}

deny if {
  relation := input.parsed_body.relationshipUpdates[_].relationship.relation
  not relation in allowed_relations[input.attributes.source.principal]
}
```

`register-runtime` (register-server's actual ServiceAccount) can never write
`org_member`/`team_admin`/any team-level relation, even with full control of its
own credential and mesh identity — the boundary is enforced by the gateway, not by
application code alone.

### 4. Reads are not gated by this mechanism

`Check`, `LookupResources`, `ReadSchema`, and every non-`WriteRelationships` call
pass through ungated. Authorization checks legitimately need visibility across the
whole graph; scoping reads the same way would break normal operation.

### 5. Schema changes and the allowlist are updated together, deliberately

The allowlist in Decision 3 is derived from `schema.zed`'s relation set but is not
generated from it automatically. A new relation added to the schema does not
silently become writable by every caller — the allowlist requires its own
deliberate, reviewed change alongside the schema change.

---

## Code Smells

### ❌ One shared preshared key for every caller

```yaml
# BAD
spicedb:
  presharedKey: "same-key-for-app-and-runner"
```

```yaml
# GOOD
spicedb:
  presharedKeys:
    register: spicedb-register-credentials
    runner:   runner-spicedb-token
```

### ❌ Scoping by bearer token instead of workload identity

```rego
# BAD: token value proves nothing about which workload sent the request —
# a leaked or replayed token bypasses this entirely
allow if input.headers["authorization"] == "Bearer app-token"
```

```rego
# GOOD: mTLS-verified SPIFFE identity cannot be forged by replaying a leaked token
allow if input.attributes.source.principal == "spiffe://cluster.local/ns/register/sa/register-runtime"
```

### ❌ Gating reads the same way as writes

```rego
# BAD: breaks every legitimate permission check — reads must span the whole graph
deny if input.request.path == "/v1/permissions/check" and not caller_owns_resource
```

```rego
# GOOD: only WriteRelationships is scoped; Check/LookupResources pass through
deny if input.request.path == "/v1/relationships/write" and relation_not_allowed
```

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/secrets/spicedb-register.enc.yaml`, `runner-spicedb-token.enc.yaml` | Separate preshared keys per caller |
| `infra/helm/spicedb/values.yaml` | Comma-joined `preshared-key` value covering both |
| `infra/k8s/istio/waypoint-infra.yaml` (new) | Waypoint for the `infra` namespace |
| `infra/k8s/opa/spicedb-write-gate.yaml` (new) | EnvoyFilter, ext_authz on the infra waypoint |
| `infra/helm/opa/policies/spicedb_write_gate.rego` (new) | Per-identity relation allowlist |
| `tests/opa/spicedb_write_gate_test.rego` (new) | Unit tests for the allowlist |

---

## Alternatives Rejected

### A — Defer indefinitely (single shared preshared key)

- **What**: no credential separation, no enforcement gateway; every caller shares one key with full API access.
- **Why rejected**: leaves the entire authorization graph reachable from whichever component is most exposed to compromise. Acceptable only while the product had a single, undifferentiated deployment target — the multi-layer design (public/Layer 0, small-team/Layer 1, enterprise/Layer 2) sharing one SpiceDB backend removes that justification. A compromise of the Layer-0-facing app must not reach Layer-2 org/team relations.

### Minimal purpose-built shim instead of the OPA/waypoint pattern

- **What**: a small dedicated proxy in front of SpiceDB checking caller identity against a static allowlist, without a full Istio waypoint or OPA policy.
- **Why rejected**: duplicates infrastructure the mesh already provides (mTLS, SPIFFE identity, ext_authz) instead of reusing it. A second, bespoke enforcement mechanism is an additional component to secure, test, and maintain, with none of the existing OPA policy-testing conventions (`allow_test.rego`-style unit tests) available for free. The marginal cost of one more EnvoyFilter + Rego policy is smaller than a wholly separate enforcement component, given the waypoint pattern and OPA deployment already exist for `register`.

### Resource-instance-scoped enforcement (correlating writes to specific workspace IDs)

- **What**: extend the gateway to verify not just *which relation type* a caller may write, but *which specific resource* — e.g., register-server may only write `owner_user` for the workspace it is actively bootstrapping in that request.
- **Why rejected**: requires the gateway to re-implement `BootstrapProvisioner`'s own correctness logic a second time, as a parallel system that can itself drift from the application code it's supposed to be checking. This does not fully close the residual gap it targets (full RCE compromise of register-server can still forge `owner_user` on an arbitrary workspace) at a cost disproportionate to what a relation-type allowlist already buys. Revisit only if a concrete incident or threat model justifies it.

---

## References

- [ADR-INFRA-010](ADR-INFRA-010.md) — SpiceDB runtime: HTTP in-cluster, mesh mTLS
- [ADR-INFRA-011](ADR-INFRA-011.md) — in-cluster runner; rejected exporting cluster credentials; runner namespace and secret path this ADR builds on
- [ADR-INFRA-014](ADR-INFRA-014.md) — Multi-Environment GitOps Topology; same blast-radius reasoning applied to ArgoCD's own topology
- `infra/k8s/opa/ext-authz-filter.yaml`, `allow.rego` — the register API's own ext_authz gate; the established pattern this decision extends to SpiceDB
- TODO.md § L2 Path Step 3 (K.6), § SpiceDB Write-Scoping Enforcement
