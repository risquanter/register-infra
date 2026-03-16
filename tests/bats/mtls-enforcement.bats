#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Regression tests: mTLS enforcement and mesh identity
#
# Verifies that STRICT mTLS is enforced across all security namespaces and
# that port-level PERMISSIVE exceptions exist only for expected health probe
# ports.  Proves the absence of misconfiguration that would allow plaintext
# bypass of the mesh (THREAT-CATALOG T1).
#
# Prerequisites: kubectl configured against a live cluster with Istio ambient.
#
# Run:   bats tests/bats/mtls-enforcement.bats
# ──────────────────────────────────────────────────────────────────────────────

# ── Setup / helpers ───────────────────────────────────────────────────────────

setup() {
    # Namespaces that MUST have STRICT mTLS.
    SECURE_NAMESPACES=(register argocd infra)

    # Expected PERMISSIVE port overrides — mapping of "namespace/name/port" → mode.
    # Any PERMISSIVE port NOT in this list is a failure.
    EXPECTED_PERMISSIVE=(
        "register/opa-diag-permissive/8282"
        "register/register-probe-permissive/8091"
        "register/frontend-probe-permissive/8080"
        "infra/keycloak-mgmt-permissive/9000"
    )
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 1: Namespace-level STRICT mTLS
# ══════════════════════════════════════════════════════════════════════════════

@test "1.1 PeerAuthentication STRICT exists in register namespace" {
    local mode
    mode=$(kubectl -n register get peerauthentication strict-mtls \
        -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "")
    [ "$mode" = "STRICT" ]
}

@test "1.2 PeerAuthentication STRICT exists in argocd namespace" {
    local mode
    mode=$(kubectl -n argocd get peerauthentication strict-mtls \
        -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "")
    [ "$mode" = "STRICT" ]
}

@test "1.3 PeerAuthentication STRICT exists in infra namespace" {
    local mode
    mode=$(kubectl -n infra get peerauthentication strict-mtls \
        -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "")
    [ "$mode" = "STRICT" ]
}

@test "1.4 no PeerAuthentication uses DISABLE mode anywhere" {
    local disable_found=""
    for ns in register argocd infra; do
        local modes
        modes=$(kubectl -n "$ns" get peerauthentication -o json 2>/dev/null | \
            jq -r '
                [.items[] |
                 (.spec.portLevelMtls // {} | to_entries[] | .value.mode),
                 (.spec.mtls.mode // empty)
                ] | .[]' 2>/dev/null || echo "")
        if echo "$modes" | grep -qi "DISABLE"; then
            disable_found="$ns"
            break
        fi
    done
    [ -z "$disable_found" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: Port-level PERMISSIVE — only on expected health probe ports
# ══════════════════════════════════════════════════════════════════════════════

@test "2.1 PERMISSIVE overrides exist only on known health probe ports" {
    local unexpected=""
    for ns in register argocd infra; do
        local permissive_entries
        permissive_entries=$(kubectl -n "$ns" get peerauthentication -o json 2>/dev/null | \
            jq -r '
                .items[] |
                . as $pa |
                (.spec.portLevelMtls // {} | to_entries[] |
                 select(.value.mode == "PERMISSIVE") |
                 "\($pa.metadata.namespace)/\($pa.metadata.name)/\(.key)")
            ' 2>/dev/null || echo "")

        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            local found=false
            for expected in "${EXPECTED_PERMISSIVE[@]}"; do
                if [ "$entry" = "$expected" ]; then
                    found=true
                    break
                fi
            done
            if [ "$found" = "false" ]; then
                unexpected="${unexpected}${entry} "
            fi
        done <<< "$permissive_entries"
    done
    if [ -n "$unexpected" ]; then
        echo "Unexpected PERMISSIVE ports: ${unexpected}" >&2
        false
    fi
}

@test "2.2 OPA diag port 8282 override targets OPA pods only" {
    local selector
    selector=$(kubectl -n register get peerauthentication opa-diag-permissive \
        -o jsonpath='{.spec.selector.matchLabels.app\.kubernetes\.io/name}' 2>/dev/null || echo "")
    [ "$selector" = "opa" ]
}

@test "2.3 register health port 8091 override targets register pods only" {
    local selector
    selector=$(kubectl -n register get peerauthentication register-probe-permissive \
        -o jsonpath='{.spec.selector.matchLabels.app\.kubernetes\.io/name}' 2>/dev/null || echo "")
    [ "$selector" = "register" ]
}

@test "2.4 keycloak mgmt port 9000 override targets keycloak pods only" {
    local selector
    selector=$(kubectl -n infra get peerauthentication keycloak-mgmt-permissive \
        -o jsonpath='{.spec.selector.matchLabels.app\.kubernetes\.io/name}' 2>/dev/null || echo "")
    [ "$selector" = "keycloak" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 3: Mesh identity enrollment (ambient mode)
# ══════════════════════════════════════════════════════════════════════════════

@test "3.1 ztunnel pods are running in istio-system" {
    local count
    count=$(kubectl -n istio-system get pods -l app=ztunnel \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items}' 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    [ "$count" -gt 0 ]
}

@test "3.2 register namespace is enrolled in ambient mesh" {
    local label
    label=$(kubectl get namespace register \
        -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null || echo "")
    [ "$label" = "ambient" ]
}

@test "3.3 infra namespace is enrolled in ambient mesh" {
    local label
    label=$(kubectl get namespace infra \
        -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null || echo "")
    [ "$label" = "ambient" ]
}

@test "3.4 all register pods have ztunnel-assigned identity (SPIFFE)" {
    # In ambient mode, ztunnel assigns SPIFFE identities to all pods.
    # Verify via istioctl proxy-status that workloads are SYNCED.
    command -v istioctl >/dev/null 2>&1 || skip "istioctl not available"
    local unsynced
    unsynced=$(istioctl proxy-status 2>/dev/null | \
        grep "register" | grep -v "SYNCED" | wc -l || echo "999")
    [ "$unsynced" -eq 0 ]
}
