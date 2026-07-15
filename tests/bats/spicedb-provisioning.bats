#!/usr/bin/env bats
# ──────────────────────────────────────────────────────────────────────────────
# Regression tests: K.6 authorization-graph provisioning job (Layer 2, Step 3)
#
# Verifies scripts/spicedb-provision.sh + its local launcher:
#  - Offline     config flattening: exact tuple output, fail-closed validation
#                (unknown users, out-of-scope relations, malformed ids)
#  - Live        bidirectional reconcile against the cluster: idempotence,
#                orphan deletion + WARN + strict-drift exit code, and the
#                B-K6-4 guarantee that owner_user tuples survive a run
#
# Canary tuples are written through a register-labeled probe pod with the
# preshared key injected via secretKeyRef (shared helper, also used by
# spicedb.bats) — the key never materializes in the runner's env or output.
# The provisioning runs themselves go through the local launcher, which holds
# the key only inside its own process.
#
# THREAT-CATALOG: Layer 2 (instance authorization) — privilege creep detection
#
# Prerequisites: kubectl, jq, yq configured against a live cluster;
# spicedb-credentials (infra) + spicedb-preshared-key-register (register)
# secrets applied. Live tests reconcile against the REAL repo config
# (infra/spicedb/relationships.yaml) — the git-authoritative state — so they
# never destroy intended tuples; injected canaries are drift by definition.
#
# Run:   bats tests/bats/spicedb-provisioning.bats
# ──────────────────────────────────────────────────────────────────────────────

# Probe-pod mechanics (spicedb_api_pod: secretKeyRef key injection,
# PSS-restricted) live in the shared helper: tests/bats/helpers/spicedb-probe.bash.
load "helpers/spicedb-probe"

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
PROVISION="${REPO_ROOT}/scripts/spicedb-provision.sh"
LAUNCHER="${REPO_ROOT}/scripts/spicedb-provision-local.sh"
CONFIG="${REPO_ROOT}/infra/spicedb/relationships.yaml"
LOCAL_PORT=18099

# Canary identifiers — never present in the repo config.
DRIFT_TUPLE_BODY='{"updates":[{"operation":"OPERATION_TOUCH","relationship":{"resource":{"objectType":"team","objectId":"bats-k6-canary"},"relation":"viewer","subject":{"object":{"objectType":"user","objectId":"bats-k6-sub"}}}}]}'
OWNER_TUPLE_BODY='{"updates":[{"operation":"OPERATION_TOUCH","relationship":{"resource":{"objectType":"workspace","objectId":"bats-k6-ws"},"relation":"owner_user","subject":{"object":{"objectType":"user","objectId":"bats-k6-sub"}}}}]}'
OWNER_READ_BODY='{"consistency":{"fullyConsistent":true},"relationshipFilter":{"resourceType":"workspace","optionalResourceId":"bats-k6-ws","optionalRelation":"owner_user"}}'
OWNER_DELETE_BODY='{"updates":[{"operation":"OPERATION_DELETE","relationship":{"resource":{"objectType":"workspace","objectId":"bats-k6-ws"},"relation":"owner_user","subject":{"object":{"objectType":"user","objectId":"bats-k6-sub"}}}}]}'

# run_provision [env-assignments...] — launcher with the repo config; captures
# combined output in $RUN_LOG and exit code in $RUN_EXIT.
run_provision() {
    RUN_LOG="${BATS_TEST_TMPDIR}/provision.log"
    RUN_EXIT=0
    env "$@" SPICEDB_LOCAL_PORT="$LOCAL_PORT" \
        "$LAUNCHER" > "$RUN_LOG" 2>&1 || RUN_EXIT=$?
}

setup_file() {
    export SKIP_LIVE=""
    kubectl get ns register >/dev/null 2>&1 || export SKIP_LIVE=1
}

teardown_file() {
    # Best-effort: remove the owner canary tuple (drift canaries are deleted
    # by the job itself as part of the tests).
    [ -n "${SKIP_LIVE:-}" ] && return 0
    spicedb_api_pod "bats-k6-cleanup" "/v1/relationships/write" \
        "$OWNER_DELETE_BODY" "${BATS_FILE_TMPDIR}/cleanup.log" || true
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 1: Config flattening — offline, fail-closed validation
# ══════════════════════════════════════════════════════════════════════════════

@test "1.1 repo config exists and flattens cleanly" {
    [ -f "$CONFIG" ]
    run "$PROVISION" --flatten "$CONFIG"
    [ "$status" -eq 0 ]
}

@test "1.2 provisioning scripts are executable and pass bash -n" {
    [ -x "$PROVISION" ]
    [ -x "$LAUNCHER" ]
    bash -n "$PROVISION"
    bash -n "$LAUNCHER"
}

@test "1.3 fixture config flattens to the exact expected tuple set" {
    cat > "${BATS_TEST_TMPDIR}/fixture.yaml" <<'YAML'
users:
  alice: "aaaa-1111"
  bob: "bbbb-2222"
organizations:
  acme:
    members: [alice]
    teams:
      platform:
        admins: [alice]
        editors: [bob]
        analysts: [bob]
        viewers: [bob]
workspaces:
  ws-demo:
    editors: [alice]
    analysts: [bob]
    viewers: [bob]
YAML
    cat > "${BATS_TEST_TMPDIR}/expected" <<'TUPLES'
organization:acme#org_member@user:aaaa-1111
team:platform#analyst@user:bbbb-2222
team:platform#editor@user:bbbb-2222
team:platform#team_admin@user:aaaa-1111
team:platform#viewer@user:bbbb-2222
workspace:ws-demo#analyst@user:bbbb-2222
workspace:ws-demo#editor@user:aaaa-1111
workspace:ws-demo#viewer@user:bbbb-2222
TUPLES
    "$PROVISION" --flatten "${BATS_TEST_TMPDIR}/fixture.yaml" \
        > "${BATS_TEST_TMPDIR}/actual"
    diff -u "${BATS_TEST_TMPDIR}/expected" "${BATS_TEST_TMPDIR}/actual"
}

@test "1.4 unknown user name is rejected (exit 2)" {
    printf 'users: {}\norganizations:\n  o1:\n    members: [ghost]\n' \
        > "${BATS_TEST_TMPDIR}/bad.yaml"
    run "$PROVISION" --flatten "${BATS_TEST_TMPDIR}/bad.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown user"* ]]
}

@test "1.5 out-of-scope relation in config is rejected (owner_user is inexpressible)" {
    printf 'users: {}\nworkspaces:\n  ws1:\n    owner_user: [x]\n' \
        > "${BATS_TEST_TMPDIR}/bad.yaml"
    run "$PROVISION" --flatten "${BATS_TEST_TMPDIR}/bad.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown key"* ]]
}

@test "1.6 object id with tuple-delimiter characters is rejected (exit 2)" {
    printf 'users:\n  eve: "has#hash"\norganizations:\n  o1:\n    members: [eve]\n' \
        > "${BATS_TEST_TMPDIR}/bad.yaml"
    run "$PROVISION" --flatten "${BATS_TEST_TMPDIR}/bad.yaml"
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid id"* ]]
}

# ══════════════════════════════════════════════════════════════════════════════
#  GROUP 2: Live bidirectional reconcile (launcher + probe pods)
# ══════════════════════════════════════════════════════════════════════════════

@test "2.1 reconcile converges and an immediate re-run is a no-op (idempotence)" {
    [ -n "${SKIP_LIVE:-}" ] && skip "no cluster reachable"
    run_provision            # first run may reconcile leftover drift
    run_provision            # second run must be a clean no-op
    if [ "$RUN_EXIT" -ne 0 ]; then
        cat "$RUN_LOG" >&2
        false
    fi
    grep -q "converged — no changes" "$RUN_LOG"
    cp "$RUN_LOG" "${BATS_FILE_TMPDIR}/clean-run.log"
}

@test "2.2 orphaned managed tuple: WARN, deleted, exit 1 under default strict drift" {
    [ -n "${SKIP_LIVE:-}" ] && skip "no cluster reachable"
    spicedb_api_pod "bats-k6-drift" "/v1/relationships/write" \
        "$DRIFT_TUPLE_BODY" "${BATS_TEST_TMPDIR}/seed.log"
    run_provision
    if [ "$RUN_EXIT" -ne 1 ]; then
        echo "expected exit 1 (strict drift), got ${RUN_EXIT}:" >&2
        cat "$RUN_LOG" >&2
        false
    fi
    grep -q "WARN: orphaned tuple.*team:bats-k6-canary#viewer@user:bats-k6-sub" "$RUN_LOG"
    # The orphan must be gone: a re-run is a clean converge again.
    run_provision
    [ "$RUN_EXIT" -eq 0 ]
    grep -q "converged — no changes" "$RUN_LOG"
}

@test "2.3 STRICT_DRIFT=false: orphan still deleted but run exits 0" {
    [ -n "${SKIP_LIVE:-}" ] && skip "no cluster reachable"
    spicedb_api_pod "bats-k6-drift2" "/v1/relationships/write" \
        "$DRIFT_TUPLE_BODY" "${BATS_TEST_TMPDIR}/seed.log"
    run_provision STRICT_DRIFT=false
    if [ "$RUN_EXIT" -ne 0 ]; then
        cat "$RUN_LOG" >&2
        false
    fi
    grep -q "WARN: orphaned tuple" "$RUN_LOG"
    grep -q "deleted 1" "$RUN_LOG"
}

@test "2.4 owner_user tuple survives a provisioning run (B-K6-4)" {
    [ -n "${SKIP_LIVE:-}" ] && skip "no cluster reachable"
    spicedb_api_pod "bats-k6-owner" "/v1/relationships/write" \
        "$OWNER_TUPLE_BODY" "${BATS_TEST_TMPDIR}/seed.log"
    # Exit 0 required: the owner tuple must be invisible to the diff, not
    # merely spared from deletion.
    run_provision
    if [ "$RUN_EXIT" -ne 0 ]; then
        echo "provisioning saw the owner tuple as drift:" >&2
        cat "$RUN_LOG" >&2
        false
    fi
    spicedb_api_pod "bats-k6-ownercheck" "/v1/relationships/read" \
        "$OWNER_READ_BODY" "${BATS_TEST_TMPDIR}/read.log"
    grep -q '"objectId":[[:space:]]*"bats-k6-ws"' "${BATS_TEST_TMPDIR}/read.log"
}

@test "2.5 provisioning output never leaks credentials" {
    [ -n "${SKIP_LIVE:-}" ] && skip "no cluster reachable"
    [ -f "${BATS_FILE_TMPDIR}/clean-run.log" ] || skip "2.1 did not record a run"
    ! grep -qi "bearer" "${BATS_FILE_TMPDIR}/clean-run.log"
    ! grep -qi "preshared" "${BATS_FILE_TMPDIR}/clean-run.log"
}
