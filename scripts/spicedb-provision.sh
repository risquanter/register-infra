#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# K.6 authorization-graph provisioning — bidirectional reconcile of SpiceDB
# team/org relationship tuples against the git-authoritative config
# (infra/spicedb/relationships.yaml).
#
#   to_write  = intended − actual   (missing grants, written with TOUCH)
#   to_delete = actual − intended   (orphans = privilege creep, logged at WARN,
#                                    deleted; run fails under STRICT_DRIFT=true)
#
# Scope — ONLY these (resource type, relation) pairs are ever read or written:
#   organization: org_member
#   team:         team_admin, editor, analyst, viewer
#   workspace:    editor, analyst, viewer
# workspace owner_user / owner_team are app-lifecycle-written (Wave 6,
# BootstrapProvisionerSpiceDB) and are structurally invisible to this job:
# the read filter never matches them and the config cannot express them
# (BATS B-K6-4 asserts they survive a run).
#
# Environment contract — identical for local dev and the Phase 4 in-cluster CI
# runner; CI-parity lives at this script level, not the execution level
# (design decision 2026-07-15, TODO.md Step 3). Local dev provides it via
# scripts/spicedb-provision-local.sh (port-forward + cluster secret); the
# Phase 4 runner provides it natively (Service DNS + mounted secret).
#
#   SPICEDB_URL     HTTP gateway base URL, e.g. http://127.0.0.1:18080
#   SPICEDB_TOKEN   preshared key — read from env only, never printed, passed
#                   to curl via a 0600 header file (not argv, not visible in ps)
#   STRICT_DRIFT    "true" (default): exit 1 when orphans were found;
#                   "false": warn and exit 0. Reconciliation happens either way.
#
# Usage: spicedb-provision.sh [--flatten|--dry-run] [config.yaml]
#   --flatten   print the intended tuple set from the config and exit
#               (pure transformation: no cluster access, no credentials needed)
#   --dry-run   compute and print the full diff, write nothing
#   config.yaml defaults to infra/spicedb/relationships.yaml (repo-relative)
#
# Exit codes: 0 converged (or non-strict drift), 1 strict drift, 2 usage/config
# error, 3 SpiceDB API/network error.
#
# Requires: bash, curl, jq, yq (mikefarah v4). SpiceDB's HTTP gRPC-gateway
# limits one WriteRelationships call to 1000 updates — far above the expected
# config size; revisit batching if the graph ever approaches that.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Managed (resource type, relation) pairs — THE scope boundary of this job.
MANAGED_PAIRS=(
    "organization org_member"
    "team team_admin"
    "team editor"
    "team analyst"
    "team viewer"
    "workspace editor"
    "workspace analyst"
    "workspace viewer"
)

usage() { grep '^# Usage' -A 5 "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

MODE="reconcile"
CONFIG=""
for arg in "$@"; do
    case "$arg" in
        --flatten) MODE="flatten" ;;
        --dry-run) MODE="dry-run" ;;
        -h|--help) usage ;;
        -*) echo "ERROR: unknown flag: $arg" >&2; usage ;;
        *) CONFIG="$arg" ;;
    esac
done
if [ -z "$CONFIG" ]; then
    CONFIG="$(cd "$(dirname "$0")/.." && pwd)/infra/spicedb/relationships.yaml"
fi
[ -f "$CONFIG" ] || { echo "ERROR: config not found: $CONFIG" >&2; exit 2; }
for tool in curl jq yq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found" >&2; exit 2; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# ── Flatten: config YAML → canonical tuple lines "type:id#relation@user:sub" ──
# Validates structure (unknown keys / unknown users / bad ids ⇒ exit 2) and
# can only ever emit the managed relations above — owner_user/owner_team are
# inexpressible by construction.
FLATTEN_JQ='
. as $cfg |
def okid($ctx):
    if type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9/_-]*$") then .
    else error("invalid id \(tojson) under \($ctx) (allowed: [a-zA-Z0-9/_-], no leading symbol)")
    end;
def sub($n):
    (($cfg.users // {})[$n] // error("unknown user \"\($n)\" — not in users: map"))
    | okid("users.\($n)");
def checkkeys($ctx; $allowed):
    (((. // {}) | keys) - $allowed) as $extra |
    if ($extra | length) > 0
    then error("unknown key(s) [\($extra | join(", "))] under \($ctx)")
    else (. // {}) end;
($cfg | checkkeys("top level"; ["users", "organizations", "workspaces"])) as $top |
[
    ((($cfg.organizations // {}) | to_entries[]) as $o |
        ($o.key | okid("organizations")) as $oid |
        ($o.value | checkkeys("organizations.\($oid)"; ["members", "teams"])) as $ov |
        (
            (($ov.members // [])[] | "organization:\($oid)#org_member@user:\(sub(.))"),
            ((($ov.teams // {}) | to_entries[]) as $t |
                ($t.key | okid("organizations.\($oid).teams")) as $tid |
                ($t.value | checkkeys("teams.\($tid)";
                    ["admins", "editors", "analysts", "viewers"])) as $tv |
                (
                    (($tv.admins   // [])[] | "team:\($tid)#team_admin@user:\(sub(.))"),
                    (($tv.editors  // [])[] | "team:\($tid)#editor@user:\(sub(.))"),
                    (($tv.analysts // [])[] | "team:\($tid)#analyst@user:\(sub(.))"),
                    (($tv.viewers  // [])[] | "team:\($tid)#viewer@user:\(sub(.))")
                )
            )
        )
    ),
    ((($cfg.workspaces // {}) | to_entries[]) as $w |
        ($w.key | okid("workspaces")) as $wid |
        ($w.value | checkkeys("workspaces.\($wid)";
            ["editors", "analysts", "viewers"])) as $wv |
        (
            (($wv.editors  // [])[] | "workspace:\($wid)#editor@user:\(sub(.))"),
            (($wv.analysts // [])[] | "workspace:\($wid)#analyst@user:\(sub(.))"),
            (($wv.viewers  // [])[] | "workspace:\($wid)#viewer@user:\(sub(.))")
        )
    )
] | unique | .[]
'

flatten_config() {
    yq -o=json '.' "$CONFIG" > "$WORK/config.json" \
        || { echo "ERROR: config is not valid YAML: $CONFIG" >&2; exit 2; }
    jq -r "$FLATTEN_JQ" "$WORK/config.json" 2> "$WORK/flatten.err" \
        || { echo "ERROR: invalid config: $(cat "$WORK/flatten.err")" >&2; exit 2; }
}

flatten_config | sort > "$WORK/intended"

if [ "$MODE" = "flatten" ]; then
    cat "$WORK/intended"
    exit 0
fi

# ── Live modes: env contract + curl auth via 0600 header file ────────────────
[ -n "${SPICEDB_URL:-}" ]   || { echo "ERROR: SPICEDB_URL not set" >&2; exit 2; }
[ -n "${SPICEDB_TOKEN:-}" ] || { echo "ERROR: SPICEDB_TOKEN not set" >&2; exit 2; }
STRICT_DRIFT="${STRICT_DRIFT:-true}"

HDR="$WORK/hdr"
touch "$HDR" && chmod 600 "$HDR"
printf 'Authorization: Bearer %s\n' "$SPICEDB_TOKEN" > "$HDR"

# api <path> <request-body-file> <response-file>: POST, fail (exit 3) on ≠200.
api() {
    local status
    status=$(curl -sS -o "$3" -w '%{http_code}' --max-time 30 \
        -X POST -H "Content-Type: application/json" -H @"$HDR" \
        --data-binary @"$2" "${SPICEDB_URL}$1") \
        || { echo "ERROR: cannot reach SpiceDB at ${SPICEDB_URL}$1" >&2; exit 3; }
    if [ "$status" != "200" ]; then
        echo "ERROR: ${1} returned HTTP ${status}: $(head -c 500 "$3")" >&2
        exit 3
    fi
}

# ── Read actual state: one filtered read per managed pair ────────────────────
# /v1/relationships/read streams NDJSON: {"result":{"relationship":{...}}} per
# tuple, or an {"error":...} line mid-stream.
: > "$WORK/actual.raw"
for pair in "${MANAGED_PAIRS[@]}"; do
    rtype="${pair%% *}"; rel="${pair##* }"
    jq -n --arg t "$rtype" --arg r "$rel" '{
        consistency: {fullyConsistent: true},
        relationshipFilter: {resourceType: $t, optionalRelation: $r}
    }' > "$WORK/read.req"
    api "/v1/relationships/read" "$WORK/read.req" "$WORK/read.resp"
    jq -r '
        if .error then error("read stream error: \(.error | tojson)") else . end |
        .result.relationship |
        "\(.resource.objectType):\(.resource.objectId)#\(.relation)@\(.subject.object.objectType):\(.subject.object.objectId)"
    ' "$WORK/read.resp" >> "$WORK/actual.raw" \
        || { echo "ERROR: failed to parse read response for ${rtype}#${rel}" >&2; exit 3; }
done
sort -u "$WORK/actual.raw" > "$WORK/actual"

# ── Bidirectional diff ────────────────────────────────────────────────────────
comm -23 "$WORK/intended" "$WORK/actual" > "$WORK/to_write"
comm -13 "$WORK/intended" "$WORK/actual" > "$WORK/to_delete"
n_write=$(grep -c . "$WORK/to_write" || true)
n_delete=$(grep -c . "$WORK/to_delete" || true)
n_intended=$(grep -c . "$WORK/intended" || true)

echo "spicedb-provision: intended=${n_intended} actual=$(grep -c . "$WORK/actual" || true) to_write=${n_write} to_delete=${n_delete}"
while IFS= read -r t; do echo "  + write:  $t"; done < "$WORK/to_write"
while IFS= read -r t; do
    echo "WARN: orphaned tuple (privilege creep, not in git config): $t" >&2
    echo "  - delete: $t"
done < "$WORK/to_delete"

drift_exit=0
if [ "$n_delete" -gt 0 ] && [ "$STRICT_DRIFT" = "true" ]; then
    drift_exit=1
fi

if [ "$MODE" = "dry-run" ]; then
    echo "spicedb-provision: dry-run — nothing written"
    [ "$drift_exit" -eq 1 ] && echo "spicedb-provision: FAILING (drift found, STRICT_DRIFT=true)" >&2
    exit "$drift_exit"
fi

# ── Apply: single atomic WriteRelationships call (TOUCH + DELETE) ─────────────
if [ "$n_write" -eq 0 ] && [ "$n_delete" -eq 0 ]; then
    echo "spicedb-provision: converged — no changes"
    exit 0
fi

TUPLE_JQ='
[inputs | select(length > 0) |
 capture("^(?<rt>[^:]+):(?<ri>[^#]+)#(?<rel>[^@]+)@(?<st>[^:]+):(?<si>.+)$") |
 {operation: $op,
  relationship: {
      resource: {objectType: .rt, objectId: .ri},
      relation: .rel,
      subject: {object: {objectType: .st, objectId: .si}}}}]
'
jq -Rn --arg op "OPERATION_TOUCH"  "$TUPLE_JQ" < "$WORK/to_write"  > "$WORK/upd_write.json"
jq -Rn --arg op "OPERATION_DELETE" "$TUPLE_JQ" < "$WORK/to_delete" > "$WORK/upd_delete.json"
jq -s '{updates: add}' "$WORK/upd_write.json" "$WORK/upd_delete.json" > "$WORK/write.req"

api "/v1/relationships/write" "$WORK/write.req" "$WORK/write.resp"
jq -e '.writtenAt.token' "$WORK/write.resp" >/dev/null \
    || { echo "ERROR: write response missing writtenAt: $(head -c 500 "$WORK/write.resp")" >&2; exit 3; }

echo "spicedb-provision: reconciled (wrote ${n_write}, deleted ${n_delete})"
[ "$drift_exit" -eq 1 ] && echo "spicedb-provision: FAILING (drift found, STRICT_DRIFT=true)" >&2
exit "$drift_exit"
