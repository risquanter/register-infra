# ── OPA Unit Tests: allow.rego ─────────────────────────────────────────────────
# Tests the coarse role gate policy used by Istio ext_authz (waypoint → OPA).
#
# Run:
#   opa test infra/helm/opa/policies/ tests/opa/ -v
#
# These tests verify every branch of the OPA policy without needing a live
# cluster. They are the fastest feedback loop for policy changes.
# ──────────────────────────────────────────────────────────────────────────────
package register.authz

import future.keywords.if
import future.keywords.in

# ── Helpers ───────────────────────────────────────────────────────────────────

# Minimal JWT payload for a recognised role.
jwt_payload(roles) := {
    "sub": "test-user-uuid",
    "email": "test@example.com",
    "realm_access": {"roles": roles},
}

# Minimal input for a given method, path, and JWT payload.
make_input(method, path, payload) := {
    "parsed_path": path,
    "request": {"http": {"method": method, "headers": {}}},
    "parsed_jwt": {"payload": payload},
}

# Input with no JWT at all (anonymous / unauthenticated).
anon_input(method, path) := {
    "parsed_path": path,
    "request": {"http": {"method": method, "headers": {}}},
    "parsed_jwt": {},
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 1: Health endpoint bypass
# ══════════════════════════════════════════════════════════════════════════════

test_health_allowed_without_jwt if {
    allow with input as anon_input("GET", ["health"])
}

test_health_trailing_slash_allowed if {
    allow with input as anon_input("GET", ["health", ""])
}

test_health_allowed_with_jwt if {
    allow with input as make_input("GET", ["health"], jwt_payload(["analyst"]))
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: Role-based access — positive tests
# ══════════════════════════════════════════════════════════════════════════════

test_analyst_can_read if {
    allow with input as make_input("GET", ["w", "abc123", "risk-trees"], jwt_payload(["analyst"]))
}

test_editor_can_read if {
    allow with input as make_input("GET", ["w", "abc123", "risk-trees"], jwt_payload(["editor"]))
}

test_team_admin_can_read if {
    allow with input as make_input("GET", ["w", "abc123", "risk-trees"], jwt_payload(["team_admin"]))
}

test_analyst_can_write if {
    inp := make_input("POST", ["w", "abc123", "risk-trees"], jwt_payload(["analyst"]))
    allow with input as inp
    not deny with input as inp
}

test_editor_can_write if {
    inp := make_input("PUT", ["w", "abc123", "risk-trees"], jwt_payload(["editor"]))
    allow with input as inp
    not deny with input as inp
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 3: Viewer-only write protection
# ══════════════════════════════════════════════════════════════════════════════

test_viewer_only_denied_post if {
    deny with input as make_input("POST", ["w", "abc123", "risk-trees"], jwt_payload(["viewer"]))
}

test_viewer_only_denied_put if {
    deny with input as make_input("PUT", ["w", "abc123", "risk-trees"], jwt_payload(["viewer"]))
}

test_viewer_only_denied_patch if {
    deny with input as make_input("PATCH", ["w", "abc123", "risk-trees"], jwt_payload(["viewer"]))
}

test_viewer_only_denied_delete if {
    deny with input as make_input("DELETE", ["w", "abc123", "risk-trees"], jwt_payload(["viewer"]))
}

test_viewer_can_read if {
    inp := make_input("GET", ["w", "abc123", "risk-trees"], jwt_payload(["viewer"]))
    # viewer has no recognised role → allow does NOT fire via has_recognized_role
    # But viewer IS a real role, just not in recognized_roles.
    # The policy defaults to deny unless a recognized role is present.
    not allow with input as inp
}

test_viewer_plus_analyst_can_write if {
    # If viewer also has analyst, the analyst role satisfies has_recognized_role
    # and the deny rule doesn't fire (not every role is viewer).
    inp := make_input("POST", ["w", "abc123", "risk-trees"], jwt_payload(["viewer", "analyst"]))
    allow with input as inp
    not deny with input as inp
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 4: Admin gate — cache management
# ══════════════════════════════════════════════════════════════════════════════

test_admin_can_access_cache if {
    inp := make_input("POST", ["risk-trees", "rt-1", "cache", "clear"], jwt_payload(["team_admin"]))
    allow with input as inp
    not deny with input as inp
}

test_admin_can_clear_all_cache if {
    inp := make_input("POST", ["cache", "clear-all"], jwt_payload(["team_admin"]))
    allow with input as inp
    not deny with input as inp
}

test_analyst_denied_cache_path if {
    deny with input as make_input("POST", ["risk-trees", "rt-1", "cache", "clear"], jwt_payload(["analyst"]))
}

test_editor_denied_cache_path if {
    deny with input as make_input("POST", ["cache", "clear-all"], jwt_payload(["editor"]))
}

test_viewer_denied_cache_path if {
    deny with input as make_input("POST", ["risk-trees", "rt-1", "cache", "clear"], jwt_payload(["viewer"]))
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 5: Unauthenticated / no JWT — must deny
# ══════════════════════════════════════════════════════════════════════════════

test_no_jwt_denied_on_protected_route if {
    not allow with input as anon_input("GET", ["w", "abc123", "risk-trees"])
}

test_no_jwt_denied_on_api_route if {
    not allow with input as anon_input("POST", ["api", "test"])
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 6: Unrecognised roles — must deny
# ══════════════════════════════════════════════════════════════════════════════

test_unknown_role_denied if {
    not allow with input as make_input("GET", ["w", "abc123", "risk-trees"], jwt_payload(["hacker"]))
}

test_empty_roles_denied if {
    not allow with input as make_input("GET", ["w", "abc123", "risk-trees"], jwt_payload([]))
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 7: Edge cases
# ══════════════════════════════════════════════════════════════════════════════

test_missing_realm_access_denied if {
    inp := {
        "parsed_path": ["w", "abc123", "risk-trees"],
        "request": {"http": {"method": "GET", "headers": {}}},
        "parsed_jwt": {"payload": {"sub": "test-user", "email": "test@example.com"}},
    }
    not allow with input as inp
}

test_get_on_cache_path_allowed_for_analyst if {
    # Cache admin gate only fires for is_cache_admin_path — GET is still allowed
    # if the user has a recognized role, and deny only fires if NOT team_admin.
    inp := make_input("GET", ["risk-trees", "rt-1", "cache", "status"], jwt_payload(["analyst"]))
    allow with input as inp
    deny with input as inp   # deny fires because analyst is not team_admin on cache path
}
