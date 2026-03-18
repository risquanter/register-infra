# ── OPA Unit Tests: allow.rego ─────────────────────────────────────────────────
# Tests the coarse role gate policy used by Istio ext_authz (waypoint → OPA).
#
# Run:
#   opa test infra/helm/opa/policies/ tests/opa/ -v
#
# These tests verify every branch of the OPA policy without needing a live
# cluster. They are the fastest feedback loop for policy changes.
#
# THREAT-CATALOG L1 regression: Groups 8 and 9 explicitly verify that deny
# rules are integrated into the allow decision — not silently bypassed.
# ──────────────────────────────────────────────────────────────────────────────
package register.authz

import future.keywords.if
import future.keywords.in

# ── Helpers ───────────────────────────────────────────────────────────────────

# Minimal JWT payload for a recognised role (backward-compat input shape).
jwt_payload(roles) := {
    "sub": "test-user-uuid",
    "email": "test@example.com",
    "realm_access": {"roles": roles},
}

# Input using parsed_jwt (fallback path in policy — for transition / compat).
make_input(method, path, payload) := {
    "parsed_path": path,
    "request": {"http": {"method": method, "headers": {}}},
    "parsed_jwt": {"payload": payload},
}

# Input using x-user-roles header (primary path in policy — mesh-injected).
# Accepts a Rego array of roles, serialises to JSON (matching Istio’s
# outputClaimToHeaders wire format for array claims).
make_header_input(method, path, roles) := {
    "parsed_path": path,
    "request": {"http": {"method": method, "headers": {"x-user-roles": json.marshal(roles)}}},
    "parsed_jwt": {},
}

# Input with no JWT and no roles header (anonymous / unauthenticated).
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
#  GROUP 1b: Public route bypass — Layer 0 capability URLs
#
#  The AuthorizationPolicy lets /w/* and /workspaces/* through without a JWT,
#  but ext_authz still fires. OPA must allow these without any identity.
# ══════════════════════════════════════════════════════════════════════════════

test_capability_url_allowed_anon if {
    allow with input as anon_input("GET", ["w", "abc123", "risk-trees"])
}

test_capability_url_post_allowed_anon if {
    allow with input as anon_input("POST", ["w", "abc123", "risk-trees"])
}

test_capability_url_allowed_with_jwt if {
    allow with input as make_input("GET", ["w", "abc123", "risk-trees"], jwt_payload(["editor"]))
}

test_workspaces_allowed_anon if {
    allow with input as anon_input("GET", ["workspaces"])
}

test_workspaces_subpath_allowed_anon if {
    allow with input as anon_input("POST", ["workspaces", "create"])
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: Role-based access — positive tests (JWT fallback path)
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
    allow with input as make_input("POST", ["w", "abc123", "risk-trees"], jwt_payload(["analyst"]))
}

test_editor_can_write if {
    allow with input as make_input("PUT", ["w", "abc123", "risk-trees"], jwt_payload(["editor"]))
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 3: Viewer-only write protection
# ══════════════════════════════════════════════════════════════════════════════

test_viewer_only_denied_post if {
    denied with input as make_input("POST", ["w", "abc123", "risk-trees"], jwt_payload(["viewer"]))
}

test_viewer_only_denied_put if {
    denied with input as make_input("PUT", ["w", "abc123", "risk-trees"], jwt_payload(["viewer"]))
}

test_viewer_only_denied_patch if {
    denied with input as make_input("PATCH", ["w", "abc123", "risk-trees"], jwt_payload(["viewer"]))
}

test_viewer_only_denied_delete if {
    denied with input as make_input("DELETE", ["w", "abc123", "risk-trees"], jwt_payload(["viewer"]))
}

test_viewer_can_read if {
    inp := make_input("GET", ["w", "abc123", "risk-trees"], jwt_payload(["viewer"]))
    # viewer is a recognized role — allow fires via has_recognized_role.
    # The denied rule does NOT fire for GET (only write methods).
    allow with input as inp
}

test_viewer_plus_analyst_can_write if {
    # If viewer also has analyst, the analyst role satisfies has_recognized_role
    # and the denied rule doesn't fire (not every role is viewer).
    inp := make_input("POST", ["w", "abc123", "risk-trees"], jwt_payload(["viewer", "analyst"]))
    allow with input as inp
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 4: Admin gate — cache management
# ══════════════════════════════════════════════════════════════════════════════

test_admin_can_access_cache if {
    allow with input as make_input("POST", ["risk-trees", "rt-1", "cache", "clear"], jwt_payload(["team_admin"]))
}

test_admin_can_clear_all_cache if {
    allow with input as make_input("POST", ["cache", "clear-all"], jwt_payload(["team_admin"]))
}

test_analyst_denied_cache_path if {
    denied with input as make_input("POST", ["risk-trees", "rt-1", "cache", "clear"], jwt_payload(["analyst"]))
}

test_editor_denied_cache_path if {
    denied with input as make_input("POST", ["cache", "clear-all"], jwt_payload(["editor"]))
}

test_viewer_denied_cache_path if {
    denied with input as make_input("POST", ["risk-trees", "rt-1", "cache", "clear"], jwt_payload(["viewer"]))
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 5: Unauthenticated / no JWT — must deny on non-public routes
# ══════════════════════════════════════════════════════════════════════════════

# /w/* is now a public route (Layer 0 bypass) — tested in Group 1b.
# Non-public routes still deny without identity.

test_no_jwt_denied_on_api_route if {
    not allow with input as anon_input("POST", ["api", "test"])
}

test_no_jwt_denied_on_risk_trees_direct if {
    # /risk-trees (without /w/ prefix) is NOT a public route.
    not allow with input as anon_input("GET", ["risk-trees", "rt-1"])
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 6: Unrecognised roles — must deny
# ══════════════════════════════════════════════════════════════════════════════

test_unknown_role_denied if {
    not allow with input as make_input("GET", ["risk-trees", "rt-1"], jwt_payload(["hacker"]))
}

test_empty_roles_denied if {
    not allow with input as make_input("GET", ["risk-trees", "rt-1"], jwt_payload([]))
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 7: Edge cases
# ══════════════════════════════════════════════════════════════════════════════

test_missing_realm_access_denied if {
    inp := {
        "parsed_path": ["risk-trees", "rt-1"],
        "request": {"http": {"method": "GET", "headers": {}}},
        "parsed_jwt": {"payload": {"sub": "test-user", "email": "test@example.com"}},
    }
    not allow with input as inp
}

test_get_on_cache_path_denied_for_analyst if {
    # Cache admin gate fires for is_cache_admin_path regardless of HTTP method.
    # Analyst has a recognized role, but denied fires because not team_admin.
    # THREAT-CATALOG L1: allow must return false because denied is true.
    inp := make_input("GET", ["risk-trees", "rt-1", "cache", "status"], jwt_payload(["analyst"]))
    not allow with input as inp
    denied with input as inp
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 8: THREAT-CATALOG L1 — deny integration into allow
#
#  These tests verify the SOLE correctness property that matters for production:
#  when a deny condition fires, `allow` returns false. If these tests fail,
#  the ext_authz decision path (register/authz/allow) silently bypasses deny.
# ══════════════════════════════════════════════════════════════════════════════

test_L1_viewer_write_blocked_at_allow_level if {
    # Viewer POST on a protected (non-public) route: denied fires AND allow must be false.
    # /w/* routes are public (Layer 0) and bypass role checks entirely.
    # This test uses /risk-trees/* which requires authentication + role.
    inp := make_input("POST", ["risk-trees", "rt-1"], jwt_payload(["viewer"]))
    not allow with input as inp
    denied with input as inp
}

test_L1_analyst_cache_blocked_at_allow_level if {
    # Analyst on cache path: denied fires AND allow must be false.
    inp := make_input("POST", ["risk-trees", "rt-1", "cache", "clear"], jwt_payload(["analyst"]))
    not allow with input as inp
    denied with input as inp
}

test_L1_editor_cache_clear_all_blocked_at_allow_level if {
    # Editor on /cache/clear-all: denied fires AND allow must be false.
    inp := make_input("POST", ["cache", "clear-all"], jwt_payload(["editor"]))
    not allow with input as inp
    denied with input as inp
}

test_L1_admin_write_not_blocked if {
    # team_admin on non-cache path: not denied, allow is true.
    # Confirms deny integration doesn't over-block.
    inp := make_input("POST", ["w", "abc123", "risk-trees"], jwt_payload(["team_admin"]))
    allow with input as inp
    not denied with input as inp
}

test_L1_admin_cache_not_blocked if {
    # team_admin on cache path: not denied, allow is true.
    inp := make_input("POST", ["cache", "clear-all"], jwt_payload(["team_admin"]))
    allow with input as inp
    not denied with input as inp
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 9: Header-based input (primary path — mesh-injected x-user-roles)
#
#  These tests use x-user-roles header instead of parsed_jwt, matching the
#  actual wire format at the waypoint. The policy reads headers first,
#  falls back to parsed_jwt for backward compatibility.
# ══════════════════════════════════════════════════════════════════════════════

test_header_analyst_can_read if {
    allow with input as make_header_input("GET", ["w", "abc123", "risk-trees"], ["analyst"])
}

test_header_editor_can_write if {
    allow with input as make_header_input("PUT", ["w", "abc123", "risk-trees"], ["editor"])
}

test_header_admin_can_access_cache if {
    allow with input as make_header_input("POST", ["cache", "clear-all"], ["team_admin"])
}

test_header_viewer_can_read if {
    # viewer is a recognized role — allow fires for GET (read).
    # The denied rule only blocks write methods.
    allow with input as make_header_input("GET", ["w", "abc123", "risk-trees"], ["viewer"])
}

test_header_viewer_write_denied if {
    # Protected route — viewer writes are blocked.
    not allow with input as make_header_input("POST", ["risk-trees", "rt-1"], ["viewer"])
}

test_header_analyst_cache_denied if {
    not allow with input as make_header_input("POST", ["risk-trees", "rt-1", "cache", "clear"], ["analyst"])
}

test_header_multi_role if {
    # Multiple roles in header — analyst satisfies has_recognized_role.
    allow with input as make_header_input("POST", ["w", "abc123", "risk-trees"], ["viewer", "analyst"])
}

test_header_empty_denied if {
    # Protected route — no roles means deny.
    not allow with input as make_header_input("GET", ["risk-trees", "rt-1"], [])
}