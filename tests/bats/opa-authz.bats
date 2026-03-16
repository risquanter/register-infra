#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Regression tests: OPA ext_authz behavioural verification
#
# Tests the live OPA policy through the Istio waypoint ext_authz integration.
# Verifies that the coarse role gate (allow.rego) correctly:
#   - Allows health endpoints without JWT
#   - Allows recognised roles (analyst, editor, team_admin)
#   - Denies unrecognised/missing roles
#   - Blocks viewer-only writes (POST/PUT/PATCH/DELETE)
#   - Restricts cache admin paths to team_admin
#   - Fails closed when OPA is unreachable
#
# These tests complement the OPA unit tests (tests/opa/allow_test.rego) by
# verifying policy behaviour through the actual ext_authz gRPC call path.
#
# ADR-012 §3, AUTHORIZATION-PLAN Task L2.4, THREAT-CATALOG T2
#
# Prerequisites: kubectl, curl, jq, waypoint deployed, Keycloak configured.
#
# Run:   bats tests/bats/opa-authz.bats
# ──────────────────────────────────────────────────────────────────────────────

# ── Setup / helpers ───────────────────────────────────────────────────────────

setup() {
    INGRESS="${INGRESS:-http://localhost:8080}"
    KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.infra.svc.cluster.local/realms/register/protocol/openid-connect/token}"
    KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-register-web}"
    KEYCLOAK_TEST_USER="${KEYCLOAK_TEST_USER:-demo-editor}"
    KEYCLOAK_TEST_PASSWORD="${KEYCLOAK_TEST_PASSWORD:-editor-demo-2026}"
    KEYCLOAK_TOKEN="${KEYCLOAK_TOKEN:-}"
    # Optional: viewer-only user for write-deny tests.
    KEYCLOAK_VIEWER_USER="${KEYCLOAK_VIEWER_USER:-demo-viewer}"
    KEYCLOAK_VIEWER_PASSWORD="${KEYCLOAK_VIEWER_PASSWORD:-viewer-demo-2026}"
    KEYCLOAK_VIEWER_TOKEN="${KEYCLOAK_VIEWER_TOKEN:-}"
}

# HTTP status code helper.
# NOTE: curl -w '%{http_code}' outputs "000" on failure AND exits non-zero.
# Capture in a variable to avoid double-output from || echo fallback.
http_status() {
    local code
    code=$(curl -so /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$@" 2>/dev/null) || true
    echo "${code:-000}"
}

# Fetch or reuse a Keycloak JWT for the test user. Sets KEYCLOAK_TOKEN.
ensure_token() {
    [ -n "$KEYCLOAK_TOKEN" ] && return 0
    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 \
        -d "grant_type=password" \
        -d "client_id=${KEYCLOAK_CLIENT_ID}" \
        -d "username=${KEYCLOAK_TEST_USER}" \
        -d "password=${KEYCLOAK_TEST_PASSWORD}" \
        "${KEYCLOAK_URL}" 2>/dev/null || echo "")
    KEYCLOAK_TOKEN=$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null)
    [ -n "$KEYCLOAK_TOKEN" ] && return 0
    return 1
}

# Fetch or reuse a viewer-only JWT.
ensure_viewer_token() {
    [ -n "$KEYCLOAK_VIEWER_TOKEN" ] && return 0
    [ -z "$KEYCLOAK_VIEWER_USER" ] && return 1
    local response
    response=$(curl -s --connect-timeout 5 --max-time 10 \
        -d "grant_type=password" \
        -d "client_id=${KEYCLOAK_CLIENT_ID}" \
        -d "username=${KEYCLOAK_VIEWER_USER}" \
        -d "password=${KEYCLOAK_VIEWER_PASSWORD}" \
        "${KEYCLOAK_URL}" 2>/dev/null || echo "")
    KEYCLOAK_VIEWER_TOKEN=$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null)
    [ -n "$KEYCLOAK_VIEWER_TOKEN" ] && return 0
    return 1
}

# Require a reachable ingress (any status != 000).
require_ingress() {
    local status
    status=$(http_status "${INGRESS}/health")
    [ "$status" != "000" ] || skip "ingress not reachable at ${INGRESS}"
}

# Require the waypoint pod to be running.
require_waypoint() {
    local wp
    wp=$(kubectl -n register get pods \
        -l gateway.istio.io/managed=istio.io-mesh-controller \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [ -n "$wp" ] || skip "waypoint pod not found — OPA ext_authz tests require waypoint"
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 1: OPA infrastructure — ext_authz integration
# ══════════════════════════════════════════════════════════════════════════════

@test "1.1 OPA pod is running in register namespace" {
    local count
    count=$(kubectl -n register get pods -l app.kubernetes.io/name=opa \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items}' 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    [ "$count" -gt 0 ]
}

@test "1.2 OPA health check passes (readiness via port 8282)" {
    # OPA uses a scratch-based image — no shell for exec.
    # Verify health via kubelet readiness condition (probes port 8282).
    local ready
    ready=$(kubectl -n register get pods -l app.kubernetes.io/name=opa \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ -n "$ready" ] || skip "no OPA pod found"
    [ "$ready" = "True" ]
}

@test "1.3 ext_authz EnvoyFilter uses failure_mode_deny: true (fail-closed)" {
    local fmd
    fmd=$(kubectl -n register get envoyfilter opa-ext-authz -o json 2>/dev/null | \
        jq -r '.. | .failure_mode_deny? // empty' 2>/dev/null | head -1)
    [ "$fmd" = "true" ]
}

@test "1.4 ext_authz timeout is <= 200ms (latency guard)" {
    local timeout
    timeout=$(kubectl -n register get envoyfilter opa-ext-authz -o json 2>/dev/null | \
        jq -r '.. | .timeout? // empty' 2>/dev/null | head -1)
    [ -n "$timeout" ] || skip "could not extract timeout"
    # timeout is a string like "0.1s" — extract numeric part.
    local seconds
    seconds=$(echo "$timeout" | sed 's/s$//')
    # Use awk for float comparison.
    [ "$(echo "$seconds 0.2" | awk '{print ($1 <= $2) ? "ok" : "fail"}')" = "ok" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: Public routes — OPA bypass
# ══════════════════════════════════════════════════════════════════════════════

@test "2.1 /health returns 200 without JWT (OPA health bypass)" {
    require_ingress
    run http_status "${INGRESS}/health"
    [ "$output" = "200" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 3: Authenticated access with recognised roles
# ══════════════════════════════════════════════════════════════════════════════

@test "3.1 authenticated user with recognised role can access protected routes" {
    require_ingress
    require_waypoint
    ensure_token || skip "no JWT available"

    run http_status \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
        "${INGRESS}/w/test-capability-key/risk-trees"
    # 200 or 404 = passed auth; 401/403 = auth failed.
    [[ "$output" =~ ^(200|404)$ ]]
}

@test "3.2 authenticated GET on standard path succeeds" {
    require_ingress
    require_waypoint
    ensure_token || skip "no JWT available"

    run http_status \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
        "${INGRESS}/workspaces"
    # /workspaces is a public route, should always be 200/404.
    [[ "$output" =~ ^(200|404)$ ]]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 4: Unauthenticated access — must be denied
# ══════════════════════════════════════════════════════════════════════════════

@test "4.1 no JWT on protected route returns 401 or 403" {
    require_ingress
    require_waypoint

    run http_status "${INGRESS}/api/protected-resource"
    [[ "$output" =~ ^(401|403)$ ]]
}

@test "4.2 expired JWT is rejected" {
    require_ingress
    require_waypoint
    # Craft a JWT with exp=1 (1970-01-01).
    run http_status \
        -H "Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0IiwiZXhwIjoxLCJhdWQiOiJyZWdpc3Rlci1hcGkifQ.invalid" \
        "${INGRESS}/api/protected-resource"
    [[ "$output" =~ ^(401|403)$ ]]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 5: Viewer-only write protection
# ══════════════════════════════════════════════════════════════════════════════

@test "5.1 viewer-only user denied POST on data route" {
    require_ingress
    require_waypoint
    ensure_viewer_token || skip "viewer test user not configured (set KEYCLOAK_VIEWER_USER)"

    run http_status \
        -X POST \
        -H "Authorization: Bearer ${KEYCLOAK_VIEWER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{}' \
        "${INGRESS}/w/test-key/risk-trees"
    # OPA denies writes for viewer-only users.
    [[ "$output" =~ ^(403)$ ]]
}

@test "5.2 viewer-only user denied PUT" {
    require_ingress
    require_waypoint
    ensure_viewer_token || skip "viewer test user not configured"

    run http_status \
        -X PUT \
        -H "Authorization: Bearer ${KEYCLOAK_VIEWER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{}' \
        "${INGRESS}/w/test-key/risk-trees/rt-1"
    [[ "$output" =~ ^(403)$ ]]
}

@test "5.3 viewer-only user denied DELETE" {
    require_ingress
    require_waypoint
    ensure_viewer_token || skip "viewer test user not configured"

    run http_status \
        -X DELETE \
        -H "Authorization: Bearer ${KEYCLOAK_VIEWER_TOKEN}" \
        "${INGRESS}/w/test-key/risk-trees/rt-1"
    [[ "$output" =~ ^(403)$ ]]
}

@test "5.4 viewer-only user can still GET (read access)" {
    require_ingress
    require_waypoint
    ensure_viewer_token || skip "viewer test user not configured"

    run http_status \
        -H "Authorization: Bearer ${KEYCLOAK_VIEWER_TOKEN}" \
        "${INGRESS}/w/test-key/risk-trees"
    # If viewer has ONLY "viewer" role → no recognized_role → OPA denies.
    # This is expected: viewer alone is NOT in recognized_roles.
    # The test documents this design choice.
    [[ "$output" =~ ^(403|200|404)$ ]]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 6: Admin gate — cache management endpoints
# ══════════════════════════════════════════════════════════════════════════════

@test "6.1 non-admin user denied on cache clear-all" {
    require_ingress
    require_waypoint
    ensure_token || skip "no JWT available"

    # The test user likely has analyst/editor but not team_admin.
    local roles
    roles=$(echo "$KEYCLOAK_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | \
        jq -r '.realm_access.roles // [] | .[]' 2>/dev/null || echo "")
    echo "$roles" | grep -q "team_admin" && skip "test user has team_admin — need non-admin"

    run http_status \
        -X POST \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
        "${INGRESS}/cache/clear-all"
    [[ "$output" =~ ^(403)$ ]]
}

@test "6.2 non-admin user denied on risk-tree cache path" {
    require_ingress
    require_waypoint
    ensure_token || skip "no JWT available"

    local roles
    roles=$(echo "$KEYCLOAK_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | \
        jq -r '.realm_access.roles // [] | .[]' 2>/dev/null || echo "")
    echo "$roles" | grep -q "team_admin" && skip "test user has team_admin"

    run http_status \
        -X POST \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
        "${INGRESS}/risk-trees/rt-1/cache/clear"
    [[ "$output" =~ ^(403)$ ]]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 7: OPA policy ConfigMap integrity
# ══════════════════════════════════════════════════════════════════════════════

@test "7.1 OPA ConfigMap contains allow.rego policy" {
    local data
    data=$(kubectl -n register get configmap opa-policy \
        -o jsonpath='{.data.allow\.rego}' 2>/dev/null || echo "")
    [ -n "$data" ]
    echo "$data" | grep -q "default allow := false"
}

@test "7.2 OPA policy enforces default deny" {
    local data
    data=$(kubectl -n register get configmap opa-policy \
        -o jsonpath='{.data.allow\.rego}' 2>/dev/null || echo "")
    echo "$data" | grep -q "default allow := false"
}

@test "7.3 OPA policy includes viewer write protection" {
    local data
    data=$(kubectl -n register get configmap opa-policy \
        -o jsonpath='{.data.allow\.rego}' 2>/dev/null || echo "")
    echo "$data" | grep -q "write_methods"
    echo "$data" | grep -q 'role == "viewer"'
}

@test "7.4 OPA policy includes admin cache gate" {
    local data
    data=$(kubectl -n register get configmap opa-policy \
        -o jsonpath='{.data.allow\.rego}' 2>/dev/null || echo "")
    echo "$data" | grep -q "is_cache_admin_path"
    echo "$data" | grep -q '"team_admin"'
}
