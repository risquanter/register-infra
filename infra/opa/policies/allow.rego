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
#   input.request.http.headers          — includes "authorization"
#   input.parsed_jwt.payload            — decoded JWT (Istio forwards validated JWT)
#
# JWT shape expected from Keycloak realm "register":
#   parsed_jwt.payload.sub                      → user UUID (= x-user-id)
#   parsed_jwt.payload.realm_access.roles       → ["analyst","editor","team_admin"]
#   parsed_jwt.payload.email                    → user email
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
# ---------------------------------------------------------------------------
allow if {
    input.parsed_path == ["health"]
}

allow if {
    input.parsed_path == ["health", ""]
}

# ---------------------------------------------------------------------------
# Role-based allow — at least one recognised role required for all other paths
# ---------------------------------------------------------------------------
recognized_roles := {"analyst", "editor", "team_admin"}

# Extract roles from the Keycloak JWT realm_access claim.
# If the claim is absent the set is empty and no role rule fires.
user_roles := roles if {
    roles := {r | some r; r = input.parsed_jwt.payload.realm_access.roles[_]}
} else := set()

has_recognized_role if {
    some role in user_roles
    role in recognized_roles
}

# Allow any request where the caller has at least one recognized role.
# SpiceDB enforces whether they have access to the specific resource.
allow if {
    has_recognized_role
}

# ---------------------------------------------------------------------------
# Write protection — viewer-only callers cannot mutate data
# "viewer" is a Keycloak role that grants read-only access.
# If the caller has ONLY viewer (no analyst/editor/team_admin), deny writes.
# ---------------------------------------------------------------------------
write_methods := {"POST", "PUT", "PATCH", "DELETE"}

deny if {
    input.request.http.method in write_methods
    # caller has no role beyond viewer
    every role in user_roles {
        role == "viewer"
    }
}

# ---------------------------------------------------------------------------
# Admin gate — cache management endpoints require team_admin claim
# Routes: /risk-trees/{id}/cache/*, /cache/clear-all
# These routes are NEVER reached by the ZIO app — mesh-only enforcement.
# (AUTHORIZATION-PLAN Task L2.6 rows 19–22)
# ---------------------------------------------------------------------------
admin_paths := {
    ["risk-trees"],         # prefix match below
    ["cache", "clear-all"],
}

is_cache_admin_path if {
    # /risk-trees/{id}/cache/...
    input.parsed_path[0] == "risk-trees"
    input.parsed_path[2] == "cache"
}

is_cache_admin_path if {
    # /cache/clear-all
    input.parsed_path == ["cache", "clear-all"]
}

deny if {
    is_cache_admin_path
    not "team_admin" in user_roles
}
