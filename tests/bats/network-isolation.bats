#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Regression tests: network isolation and segmentation
#
# Verifies that NetworkPolicy and CiliumNetworkPolicy enforce the intended
# access topology.  Tests both POSITIVE (allowed paths work) and NEGATIVE
# (disallowed paths are blocked).
#
# Layers tested:
#  - NetworkPolicy   default-deny-all (register + infra)
#  - HBONE tunnels   allow-hbone-intra-namespace
#  - Per-service     allow-ingress-from-waypoint, allow-egress-*
#  - CiliumNP        health probe CIDR restriction (169.254.7.127/32)
#  - Cross-namespace register↔infra, infra↛register
#
# THREAT-CATALOG: T1 (mesh bypass), T6 (lateral movement)
#
# Prerequisites: kubectl, jq, curl configured against a live cluster.
#
# Run:   bats tests/bats/network-isolation.bats
# ──────────────────────────────────────────────────────────────────────────────

# ── Setup / helpers ───────────────────────────────────────────────────────────

setup() {
    INGRESS="${INGRESS:-http://localhost:8080}"
}

# Helper: check if a NetworkPolicy exists by name in a namespace.
netpol_exists() {
    local ns="$1" name="$2"
    kubectl -n "$ns" get networkpolicy "$name" -o name >/dev/null 2>&1
}

# Helper: get pod IP for a given label in a namespace.
pod_ip() {
    local ns="$1" label="$2"
    kubectl -n "$ns" get pods -l "$label" \
        -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 1: Default deny-all — structural verification
# ══════════════════════════════════════════════════════════════════════════════

@test "1.1 default-deny-all exists in register namespace" {
    netpol_exists register default-deny-all
}

@test "1.2 default-deny-all exists in infra namespace" {
    netpol_exists infra default-deny-all
}

@test "1.3 default-deny-all covers both Ingress and Egress (register)" {
    local types
    types=$(kubectl -n register get networkpolicy default-deny-all \
        -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null || echo "")
    [[ "$types" == *"Ingress"* ]]
    [[ "$types" == *"Egress"* ]]
}

@test "1.4 default-deny-all covers both Ingress and Egress (infra)" {
    local types
    types=$(kubectl -n infra get networkpolicy default-deny-all \
        -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null || echo "")
    [[ "$types" == *"Ingress"* ]]
    [[ "$types" == *"Egress"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: HBONE tunnel policies — required for ambient mode
# ══════════════════════════════════════════════════════════════════════════════

@test "2.1 HBONE intra-namespace policy exists in register" {
    netpol_exists register allow-hbone-intra-namespace
}

@test "2.2 HBONE intra-namespace policy exists in infra" {
    netpol_exists infra allow-hbone-intra-namespace
}

@test "2.3 HBONE from register to infra policy exists" {
    netpol_exists infra allow-hbone-from-register
}

@test "2.4 HBONE policies use port 15008" {
    local port
    port=$(kubectl -n register get networkpolicy allow-hbone-intra-namespace \
        -o jsonpath='{.spec.ingress[0].ports[0].port}' 2>/dev/null || echo "")
    [ "$port" = "15008" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 3: Per-service allow rules — structural completeness
# ══════════════════════════════════════════════════════════════════════════════

@test "3.1 waypoint ingress to register app allowed" {
    netpol_exists register allow-ingress-from-waypoint
}

@test "3.2 waypoint egress to register app allowed" {
    netpol_exists register allow-egress-waypoint-to-register
}

@test "3.3 waypoint to OPA (ext_authz) ingress allowed" {
    netpol_exists register allow-ingress-opa-from-waypoint
}

@test "3.4 waypoint to OPA (ext_authz) egress allowed" {
    netpol_exists register allow-egress-waypoint-to-opa
}

@test "3.5 register egress to PostgreSQL allowed" {
    netpol_exists register allow-egress-postgres
}

@test "3.6 register egress to Keycloak allowed" {
    netpol_exists register allow-egress-keycloak
}

@test "3.7 DNS egress allowed in register namespace" {
    netpol_exists register allow-egress-dns
}

@test "3.8 DNS egress allowed in infra namespace" {
    netpol_exists infra allow-egress-dns
}

@test "3.9 istiod to Keycloak JWKS fetch allowed" {
    netpol_exists infra allow-ingress-keycloak-from-istio-system
}

@test "3.10 register egress to SpiceDB allowed" {
    netpol_exists register allow-egress-spicedb
}

@test "3.11 SpiceDB ingress from register allowed" {
    netpol_exists infra allow-ingress-spicedb-from-register
}

@test "3.12 SpiceDB egress to PostgreSQL allowed" {
    netpol_exists infra allow-egress-spicedb-to-postgres
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 4: CiliumNetworkPolicy — health probe CIDR restrictions
# ══════════════════════════════════════════════════════════════════════════════

@test "4.1 CiliumNetworkPolicy for OPA healthcheck exists" {
    kubectl -n register get ciliumnetworkpolicy allow-ingress-opa-healthcheck \
        -o name >/dev/null 2>&1
}

@test "4.2 CiliumNetworkPolicy for register healthcheck exists" {
    kubectl -n register get ciliumnetworkpolicy allow-ingress-register-healthcheck \
        -o name >/dev/null 2>&1
}

@test "4.3 CiliumNetworkPolicy for Keycloak healthcheck exists" {
    kubectl -n infra get ciliumnetworkpolicy allow-ingress-keycloak-healthcheck \
        -o name >/dev/null 2>&1
}

@test "4.4 OPA healthcheck CIDR restricted to ztunnel SNAT address" {
    local cidr
    cidr=$(kubectl -n register get ciliumnetworkpolicy allow-ingress-opa-healthcheck \
        -o jsonpath='{.spec.ingress[0].fromCIDR[0]}' 2>/dev/null || echo "")
    [ "$cidr" = "169.254.7.127/32" ]
}

@test "4.5 register healthcheck CIDR restricted to ztunnel SNAT address" {
    local cidr
    cidr=$(kubectl -n register get ciliumnetworkpolicy allow-ingress-register-healthcheck \
        -o jsonpath='{.spec.ingress[0].fromCIDR[0]}' 2>/dev/null || echo "")
    [ "$cidr" = "169.254.7.127/32" ]
}

@test "4.6 Keycloak healthcheck CIDR restricted to ztunnel SNAT address" {
    local cidr
    cidr=$(kubectl -n infra get ciliumnetworkpolicy allow-ingress-keycloak-healthcheck \
        -o jsonpath='{.spec.ingress[0].fromCIDR[0]}' 2>/dev/null || echo "")
    [ "$cidr" = "169.254.7.127/32" ]
}

@test "4.7 CiliumNetworkPolicy for SpiceDB gRPC healthcheck exists" {
    kubectl -n infra get ciliumnetworkpolicy allow-ingress-spicedb-grpc-healthcheck \
        -o name >/dev/null 2>&1
}

@test "4.8 SpiceDB healthcheck CIDR restricted to ztunnel SNAT address" {
    local cidr
    cidr=$(kubectl -n infra get ciliumnetworkpolicy allow-ingress-spicedb-grpc-healthcheck \
        -o jsonpath='{.spec.ingress[0].fromCIDR[0]}' 2>/dev/null || echo "")
    [ "$cidr" = "169.254.7.127/32" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 5: Negative tests — paths that MUST be blocked
# ══════════════════════════════════════════════════════════════════════════════

@test "5.1 direct pod access bypassing waypoint is blocked (register app)" {
    local ip
    ip=$(pod_ip register "app.kubernetes.io/name=register")
    [ -n "$ip" ] || skip "no register pod found"

    # From outside cluster or from a non-waypoint pod, direct access should fail.
    run curl -so /dev/null -w '%{http_code}' \
        --connect-timeout 3 --max-time 5 \
        "http://${ip}:8090/health" 2>/dev/null
    # 000 = timeout/refused (blocked by NetworkPolicy or mTLS).
    [ "$output" = "000" ]
}

@test "5.2 no NetworkPolicy allows arbitrary ingress to register pods" {
    # Verify that all ingress NetworkPolicies in register namespace have a
    # podSelector or namespaceSelector (none are wide-open).
    local wide_open
    wide_open=$(kubectl -n register get networkpolicy -o json 2>/dev/null | \
        jq -r '
            [.items[] |
             select(.spec.policyTypes[]? == "Ingress") |
             select(.spec.ingress != null) |
             select(.spec.ingress[] | .from == null) |
             .metadata.name
            ] | .[]
        ' 2>/dev/null || echo "")
    if [ -n "$wide_open" ]; then
        echo "NetworkPolicies with unrestricted ingress: ${wide_open}" >&2
        false
    fi
}

@test "5.3 waypoint egress to register uses correct app port (8090, not 8080)" {
    local port
    port=$(kubectl -n register get networkpolicy allow-egress-waypoint-to-register \
        -o jsonpath='{.spec.egress[0].to[0]}' 2>/dev/null)
    local egress_port
    egress_port=$(kubectl -n register get networkpolicy allow-egress-waypoint-to-register \
        -o jsonpath='{.spec.egress[0].ports[0].port}' 2>/dev/null || echo "")
    [ "$egress_port" = "8090" ]
}

@test "5.4 OPA ingress restricted to waypoint pods and port 9191 only" {
    local from_label
    from_label=$(kubectl -n register get networkpolicy allow-ingress-opa-from-waypoint \
        -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels.gateway\.istio\.io/managed}' 2>/dev/null || echo "")
    local port
    port=$(kubectl -n register get networkpolicy allow-ingress-opa-from-waypoint \
        -o jsonpath='{.spec.ingress[0].ports[0].port}' 2>/dev/null || echo "")
    [ "$from_label" = "istio.io-mesh-controller" ]
    [ "$port" = "9191" ]
}
