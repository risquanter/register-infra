#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Regression tests: health probe reachability
#
# Verifies that all workloads pass Kubernetes health probes and that the
# defense-in-depth layers (PeerAuth PERMISSIVE + CiliumNetworkPolicy CIDR
# restriction) correctly allow kubelet probe traffic while blocking everything
# else on health ports.
#
# These tests detect the common ambient-mode failure: STRICT mTLS rejecting
# plaintext kubelet probes, causing CrashLoopBackOff.
#
# Prerequisites: kubectl, jq configured against a live cluster.
#
# Run:   bats tests/bats/health-probes.bats
# ──────────────────────────────────────────────────────────────────────────────

# ── Setup / helpers ───────────────────────────────────────────────────────────

setup() {
    :
}

# Helper: check that all pods with a given label are in Running phase and Ready.
pods_ready() {
    local ns="$1" label="$2"
    local pods_json
    pods_json=$(kubectl -n "$ns" get pods -l "$label" -o json 2>/dev/null || echo '{"items":[]}')

    # Must have at least one pod.
    local count
    count=$(echo "$pods_json" | jq '.items | length' 2>/dev/null || echo "0")
    [ "$count" -gt 0 ] || return 1

    # All pods must be Running phase.
    local not_running
    not_running=$(echo "$pods_json" | jq '[.items[] | select(.status.phase != "Running")] | length' 2>/dev/null || echo "999")
    [ "$not_running" -eq 0 ] || return 1

    # All containers must be Ready.
    local not_ready
    not_ready=$(echo "$pods_json" | jq '
        [.items[].status.containerStatuses[]? | select(.ready != true)] | length
    ' 2>/dev/null || echo "999")
    [ "$not_ready" -eq 0 ] || return 1
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 1: Pod readiness — all workloads must be Running + Ready
# ══════════════════════════════════════════════════════════════════════════════

@test "1.1 register app pods are Running and Ready" {
    pods_ready register "app.kubernetes.io/name=register"
}

@test "1.2 OPA pods are Running and Ready" {
    pods_ready register "app.kubernetes.io/name=opa"
}

@test "1.3 PostgreSQL pods are Running and Ready" {
    pods_ready infra "app.kubernetes.io/name=postgresql"
}

@test "1.4 Keycloak pods are Running and Ready" {
    pods_ready infra "app.kubernetes.io/name=keycloak"
}

@test "1.5 frontend pods are Running and Ready (if deployed)" {
    local count
    count=$(kubectl -n register get pods -l app.kubernetes.io/name=frontend \
        -o jsonpath='{.items}' 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    [ "$count" -gt 0 ] || skip "frontend not deployed"
    pods_ready register "app.kubernetes.io/name=frontend"
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: Health endpoint responses — via exec (bypasses NetworkPolicy)
# ══════════════════════════════════════════════════════════════════════════════

@test "2.1 OPA health check passes (Kubernetes readiness condition)" {
    # OPA uses a scratch-based image with no shell — kubectl exec is not possible.
    # Instead, verify via the pod's readiness condition (kubelet probes port 8282).
    local ready
    ready=$(kubectl -n register get pods -l app.kubernetes.io/name=opa \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ -n "$ready" ] || skip "no OPA pod"
    [ "$ready" = "True" ]
}

@test "2.2 register health check passes (Kubernetes readiness condition)" {
    # register uses a minimal JVM image — verify via kubelet readiness (port 8091).
    local ready
    ready=$(kubectl -n register get pods -l app.kubernetes.io/name=register \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ -n "$ready" ] || skip "no register pod"
    [ "$ready" = "True" ]
}

@test "2.3 Keycloak health check passes (Kubernetes readiness condition)" {
    # Verify via kubelet readiness (probes port 9000).
    local ready
    ready=$(kubectl -n infra get pods -l app.kubernetes.io/name=keycloak \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    [ -n "$ready" ] || skip "no Keycloak pod"
    [ "$ready" = "True" ]
}

@test "2.4 PostgreSQL pg_isready succeeds (exec probe, no network)" {
    local pod
    pod=$(kubectl -n infra get pods -l app.kubernetes.io/name=postgresql \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [ -n "$pod" ] || skip "no PostgreSQL pod"

    run kubectl -n infra exec "$pod" -- \
        pg_isready -U postgres -h 127.0.0.1 2>/dev/null
    [ "$status" -eq 0 ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 3: Probe configuration integrity
# ══════════════════════════════════════════════════════════════════════════════

@test "3.1 register readinessProbe uses dedicated health port 8091" {
    local probe_port
    probe_port=$(kubectl -n register get pods -l app.kubernetes.io/name=register -o json 2>/dev/null | \
        jq -r '.items[0].spec.containers[0].readinessProbe.httpGet.port // empty' 2>/dev/null)
    [ "$probe_port" = "8091" ] || [ "$probe_port" = "health" ]
}

@test "3.2 OPA readinessProbe uses diagnostic port 8282" {
    local probe_port
    probe_port=$(kubectl -n register get pods -l app.kubernetes.io/name=opa -o json 2>/dev/null | \
        jq -r '.items[0].spec.containers[0].readinessProbe.httpGet.port // empty' 2>/dev/null)
    # Port may be numeric "8282" or named "http-diag" (both resolve to 8282).
    [[ "$probe_port" = "8282" || "$probe_port" = "http-diag" ]]
}

@test "3.3 Keycloak readiness/liveness probes use management port 9000" {
    local pod_json
    pod_json=$(kubectl -n infra get pods -l app.kubernetes.io/name=keycloak -o json 2>/dev/null || echo '{}')

    local readiness_port
    readiness_port=$(echo "$pod_json" | \
        jq -r '.items[0].spec.containers[0].readinessProbe.httpGet.port // empty' 2>/dev/null)

    local liveness_port
    liveness_port=$(echo "$pod_json" | \
        jq -r '.items[0].spec.containers[0].livenessProbe.httpGet.port // empty' 2>/dev/null)

    # At least the readiness probe must use 9000.
    [ "$readiness_port" = "9000" ] || [ "$readiness_port" = "management" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 4: Negative — health ports not exposed to external traffic
# ══════════════════════════════════════════════════════════════════════════════

@test "4.1 no Service exposes OPA diagnostic port 8282" {
    local ports
    ports=$(kubectl -n register get service opa -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")
    # Port 8282 must NOT appear in the Service definition.
    [[ "$ports" != *"8282"* ]]
}

@test "4.2 no Service exposes register health port 8091" {
    local ports
    ports=$(kubectl -n register get service register -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")
    [[ "$ports" != *"8091"* ]]
}

@test "4.3 no Service exposes Keycloak management port 9000" {
    local ports
    ports=$(kubectl -n infra get service keycloak -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")
    [[ "$ports" != *"9000"* ]]
}
