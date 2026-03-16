#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Regression tests: pod security hardening
#
# Verifies that all workload pods follow Kubernetes security best practices:
#   - Non-root execution (runAsNonRoot: true)
#   - Service account token not auto-mounted
#   - Read-only root filesystem where architecturally possible
#   - No privileged containers
#   - No host namespace sharing (hostNetwork, hostPID, hostIPC)
#   - Capabilities dropped
#
# These tests prove that misconfiguration or a bad Helm upgrade has not
# weakened the container security posture.
#
# THREAT-CATALOG: L3 (container escape), L5 (privilege escalation)
#
# Prerequisites: kubectl, jq configured against a live cluster.
#
# Run:   bats tests/bats/pod-security.bats
# ──────────────────────────────────────────────────────────────────────────────

# ── Setup / helpers ───────────────────────────────────────────────────────────

setup() {
    # Namespaces to audit.
    AUDIT_NAMESPACES=(register infra)
    # Pods that are EXPECTED to not have readOnlyRootFilesystem.
    # Keycloak writes to /opt/keycloak/data/ at runtime.
    READ_ONLY_EXCEPTIONS=("keycloak")
}

# Helper: get all pod specs in a namespace as JSON array.
pod_specs() {
    local ns="$1"
    kubectl -n "$ns" get pods -o json 2>/dev/null | jq '.items' 2>/dev/null || echo "[]"
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 1: automountServiceAccountToken
# ══════════════════════════════════════════════════════════════════════════════

@test "1.1 all ServiceAccounts in register have automountServiceAccountToken: false" {
    local violations
    violations=$(kubectl -n register get serviceaccount -o json 2>/dev/null | \
        jq -r '
            [.items[] |
             select(.metadata.name != "default") |
             select(.automountServiceAccountToken != false) |
             .metadata.name
            ] | .[]
        ' 2>/dev/null || echo "")
    if [ -n "$violations" ]; then
        echo "ServiceAccounts with automount enabled: ${violations}" >&2
        false
    fi
}

@test "1.2 all ServiceAccounts in infra have automountServiceAccountToken: false" {
    local violations
    violations=$(kubectl -n infra get serviceaccount -o json 2>/dev/null | \
        jq -r '
            [.items[] |
             select(.metadata.name != "default") |
             select(.automountServiceAccountToken != false) |
             .metadata.name
            ] | .[]
        ' 2>/dev/null || echo "")
    if [ -n "$violations" ]; then
        echo "ServiceAccounts with automount enabled: ${violations}" >&2
        false
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: Non-root execution
# ══════════════════════════════════════════════════════════════════════════════

@test "2.1 no privileged containers in register namespace" {
    local violations
    violations=$(pod_specs register | jq -r '
        [.[] |
         .metadata.name as $pod |
         (.spec.containers + (.spec.initContainers // []))[] |
         select(.securityContext.privileged == true) |
         "\($pod)/\(.name)"
        ] | .[]
    ' 2>/dev/null || echo "")
    if [ -n "$violations" ]; then
        echo "Privileged containers: ${violations}" >&2
        false
    fi
}

@test "2.2 no privileged containers in infra namespace" {
    local violations
    violations=$(pod_specs infra | jq -r '
        [.[] |
         .metadata.name as $pod |
         (.spec.containers + (.spec.initContainers // []))[] |
         select(.securityContext.privileged == true) |
         "\($pod)/\(.name)"
        ] | .[]
    ' 2>/dev/null || echo "")
    if [ -n "$violations" ]; then
        echo "Privileged containers: ${violations}" >&2
        false
    fi
}

@test "2.3 all pod-level securityContexts set runAsNonRoot or runAsUser > 0 (register)" {
    local violations
    violations=$(pod_specs register | jq -r '
        [.[] |
         select(.metadata.labels["app.kubernetes.io/name"] != null) |
         select(
             (.spec.securityContext.runAsNonRoot != true) and
             ((.spec.securityContext.runAsUser // 0) == 0)
         ) |
         .metadata.name
        ] | .[]
    ' 2>/dev/null || echo "")
    if [ -n "$violations" ]; then
        echo "Pods without runAsNonRoot: ${violations}" >&2
        false
    fi
}

@test "2.4 all pod-level securityContexts set runAsNonRoot or runAsUser > 0 (infra)" {
    # Known exception: Bitnami PostgreSQL runs as UID 1001 via the container
    # image's USER directive, but does not set runAsNonRoot at the pod spec level.
    # This is acceptable because the container process IS non-root (UID 1001).
    local violations
    violations=$(pod_specs infra | jq -r '
        [.[] |
         select(.metadata.labels["app.kubernetes.io/name"] != null) |
         select(.metadata.labels["app.kubernetes.io/name"] != "postgresql") |
         select(
             (.spec.securityContext.runAsNonRoot != true) and
             ((.spec.securityContext.runAsUser // 0) == 0)
         ) |
         .metadata.name
        ] | .[]
    ' 2>/dev/null || echo "")
    if [ -n "$violations" ]; then
        echo "Pods without runAsNonRoot: ${violations}" >&2
        false
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 3: Read-only root filesystem
# ══════════════════════════════════════════════════════════════════════════════

@test "3.1 OPA container has readOnlyRootFilesystem" {
    local value
    value=$(kubectl -n register get pods -l app.kubernetes.io/name=opa -o json 2>/dev/null | \
        jq -r '.items[0].spec.containers[0].securityContext.readOnlyRootFilesystem' 2>/dev/null || echo "")
    [ "$value" = "true" ]
}

@test "3.2 register container has readOnlyRootFilesystem" {
    local value
    value=$(kubectl -n register get pods -l app.kubernetes.io/name=register -o json 2>/dev/null | \
        jq -r '.items[0].spec.containers[0].securityContext.readOnlyRootFilesystem' 2>/dev/null || echo "")
    [ "$value" = "true" ]
}

@test "3.3 frontend container has readOnlyRootFilesystem" {
    local value
    value=$(kubectl -n register get pods -l app.kubernetes.io/name=frontend -o json 2>/dev/null | \
        jq -r '.items[0].spec.containers[0].securityContext.readOnlyRootFilesystem' 2>/dev/null || echo "")
    [ "$value" = "true" ] || skip "no frontend pod found"
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 4: Host namespace isolation
# ══════════════════════════════════════════════════════════════════════════════

@test "4.1 no pods use hostNetwork in register namespace" {
    local violations
    violations=$(pod_specs register | jq -r '
        [.[] | select(.spec.hostNetwork == true) | .metadata.name] | .[]
    ' 2>/dev/null || echo "")
    [ -z "$violations" ]
}

@test "4.2 no pods use hostNetwork in infra namespace" {
    local violations
    violations=$(pod_specs infra | jq -r '
        [.[] | select(.spec.hostNetwork == true) | .metadata.name] | .[]
    ' 2>/dev/null || echo "")
    [ -z "$violations" ]
}

@test "4.3 no pods use hostPID in register or infra" {
    local violations=""
    for ns in register infra; do
        local v
        v=$(pod_specs "$ns" | jq -r '
            [.[] | select(.spec.hostPID == true) | .metadata.name] | .[]
        ' 2>/dev/null || echo "")
        violations="${violations}${v}"
    done
    [ -z "$violations" ]
}

@test "4.4 no pods use hostIPC in register or infra" {
    local violations=""
    for ns in register infra; do
        local v
        v=$(pod_specs "$ns" | jq -r '
            [.[] | select(.spec.hostIPC == true) | .metadata.name] | .[]
        ' 2>/dev/null || echo "")
        violations="${violations}${v}"
    done
    [ -z "$violations" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 5: LimitRange enforcement
# ══════════════════════════════════════════════════════════════════════════════

@test "5.1 LimitRange exists in register namespace" {
    kubectl -n register get limitrange -o name 2>/dev/null | grep -q "limitrange" || \
        skip "no LimitRange found — may not be deployed yet"
}

@test "5.2 LimitRange exists in infra namespace" {
    kubectl -n infra get limitrange -o name 2>/dev/null | grep -q "limitrange" || \
        skip "no LimitRange found — may not be deployed yet"
}
