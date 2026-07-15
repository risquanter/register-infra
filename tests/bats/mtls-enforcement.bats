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

    # All port-level PERMISSIVE probe exceptions were retired (ADR-INFRA-004 §4):
    # kubelet probes are plain HTTP allowed by per-port CiliumNetworkPolicies
    # (fromCIDR 169.254.7.127/32), so PERMISSIVE overrides must not exist at all.
    # The last one (SpiceDB gRPC :50051) was retired 2026-07-15.
    RETIRED_PERMISSIVE_PAS=(
        "register/opa-diag-permissive"
        "register/register-probe-permissive"
        "register/frontend-probe-permissive"
        "infra/keycloak-mgmt-permissive"
        "infra/spicedb-grpc-probe-permissive"
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
#  GROUP 2: No port-level PERMISSIVE exceptions anywhere
# ══════════════════════════════════════════════════════════════════════════════

@test "2.1 no PERMISSIVE override exists in any security namespace" {
    local permissive=""
    for ns in register argocd infra; do
        local entries
        entries=$(kubectl -n "$ns" get peerauthentication -o json 2>/dev/null | \
            jq -r '
                .items[] |
                . as $pa |
                (.spec.portLevelMtls // {} | to_entries[] |
                 select(.value.mode == "PERMISSIVE") |
                 "\($pa.metadata.namespace)/\($pa.metadata.name)/\(.key)")
            ' 2>/dev/null || echo "")
        [ -n "$entries" ] && permissive="${permissive}${entries} "
    done
    if [ -n "$permissive" ]; then
        echo "PERMISSIVE ports found (none are allowed): ${permissive}" >&2
        false
    fi
}

@test "2.2 retired probe-exception PeerAuthentications stay retired" {
    local resurrected=""
    for entry in "${RETIRED_PERMISSIVE_PAS[@]}"; do
        local ns="${entry%%/*}" name="${entry#*/}"
        if kubectl -n "$ns" get peerauthentication "$name" >/dev/null 2>&1; then
            resurrected="${resurrected}${entry} "
        fi
    done
    if [ -n "$resurrected" ]; then
        echo "Retired PeerAuthentication reappeared: ${resurrected}" >&2
        false
    fi
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

@test "3.4 all register app pods are captured by ztunnel (HBONE)" {
    # In ambient mode, ztunnel captures enrolled pods and tunnels their traffic
    # over HBONE with a SPIFFE identity. Every register-namespace pod must show
    # protocol HBONE in ztunnel's workload table — except the ingress gateway,
    # which is a full Envoy proxy with its own mesh identity (checked in 3.5).
    command -v istioctl >/dev/null 2>&1 || skip "istioctl not available"
    local not_hbone
    not_hbone=$(istioctl ztunnel-config workload -o json 2>/dev/null | \
        jq -r '.[] | select(.namespace == "register"
                            and .workloadType == "pod"
                            and .workloadName != "register-ingress-istio"
                            and .protocol != "HBONE") | .name' || echo "jq-failed")
    if [ -n "$not_hbone" ]; then
        echo "register pods not captured as HBONE: ${not_hbone}" >&2
        false
    fi
}

@test "3.5 ingress gateway Envoy proxy is connected to istiod" {
    # The register ingress gateway is a full Envoy proxy (not ztunnel-captured);
    # its mesh identity comes from istiod directly. Verify it appears in
    # proxy-status, i.e. it holds a live xDS connection.
    command -v istioctl >/dev/null 2>&1 || skip "istioctl not available"
    istioctl proxy-status 2>/dev/null | grep -q "register-ingress-istio.*\.register"
}
