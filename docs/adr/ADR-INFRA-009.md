# ADR-INFRA-009: BeyondCorp Identity Model — Infrastructure-Asserted Headers

**Status:** Accepted  
**Date:** 2026-03-17  
**Tags:** identity, beyondcorp, zero-trust, headers, opa, waypoint

---

## Context

- The Istio waypoint validates JWT signatures and injects claims as request headers (`x-user-id`, `x-user-email`, `x-user-roles`) via `outputClaimToHeaders`
- Multiple consumers need identity information: the ZIO application, OPA (ext_authz), and future SpiceDB integration
- Each consumer implementing its own JWT parsing creates redundant validation logic and inconsistent trust models
- Google's BeyondCorp and BeyondProd architectures establish a canonical pattern: infrastructure asserts identity into trusted headers at the perimeter; all downstream consumers read headers, never raw credentials
- If the JWT validation step (RequestAuthentication) is accidentally removed, consumers that decode the JWT themselves would still trust unvalidated tokens

---

## Decision

### 1. Single Identity Source — Mesh-Injected Headers

All consumers of identity — application code, OPA, future services — read `x-user-*` headers. No component decodes the JWT itself.

```
Envoy filter chain (waypoint):
  1. EnvoyFilter: strip x-user-* from inbound traffic
  2. jwt_authn:   validate JWT → inject x-user-id, x-user-email, x-user-roles
  3. rbac:        require valid requestPrincipal
  4. ext_authz:   OPA reads x-user-roles header (not input.parsed_jwt)
  5. upstream:    app reads x-user-id header (zero JWT code)
```

### 2. OPA Reads Trusted Headers, Not Raw JWT

OPA's `envoy_ext_authz_grpc` plugin auto-decodes the JWT from the Authorization header into `input.parsed_jwt` — but this decode is a base64 split without signature verification. The policy reads `x-user-roles` from the request headers instead.

```rego
# Primary: mesh-injected header (JSON array from outputClaimToHeaders)
user_roles := roles if {
    header_val := input.request.http.headers["x-user-roles"]
    startswith(header_val, "[")
    parsed := json.unmarshal(header_val)
    roles := {r | some r; r = parsed[_]}
}
# Fallback: parsed_jwt for unit tests that mock the ext_authz input structure
```

### 3. Deny Rules Integrated Into Allow Decision

The ext_authz plugin evaluates only the decision path (`register/authz/allow`). Independent deny rules are never checked. Deny conditions must be gated into the allow rule via `not denied`.

```rego
# ext_authz evaluates ONLY this rule — denied must be integrated here
allow if {
    has_recognized_role
    not denied
}
```

### 4. Fail-Closed on Missing Headers

If `x-user-roles` is absent (no header, no JWT, RequestAuthentication removed), `user_roles` resolves to the empty set. No recognized role → `allow` is false → 403.

```
RequestAuthentication removed accidentally:
  → jwt_authn filter absent → no x-user-roles header injected
  → OPA: user_roles = {} → has_recognized_role = false → allow = false → 403
  → Detected by: conftest policy (requestauthentication.rego), ArgoCD sync status
```

### 5. Header Stripping Is Non-Optional

The EnvoyFilter that strips `x-user-*` headers from inbound traffic is a mandatory prerequisite, not hardening. Without it, an external client can forge identity headers.

```yaml
# Strips x-user-id, x-user-email, x-user-roles BEFORE jwt_authn runs
request_headers_to_remove:
  - x-user-id
  - x-user-email
  - x-user-roles
```

---

## Code Smells

### ❌ OPA Reads parsed_jwt Instead of Trusted Headers

```rego
# BAD: OPA base64-decodes the JWT without signature verification.
# If RequestAuthentication is removed, OPA trusts forged JWT claims.
user_roles := {r | some r; r = input.parsed_jwt.payload.realm_access.roles[_]}
```

```rego
# GOOD: OPA reads mesh-injected headers — same trust model as the app.
user_roles := roles if {
    header_val := input.request.http.headers["x-user-roles"]
    parsed := json.unmarshal(header_val)
    roles := {r | some r; r = parsed[_]}
}
```

### ❌ Independent Deny Rules Not Integrated Into Allow

```rego
# BAD: deny is a separate rule — ext_authz never evaluates it.
# Viewer writes silently succeed because only 'allow' is checked.
allow if { has_recognized_role }
deny if { viewer_only_write }
```

```rego
# GOOD: deny conditions gated into the allow decision.
allow if { has_recognized_role; not denied }
denied if { viewer_only_write }
```

### ❌ String-Splitting Header Values Instead of JSON Unmarshal

```rego
# BAD: outputClaimToHeaders serializes arrays as JSON.
# String splitting produces '"editor"' (with embedded quotes) — never matches.
roles := {r | r = split(trim(header_val, "[]"), ",")[_]}
```

```rego
# GOOD: json.unmarshal handles the actual Istio wire format correctly.
parsed := json.unmarshal(header_val)
roles := {r | some r; r = parsed[_]}
```

### ❌ Application Decodes JWT Alongside Mesh

```scala
// BAD: app imports a JWT library and validates tokens itself.
// Duplicates mesh validation, creates inconsistent trust boundaries.
val claims = JwtCirce.decode(token, publicKey, Seq(JwtAlgorithm.RS256))
```

```scala
// GOOD: app reads the header that the mesh already validated.
headers.get("x-user-id") match
  case Some(sub) => UserId.fromString(sub)
  case None      => ZIO.fail(AuthForbidden("Missing x-user-id"))
```

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/k8s/istio/envoy-filter-strip-headers.yaml` | Header stripping (Decision §5) |
| `infra/k8s/istio/request-authentication.yaml` | `outputClaimToHeaders` — JWT → headers (Decision §1) |
| `infra/helm/opa/policies/allow.rego` | Header-based role extraction + deny integration (Decisions §2, §3) |
| `tests/opa/allow_test.rego` | GROUP 8 (L1 regression), GROUP 9 (header wire format) |
| `docs/SECURITY-FLOW.md` §④ | Documents OPA reads headers, deny integration |

---

## Alternatives Rejected

### OPA Reads input.parsed_jwt as Primary Source

- **What**: OPA's ext_authz plugin auto-decodes the JWT; policy reads `input.parsed_jwt.payload.realm_access.roles`
- **Why rejected**: the decode is a base64 split without signature verification. If RequestAuthentication is removed (misconfiguration, accidental deletion), OPA would trust unvalidated claims. Reading mesh-injected headers fails closed in this scenario — no header means empty roles means deny. Additionally, using headers gives a single trust model (app and OPA both read headers) rather than two (app reads headers, OPA reads raw JWT).

### Deny Rules as Independent OPA Decisions

- **What**: define `deny` as a separate rule evaluated by ext_authz alongside `allow`
- **Why rejected**: the ext_authz EnvoyFilter configures a single `decisionPath: register/authz/allow`. Only the `allow` rule is evaluated. Independent `deny` rules are silently ignored — they compile and test correctly in `opa test` but have no effect in production. This was identified as THREAT-CATALOG L1.

---

## References

- [ADR-012](../../register/docs/ADR-012.md) §5–§6 — app reads `x-user-id` header, zero JWT code
- [ADR-INFRA-004](ADR-INFRA-004.md) — defense-in-depth layers, header stripping as mandatory
- [ADR-INFRA-010](ADR-INFRA-010.md) — SpiceDB infrastructure (receives userId from BeyondCorp headers)
- [SECURITY-FLOW.md](../SECURITY-FLOW.md) §③–④ — filter chain order, OPA identity source
- Google BeyondCorp: https://cloud.google.com/beyondcorp
- Google BeyondProd: https://cloud.google.com/security/beyondprod
