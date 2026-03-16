#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Regression tests: identity header security invariants
#
# Verifies the five defence layers that protect x-user-id from forgery
# (see SECURITY-FLOW.md, ADR-INFRA-004, ADR-INFRA-005).
#
# Prerequisites: kubectl, curl, jq configured against a live cluster.
# Optional: KEYCLOAK_TOKEN or test user credentials for Group 3.
#
# Run via wrapper for strict skip semantics:
#   ./tests/run-regression.sh              # exit 2 on skips
#   ./tests/run-regression.sh --allow-skip # skips OK (feature branch)
#
# Or run directly:
#   bats tests/bats/header-security.bats
# ──────────────────────────────────────────────────────────────────────────────

# ── Setup / helpers ───────────────────────────────────────────────────────────

setup() {
    INGRESS="${INGRESS:-http://localhost:8080}"
    KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.infra.svc.cluster.local/realms/register/protocol/openid-connect/token}"
    KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-register-web}"
    KEYCLOAK_TEST_USER="${KEYCLOAK_TEST_USER:-demo-editor}"
    KEYCLOAK_TEST_PASSWORD="${KEYCLOAK_TEST_PASSWORD:-editor-demo-2026}"
    KEYCLOAK_TOKEN="${KEYCLOAK_TOKEN:-}"
}

# HTTP status code helper (body discarded).
# NOTE: curl -w '%{http_code}' outputs "000" on failure AND exits non-zero.
# Using || echo "000" would append a second "000" → "000000".
# Capture in a variable and default to "000" if empty.
http_status() {
    local code
    code=$(curl -so /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$@" 2>/dev/null) || true
    echo "${code:-000}"
}

# Fetch or reuse a Keycloak JWT.  Sets KEYCLOAK_TOKEN.
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

# Require the waypoint pod to be running.  Sets WAYPOINT_POD.
require_waypoint() {
    WAYPOINT_POD=$(kubectl -n register get pods \
        -l gateway.istio.io/managed=istio.io-mesh-controller \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [ -n "$WAYPOINT_POD" ] || skip "waypoint pod not found"
}

# Require a reachable ingress (any status != 000).
require_ingress() {
    local status
    status=$(http_status "${INGRESS}/health")
    [ "$status" != "000" ] || skip "ingress not reachable at ${INGRESS}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 1: Envoy filter chain — structural verification
# ══════════════════════════════════════════════════════════════════════════════

@test "1.1 HCM request_headers_to_remove includes identity headers" {
    require_waypoint
    CONFIG_DUMP=$(kubectl -n register exec "$WAYPOINT_POD" -- \
        curl -s localhost:15000/config_dump 2>/dev/null)
    [ -n "$CONFIG_DUMP" ] || skip "could not fetch config_dump from waypoint"

    HEADERS=$(echo "$CONFIG_DUMP" | jq -r \
        '.. | .request_headers_to_remove? // empty | .[]' 2>/dev/null | sort -u)

    echo "$HEADERS" | grep -qx "x-user-id"
    echo "$HEADERS" | grep -qx "x-user-email"
    echo "$HEADERS" | grep -qx "x-user-roles"
}

@test "1.2 jwt_authn HTTP filter is present in waypoint" {
    require_waypoint
    CONFIG_DUMP=$(kubectl -n register exec "$WAYPOINT_POD" -- \
        curl -s localhost:15000/config_dump 2>/dev/null)
    [ -n "$CONFIG_DUMP" ] || skip "could not fetch config_dump"

    echo "$CONFIG_DUMP" | jq -e \
        '.. | objects | select(.name? == "envoy.filters.http.jwt_authn")' >/dev/null
}

@test "1.3 rbac HTTP filter is present in waypoint" {
    require_waypoint
    CONFIG_DUMP=$(kubectl -n register exec "$WAYPOINT_POD" -- \
        curl -s localhost:15000/config_dump 2>/dev/null)
    [ -n "$CONFIG_DUMP" ] || skip "could not fetch config_dump"

    echo "$CONFIG_DUMP" | jq -e \
        '.. | objects | select(.name? == "envoy.filters.http.rbac")' >/dev/null
}

@test "1.4 ext_authz (OPA) HTTP filter is present in waypoint" {
    require_waypoint
    CONFIG_DUMP=$(kubectl -n register exec "$WAYPOINT_POD" -- \
        curl -s localhost:15000/config_dump 2>/dev/null)
    [ -n "$CONFIG_DUMP" ] || skip "could not fetch config_dump"

    echo "$CONFIG_DUMP" | jq -e \
        '.. | objects | select(.name? == "envoy.filters.http.ext_authz")' >/dev/null
}

@test "1.5 all three HTTP filters (jwt_authn, rbac, ext_authz) coexist in filter chain" {
    require_waypoint
    CONFIG_DUMP=$(kubectl -n register exec "$WAYPOINT_POD" -- \
        curl -s localhost:15000/config_dump 2>/dev/null)
    [ -n "$CONFIG_DUMP" ] || skip "could not fetch config_dump"

    FILTERS=$(echo "$CONFIG_DUMP" | jq -r \
        '[.. | objects | select(.http_filters?) | .http_filters[]?.name // empty] | unique | .[]' 2>/dev/null)

    echo "$FILTERS" | grep -q "jwt_authn"
    echo "$FILTERS" | grep -q "rbac"
    echo "$FILTERS" | grep -q "ext_authz"
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: Unauthenticated request behaviour
# ══════════════════════════════════════════════════════════════════════════════

@test "2.1 /health returns 200 without JWT (public route)" {
    require_ingress
    run http_status "${INGRESS}/health"
    [ "$output" = "200" ]
}

@test "2.2 authenticated route rejects request without JWT" {
    require_ingress
    run http_status "${INGRESS}/api/test-auth-required"
    [[ "$output" =~ ^(401|403)$ ]]
}

@test "2.3 forged x-user-id without JWT does not grant access" {
    require_ingress
    run http_status \
        -H "x-user-id: 00000000-0000-0000-0000-000000000001" \
        "${INGRESS}/api/test-auth-required"
    [[ "$output" =~ ^(401|403)$ ]]
}

@test "2.4 forged x-user-id on public route is stripped, not denied (C1 guard)" {
    require_ingress
    run http_status -H "x-user-id: forged-value" "${INGRESS}/health"
    # Must be 200 — NOT 403.  A 403 here indicates the removed DENY policy
    # (C1 bug) has been re-introduced.
    [ "$output" = "200" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 3: Authenticated request behaviour
# ══════════════════════════════════════════════════════════════════════════════

@test "3.1 valid JWT is accepted on authenticated route" {
    require_ingress
    ensure_token || skip "no JWT available (set KEYCLOAK_TOKEN or configure test user)"
    run http_status \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
        "${INGRESS}/api/test-auth-required"
    # 200 = app handled it; 404 = app reached, route not found (auth still passed)
    [[ "$output" =~ ^(200|404)$ ]]
}

@test "3.2 valid JWT + forged x-user-id passes — header stripped, not denied (C1 regression)" {
    require_ingress
    ensure_token || skip "no JWT available"
    run http_status \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
        -H "x-user-id: forged-should-be-stripped" \
        "${INGRESS}/api/test-auth-required"
    # The old DENY policy (C1 bug) would return 403 here.
    [[ "$output" =~ ^(200|404)$ ]]
}

@test "3.3 tampered JWT is rejected" {
    require_ingress
    run http_status \
        -H "Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJmYWtlIiwiZXhwIjoxfQ.invalid" \
        "${INGRESS}/api/test-auth-required"
    [[ "$output" =~ ^(401|403)$ ]]
}

@test "3.4 app receives x-user-id matching JWT sub (echo endpoint)" {
    require_ingress
    ensure_token || skip "no JWT available"
    local body
    body=$(curl -s --connect-timeout 5 --max-time 10 \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
        "${INGRESS}/debug/headers" 2>/dev/null || echo "")
    echo "$body" | jq -e '.headers' >/dev/null 2>&1 || skip "/debug/headers not available"

    local received_id jwt_sub
    received_id=$(echo "$body" | jq -r '.headers["x-user-id"] // empty')
    jwt_sub=$(echo "$KEYCLOAK_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r '.sub // empty')

    # The forged value from test 3.2 must NOT appear.
    [ "$received_id" != "forged-should-be-stripped" ]
    # The received value must match the JWT sub claim.
    [ -n "$received_id" ]
    [ "$received_id" = "$jwt_sub" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 4: Network layer isolation
# ══════════════════════════════════════════════════════════════════════════════

@test "4.1 direct pod access is blocked by NetworkPolicy" {
    local pod_ip
    pod_ip=$(kubectl -n register get pods -l app.kubernetes.io/name=register \
        -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
    [ -n "$pod_ip" ] || skip "no register app pod found"

    # From outside the cluster the pod IP is not routable — timeout expected.
    # From inside (CI runner in cluster), NetworkPolicy blocks it.
    run curl -so /dev/null -w '%{http_code}' \
        --connect-timeout 3 --max-time 5 \
        "http://${pod_ip}:8080/health"
    # 000 = timeout/refused (blocked).  200 = NetworkPolicy not enforced.
    [ "$output" = "000" ]
}

@test "4.2 PeerAuthentication STRICT is active in register namespace" {
    local mode
    mode=$(kubectl -n register get peerauthentication \
        -o jsonpath='{.items[*].spec.mtls.mode}' 2>/dev/null || echo "")
    [[ "$mode" == *"STRICT"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 5: Istio resource integrity
# ══════════════════════════════════════════════════════════════════════════════

@test "5.1 RequestAuthentication keycloak-jwt exists with issuer" {
    local issuer
    issuer=$(kubectl -n register get requestauthentication keycloak-jwt \
        -o jsonpath='{.spec.jwtRules[0].issuer}' 2>/dev/null || echo "")
    [ -n "$issuer" ]
}

@test "5.2 outputClaimToHeaders maps sub to x-user-id" {
    local header claim
    header=$(kubectl -n register get requestauthentication keycloak-jwt \
        -o jsonpath='{.spec.jwtRules[0].outputClaimToHeaders[0].header}' 2>/dev/null || echo "")
    claim=$(kubectl -n register get requestauthentication keycloak-jwt \
        -o jsonpath='{.spec.jwtRules[0].outputClaimToHeaders[0].claim}' 2>/dev/null || echo "")
    [ "$header" = "x-user-id" ]
    [ "$claim" = "sub" ]
}

@test "5.3 AuthorizationPolicy require-jwt exists with ALLOW action" {
    local action
    action=$(kubectl -n register get authorizationpolicy require-jwt \
        -o jsonpath='{.spec.action}' 2>/dev/null || echo "")
    [ "$action" = "ALLOW" ]
}

@test "5.4 no DENY AuthorizationPolicy targets identity headers (C1 guard)" {
    local deny_names
    deny_names=$(kubectl -n register get authorizationpolicy \
        -o jsonpath='{range .items[?(@.spec.action=="DENY")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
    # If any DENY policy has "forwarded", "identity", or "header" in its name,
    # the deleted C1 policy may have been re-introduced.
    if [ -n "$deny_names" ]; then
        ! echo "$deny_names" | grep -qi "forwarded\|identity\|header"
    fi
}

@test "5.5 EnvoyFilter strip-identity-headers exists" {
    local name
    name=$(kubectl -n register get envoyfilter strip-identity-headers \
        -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
    [ "$name" = "strip-identity-headers" ]
}

@test "5.6 EnvoyFilter opa-ext-authz exists" {
    local name
    name=$(kubectl -n register get envoyfilter opa-ext-authz \
        -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
    [ "$name" = "opa-ext-authz" ]
}
