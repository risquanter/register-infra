#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Regression tests: SpiceDB deployment, wiring, and mesh reachability (Layer 2)
#
# Verifies the L2 authorization backend end-to-end at the infra level:
#  - Structural    SpiceDB pods healthy, PDB present, Service ports
#  - Wiring        register-namespace key secret + register chart env injection
#  - Live probe    HTTP gateway reachable from a register-labeled pod through
#                  the ambient mesh (HBONE 15008) with preshared-key auth
#  - Schema        schema.zed definitions present in the datastore
#  - Negative      a wrong preshared key is rejected
#
# The live probe automates the manual smoke test recorded in docs/TODO.md
# Step 1 §smoke-test, including its three hard-won corrections:
#  - restricted-PSS security context (bare pods are rejected by PSS)
#  - label app.kubernetes.io/name=register (NetworkPolicies select by it;
#    unlabeled pods fall into default-deny)
#  - /v1/schema/read is POST, not GET
#
# The preshared key is injected into the probe pod via secretKeyRef and never
# materializes in the test runner's environment or output.
#
# THREAT-CATALOG: Layer 2 (instance authorization), T6 (lateral movement)
#
# Prerequisites: kubectl, jq configured against a live cluster; the
# spicedb-preshared-key-register secret applied to the register namespace.
#
# Run:   bats tests/bats/spicedb.bats
# ──────────────────────────────────────────────────────────────────────────────

# Probe-pod mechanics (manifest, apply/collect/delete, log contract) live in
# the shared helper: tests/bats/helpers/spicedb-probe.bash.
load "helpers/spicedb-probe"

PROBE_POD="bats-spicedb-probe"
BADKEY_POD="bats-spicedb-badkey"

setup_file() {
    export PROBE_LOG="${BATS_FILE_TMPDIR}/probe.log"
    export BADKEY_LOG="${BATS_FILE_TMPDIR}/badkey.log"

    # Apply both pods first so they start in parallel, then collect.
    spicedb_probe_apply "$PROBE_POD" "/v1/schema/read" '{}'
    spicedb_probe_apply "$BADKEY_POD" "/v1/schema/read" '{}' 'definitely-not-the-key'

    spicedb_probe_collect "$PROBE_POD" "$PROBE_LOG" || true
    spicedb_probe_collect "$BADKEY_POD" "$BADKEY_LOG" || true
}

teardown_file() {
    spicedb_probe_delete "$PROBE_POD" "$BADKEY_POD"
}

probe_status() { head -n1 "$1" 2>/dev/null || echo ""; }
probe_body()   { tail -n +2 "$1" 2>/dev/null || echo ""; }

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 1: Deployment health — structural verification
# ══════════════════════════════════════════════════════════════════════════════

@test "1.1 SpiceDB pods are Running and Ready" {
    local not_ready
    not_ready=$(kubectl -n infra get pods -l app.kubernetes.io/name=spicedb \
        -o json | jq -r '
            [.items[] |
             select(.status.phase != "Running" or
                    ([.status.containerStatuses[]? | select(.ready | not)] | length) > 0) |
             .metadata.name
            ] | .[]')
    local count
    count=$(kubectl -n infra get pods -l app.kubernetes.io/name=spicedb \
        -o json | jq '.items | length')
    [ "$count" -ge 1 ]
    if [ -n "$not_ready" ]; then
        echo "SpiceDB pods not Running/Ready: ${not_ready}" >&2
        false
    fi
}

@test "1.2 SpiceDB PDB exists with minAvailable 1" {
    local min
    min=$(kubectl -n infra get pdb spicedb \
        -o jsonpath='{.spec.minAvailable}' 2>/dev/null || echo "")
    [ "$min" = "1" ]
}

@test "1.3 SpiceDB Service exposes 8080 (http) and 50051 (grpc)" {
    local ports
    ports=$(kubectl -n infra get svc spicedb \
        -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")
    [[ "$ports" == *"8080"* ]]
    [[ "$ports" == *"50051"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: register-side wiring — secret + chart env injection
# ══════════════════════════════════════════════════════════════════════════════

@test "2.1 preshared-key secret exists in register namespace with expected key" {
    local keys
    keys=$(kubectl -n register get secret spicedb-preshared-key-register \
        -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys[]' 2>/dev/null || echo "")
    [[ "$keys" == *"spicedb-preshared-key"* ]]
}

@test "2.2 register Deployment injects SPICEDB_URL pointing at the infra Service" {
    local url
    url=$(kubectl -n register get deployment register -o json 2>/dev/null | \
        jq -r '.spec.template.spec.containers[0].env[]? |
               select(.name == "SPICEDB_URL") | .value')
    [ "$url" = "$SPICEDB_URL" ]
}

@test "2.3 register Deployment injects SPICEDB_TOKEN from the secret (not inline)" {
    local ref
    ref=$(kubectl -n register get deployment register -o json 2>/dev/null | \
        jq -r '.spec.template.spec.containers[0].env[]? |
               select(.name == "SPICEDB_TOKEN") |
               "\(.valueFrom.secretKeyRef.name)/\(.valueFrom.secretKeyRef.key)"')
    [ "$ref" = "spicedb-preshared-key-register/spicedb-preshared-key" ]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 3: Live reachability through the ambient mesh (probe pod)
# ══════════════════════════════════════════════════════════════════════════════

@test "3.1 probe pod completed (PSS admission + NetworkPolicy path healthy)" {
    local phase
    phase=$(cat "${PROBE_LOG}.phase" 2>/dev/null || echo "")
    if [ "$phase" != "Succeeded" ]; then
        echo "probe pod phase: '${phase}' — logs:" >&2
        cat "$PROBE_LOG" >&2 || true
        false
    fi
}

@test "3.2 SpiceDB HTTP gateway reachable from register with valid key" {
    local status
    status=$(probe_status "$PROBE_LOG")
    # 200 = schema present; 404 (gRPC code 5, "no schema has been defined")
    # also proves reachability + auth on an empty datastore. curl exit 28
    # (timeout, empty log) would mean HBONE 15008 is blocked again; exit 56
    # (reset) would mean default-deny caught the pod.
    if [ "$status" != "200" ] && [ "$status" != "404" ]; then
        echo "unexpected HTTP status '${status}' — body:" >&2
        probe_body "$PROBE_LOG" >&2 || true
        false
    fi
}

@test "3.3 schema is loaded (all schema.zed definitions present)" {
    local status body
    status=$(probe_status "$PROBE_LOG")
    [ "$status" = "200" ]
    body=$(probe_body "$PROBE_LOG")
    for def in user organization team workspace risk_tree; do
        if [[ "$body" != *"definition ${def}"* ]]; then
            echo "missing 'definition ${def}' in schema read-back" >&2
            false
        fi
    done
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 4: Negative — wrong preshared key must be rejected
# ══════════════════════════════════════════════════════════════════════════════

@test "4.1 wrong preshared key is rejected (401/403, never 200)" {
    local status
    status=$(probe_status "$BADKEY_LOG")
    # The pod must have reached SpiceDB (a network failure would be an empty
    # status) and been turned away at the auth layer.
    [ "$status" = "401" ] || [ "$status" = "403" ]
}
