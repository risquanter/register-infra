package register.authz

import future.keywords.if
import future.keywords.every
import future.keywords.in

# ---------------------------------------------------------------------------
# OPA coarse gate — claim-based only (ADR-012 §3, AUTHORIZATION-PLAN Task L2.4)
#
# Answers: "does this role claim permit attempting this operation type?"
# Does NOT answer: "does this user own this specific resource?" (that is SpiceDB)
#
# Inputs (via Istio ext_authz CheckRequest):
#   input.parsed_body                   — request body (not used here)
#   input.parsed_path                   — ["w", "<key>", "risk-trees", ...]
#   input.request.http.method           — GET / POST / PUT / PATCH / DELETE
#   input.request.http.headers          — includes x-user-roles (trusted, mesh-injected)
#
# Identity source: trusted mesh headers (not raw JWT)
#   The waypoint's RequestAuthentication validates the JWT and injects:
#     x-user-id     ← JWT sub claim
#     x-user-email  ← JWT email claim
#     x-user-roles  ← JWT realm_access.roles claim
#   These headers are trusted because:
#     1. EnvoyFilter strips them from all inbound traffic (step 1 in chain)
#     2. Only the waypoint's jwt_authn filter writes them (step 2 in chain)
#     3. ext_authz runs after both (step 4) — values are mesh-asserted
#   Reading headers instead of input.parsed_jwt avoids trusting an unvalidated
#   JWT decode (OPA base64-decodes without signature verification).
#   See SECURITY-FLOW.md §③, ADR-INFRA-004-appendix.
#
# Decision integration:
#   The ext_authz plugin evaluates ONLY the decision path (register/authz/allow).
#   The `allow` rule is the SOLE decision point — it returns true only when:
#     1. A positive allow condition fires (public endpoint OR recognised role), AND
#     2. No deny condition fires (viewer write block, admin gate)
#   This ensures deny rules are never silently bypassed.
#   See THREAT-CATALOG L1.
#
# OPA evaluates BEFORE the ZIO application sees the request.
# OPA deny → 403 immediately; SpiceDB is never queried.
# OPA allow → request forwarded; SpiceDB then makes the instance-level decision.
# Both must allow — AND logic. Neither can grant access past the other.
# ---------------------------------------------------------------------------

# Default: deny unless an allow rule fires
default allow := false

# ---------------------------------------------------------------------------
# Public endpoints — bypass auth entirely
# Health probe must always succeed, even without a JWT.
# These are exempt from deny rules — no identity is available or needed.
# ---------------------------------------------------------------------------
allow if {
    input.parsed_path == ["health"]
}

allow if {
    input.parsed_path == ["health", ""]
}

# ---------------------------------------------------------------------------
# Role extraction — from trusted mesh header x-user-roles
#
# The waypoint's RequestAuthentication validates the JWT and writes
# realm_access.roles into the x-user-roles header (outputClaimToHeaders).
# The value is a JSON-serialized array, e.g. '["editor","analyst"]'.
#
# This is the BeyondCorp identity model (ADR-INFRA-009): infrastructure
# asserts identity into trusted headers, all consumers read headers.
# OPA does not decode the JWT itself — it reads the mesh's assertion.
#
# Fallback chain:
#   1. x-user-roles header as JSON array (production wire format)
#   2. x-user-roles header as plain string (single-role edge case)
#   3. input.parsed_jwt.payload (unit tests that mock ext_authz input)
#   4. empty set (no identity — deny)
# ---------------------------------------------------------------------------
recognized_roles := {"analyst", "editor", "team_admin"}

# Primary: JSON array from outputClaimToHeaders (e.g. '["editor","analyst"]').
user_roles := roles if {
    header_val := input.request.http.headers["x-user-roles"]
    header_val != ""
    startswith(header_val, "[")
    parsed := json.unmarshal(header_val)
    roles := {r | some r; r = parsed[_]}
} else := roles if {
    # Single-value string header (non-array claim output).
    header_val := input.request.http.headers["x-user-roles"]
    header_val != ""
    roles := {header_val}
} else := roles if {
    # Fallback: extract from parsed_jwt (OPA unit tests, transition period).
    roles := {r | some r; r = input.parsed_jwt.payload.realm_access.roles[_]}
} else := set()

has_recognized_role if {
    some role in user_roles
    role in recognized_roles
}

# ---------------------------------------------------------------------------
# Deny rules — conditions that override a positive allow
#
# IMPORTANT: deny rules are NOT independently evaluated by the ext_authz
# plugin. The decision path is register/authz/allow — ONLY the allow rule
# is checked. Deny rules influence the outcome solely through the
# role-based allow rule below, which gates on `not denied`.
# See THREAT-CATALOG L1 for the evaluation order concern.
# ---------------------------------------------------------------------------

# Write protection — viewer-only callers cannot mutate data
# "viewer" is a Keycloak role that grants read-only access.
# If the caller has ONLY viewer (no analyst/editor/team_admin), deny writes.
write_methods := {"POST", "PUT", "PATCH", "DELETE"}

denied if {
    input.request.http.method in write_methods
    # caller has no role beyond viewer
    every role in user_roles {
        role == "viewer"
    }
}

# Admin gate — cache management endpoints require team_admin claim
# Routes: /risk-trees/{id}/cache/*, /cache/clear-all
# These routes are NEVER reached by the ZIO app — mesh-only enforcement.
# (AUTHORIZATION-PLAN Task L2.6 rows 19–22)
is_cache_admin_path if {
    # /risk-trees/{id}/cache/...
    input.parsed_path[0] == "risk-trees"
    input.parsed_path[2] == "cache"
}

is_cache_admin_path if {
    # /cache/clear-all
    input.parsed_path == ["cache", "clear-all"]
}

denied if {
    is_cache_admin_path
    not "team_admin" in user_roles
}

# ---------------------------------------------------------------------------
# Role-based allow — the SOLE protected-path decision point
#
# This rule combines the positive (has_recognized_role) and negative (denied)
# conditions into one atomic decision. The ext_authz plugin evaluates only
# `allow`, so deny rules MUST be incorporated here to have any effect.
# ---------------------------------------------------------------------------
allow if {
    has_recognized_role
    not denied
}
