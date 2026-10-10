#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Regression tests: the mesh denies every path under /admin
#
# The register application serves one administrative route, DELETE
# /admin/workspaces/expired, which evicts every expired workspace and cascade-
# deletes its trees. It is not reachable from outside the cluster, and the
# component that refuses it is the waypoint's deny-admin-paths
# AuthorizationPolicy.
#
# WHY THE TESTS BELOW GO THROUGH THE REGISTER SERVICE AND NOT THE INGRESS
# The nginx SPA server also stops /admin, because its configuration has no
# location for that prefix and the path falls to the SPA catch-all. A request
# arriving over the ingress therefore cannot say which component refused it,
# and would pass whether or not the mesh policy existed. Groups 2 asks the
# register Service directly from a pod inside the register namespace: that
# traffic is service-addressed, so it is routed through the waypoint, and nginx
# is not on the path at all.
#
# WHY GROUP 2 USES A VALID TOKEN
# With no token the request is refused in every configuration, because
# require-jwt does not match and allow-capability-urls does not list /admin —
# Istio's default deny applies as soon as no ALLOW policy matches. That
# refusal proves nothing about deny-admin-paths. A token makes require-jwt
# match, so the request would be allowed; a 403 is then attributable to the
# DENY policy, and only to it. Test 2.2 is the control establishing that the
# same token IS accepted on another protected path.
#
# ADR-INFRA-004 §3 (waypoint-scoped L7 policy), ADR-INFRA-005 (test layering)
#
# Prerequisites: kubectl, curl, jq, waypoint deployed, register app deployed,
# Keycloak reachable from inside the cluster with the demo realm loaded.
#
# Run:   bats tests/bats/admin-path-deny.bats
# ──────────────────────────────────────────────────────────────────────────────

load "helpers/register-probe"

# ── Setup / helpers ───────────────────────────────────────────────────────────

setup() {
    INGRESS="${INGRESS:-http://localhost:8080}"
    ADMIN_PATH="/admin/workspaces/expired"
    POLICY="deny-admin-paths"
}

teardown() {
    register_probe_delete admin-deny-probe 2>/dev/null || true
}

# HTTP status code helper.
# curl -w '%{http_code}' prints "000" on failure AND exits non-zero, so the
# value is captured into a variable rather than piped through a fallback.
http_status() {
    local code
    code=$(curl -sko /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$@" 2>/dev/null) || true
    echo "${code:-000}"
}

require_waypoint() {
    WAYPOINT_POD=$(kubectl -n register get pods \
        -l gateway.istio.io/managed=istio.io-mesh-controller \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [ -n "$WAYPOINT_POD" ] || skip "waypoint pod not found — mesh deny tests need the waypoint"
}

require_register_app() {
    local ready
    ready=$(kubectl -n register get pods -l app.kubernetes.io/name=register \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [ -n "$ready" ] || skip "register app pod not running — in-cluster probe has no destination"
}

require_policy() {
    kubectl -n register get authorizationpolicy "$POLICY" -o name >/dev/null 2>&1 \
        || skip "AuthorizationPolicy ${POLICY} not applied to the cluster"
}

require_ingress() {
    local status
    status=$(http_status "${INGRESS}/health")
    [ "$status" != "000" ] || skip "ingress not reachable at ${INGRESS}"
}

waypoint_config_dump() {
    kubectl -n register exec "$WAYPOINT_POD" -- \
        curl -s localhost:15000/config_dump 2>/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 1: the policy exists and reached the proxy
# ══════════════════════════════════════════════════════════════════════════════

@test "1.1 deny-admin-paths AuthorizationPolicy exists with action DENY" {
    require_policy
    local action
    action=$(kubectl -n register get authorizationpolicy "$POLICY" \
        -o jsonpath='{.spec.action}' 2>/dev/null || echo "")
    [ "$action" = "DENY" ]
}

@test "1.2 deny-admin-paths is attached to the waypoint Gateway, not to pods by selector" {
    require_policy
    local kind name selector
    kind=$(kubectl -n register get authorizationpolicy "$POLICY" \
        -o jsonpath='{.spec.targetRef.kind}' 2>/dev/null || echo "")
    name=$(kubectl -n register get authorizationpolicy "$POLICY" \
        -o jsonpath='{.spec.targetRef.name}' 2>/dev/null || echo "")
    selector=$(kubectl -n register get authorizationpolicy "$POLICY" \
        -o jsonpath='{.spec.selector}' 2>/dev/null || echo "")
    [ "$kind" = "Gateway" ]
    [ "$name" = "waypoint" ]
    # ztunnel drops HTTP rules attached by selector — the policy would then
    # deny nothing while still reading as enforced (ADR-INFRA-004 §3).
    [ -z "$selector" ]
}

@test "1.3 deny-admin-paths covers the /admin prefix and the bare /admin path" {
    require_policy
    local paths
    paths=$(kubectl -n register get authorizationpolicy "$POLICY" \
        -o jsonpath='{.spec.rules[*].to[*].operation.paths[*]}' 2>/dev/null || echo "")
    # Istio reads a trailing /* as prefix "/admin/", which never matches the
    # exact string "/admin" — both entries are required.
    [[ "$paths" == *"/admin/*"* ]]
    [[ "$paths" == *"/admin"* ]]
}

@test "1.4 the waypoint's Envoy RBAC configuration names the deny-admin-paths policy" {
    require_waypoint
    require_policy
    local dump
    dump=$(waypoint_config_dump)
    [ -n "$dump" ] || skip "could not fetch config_dump from the waypoint"
    # Istio keys each RBAC policy as ns[...]-policy[<name>]-rule[n]; the name
    # appearing here is what proves the manifest reached the proxy rather than
    # merely existing in the API server.
    echo "$dump" | grep -q "$POLICY"
}

@test "1.5 the waypoint's RBAC configuration carries the /admin path matcher" {
    require_waypoint
    require_policy
    local dump
    dump=$(waypoint_config_dump)
    [ -n "$dump" ] || skip "could not fetch config_dump from the waypoint"
    echo "$dump" | jq -e '
        [.. | objects | select(.name? == "envoy.filters.http.rbac")]
        | tostring | test("/admin")
    ' >/dev/null
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: the mesh refuses /admin with nginx off the request path
# ══════════════════════════════════════════════════════════════════════════════

@test "2.1 the in-cluster probe reaches the application through the waypoint" {
    require_waypoint
    require_register_app
    local out="${BATS_TEST_TMPDIR}/probe-health"
    # No token: /health is listed by allow-capability-urls, so this establishes
    # that the probe pod, the NetworkPolicies and the waypoint route are all
    # working. Without this control a 403 below could mean a broken probe.
    register_probe admin-deny-probe GET /health "$out" || skip "probe pod did not complete"
    [ "$(register_probe_status "$out")" = "200" ]
}

@test "2.2 the probe's Keycloak token is accepted on a protected path (control)" {
    require_waypoint
    require_register_app
    local out="${BATS_TEST_TMPDIR}/probe-trees"
    register_probe admin-deny-probe GET /risk-trees "$out" token || skip "probe pod did not complete"
    local status
    status=$(register_probe_status "$out")
    [ "$status" != "TOKEN_FAILED" ] || skip "Keycloak did not issue a token for the demo user"
    # /risk-trees is not in allow-capability-urls, so reaching the application
    # at all means require-jwt matched and the mesh accepted the token. Any
    # status other than 403 shows the request was not refused by mesh policy.
    [ "$status" != "403" ]
}

@test "2.3 an authenticated request to /admin is refused by the mesh" {
    require_waypoint
    require_register_app
    require_policy
    local out="${BATS_TEST_TMPDIR}/probe-admin-auth"
    register_probe admin-deny-probe DELETE "$ADMIN_PATH" "$out" token || skip "probe pod did not complete"
    local status
    status=$(register_probe_status "$out")
    [ "$status" != "TOKEN_FAILED" ] || skip "Keycloak did not issue a token for the demo user"
    # The same token was accepted in 2.2, and nginx is not on this path, so
    # deny-admin-paths is the only component that can produce this refusal.
    [ "$status" = "403" ]
}

@test "2.4 the refusal comes from Envoy's RBAC filter, not from OPA or the application" {
    require_waypoint
    require_register_app
    require_policy
    local out="${BATS_TEST_TMPDIR}/probe-admin-body"
    register_probe admin-deny-probe DELETE "$ADMIN_PATH" "$out" token || skip "probe pod did not complete"
    [ "$(register_probe_status "$out")" != "TOKEN_FAILED" ] || skip "Keycloak did not issue a token"
    # Envoy's RBAC filter answers a denied request with this fixed body. OPA
    # ext_authz and the application both produce a JSON error instead, so the
    # string attributes the refusal to the AuthorizationPolicy. The RBAC filter
    # also runs before ext_authz, so OPA is never consulted for this path.
    register_probe_body "$out" | grep -q "RBAC: access denied"
}

@test "2.5 an unauthenticated request to /admin is refused as well" {
    require_waypoint
    require_register_app
    local out="${BATS_TEST_TMPDIR}/probe-admin-anon"
    register_probe admin-deny-probe DELETE "$ADMIN_PATH" "$out" || skip "probe pod did not complete"
    # Weaker than 2.3 on purpose: with no principal the default deny would
    # produce this too. It pins that no future ALLOW policy opens the path to
    # anonymous callers.
    [ "$(register_probe_status "$out")" = "403" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 3: the path is closed end to end, and nothing else moved
# ══════════════════════════════════════════════════════════════════════════════

@test "3.1 /admin over the ingress is refused rather than answered with the SPA shell" {
    require_ingress
    require_policy
    local status
    status=$(http_status -X DELETE "${INGRESS}${ADMIN_PATH}")
    # Before this policy the waypoint admitted the request and nginx answered
    # the catch-all with index.html and status 200. A 403 is the mesh refusing
    # one hop earlier.
    [ "$status" = "403" ]
}

@test "3.2 the SPA shell is still served for ordinary browser navigation" {
    require_ingress
    local status
    status=$(http_status -H "Accept: text/html" "${INGRESS}/")
    [ "$status" = "200" ]
}

@test "3.3 the public capability and health routes still answer" {
    require_ingress
    [ "$(http_status "${INGRESS}/health")" = "200" ]
}
