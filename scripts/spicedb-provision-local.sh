#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Thin LOCAL DEV launcher for scripts/spicedb-provision.sh (K.6).
#
# The core script is environment-driven and will be reused verbatim by the
# Phase 4 in-cluster CI runner (Service DNS + mounted secret). This launcher
# only provides that same env contract for a developer workstation:
#   - temporary `kubectl port-forward` to svc/spicedb :8080 (torn down on exit)
#   - SPICEDB_TOKEN read from the cluster secret spicedb-credentials
#     (infra namespace) — held in this process's env only, never echoed
#
# Usage: spicedb-provision-local.sh [--dry-run] [config.yaml]
#        (all arguments are passed through to spicedb-provision.sh)
# Env:   SPICEDB_LOCAL_PORT — local forward port (default 18080)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NS="infra"
LOCAL_PORT="${SPICEDB_LOCAL_PORT:-18080}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found" >&2; exit 2; }

# Read the preshared key straight into the env var — no file, no echo.
SPICEDB_TOKEN="$(kubectl -n "$NS" get secret spicedb-credentials \
    -o jsonpath='{.data.preshared-key}' 2>/dev/null | base64 -d)"
[ -n "$SPICEDB_TOKEN" ] || {
    echo "ERROR: could not read preshared-key from secret ${NS}/spicedb-credentials" >&2
    echo "       (is the SOPS secret applied? see infra/secrets/spicedb.enc.yaml)" >&2
    exit 2
}
export SPICEDB_TOKEN

kubectl -n "$NS" port-forward svc/spicedb "${LOCAL_PORT}:8080" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

ready=""
for _ in $(seq 1 25); do
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${LOCAL_PORT}/healthz" 2>/dev/null; then
        ready=yes
        break
    fi
    kill -0 "$PF_PID" 2>/dev/null || break
    sleep 0.4
done
[ -n "$ready" ] || {
    echo "ERROR: port-forward to ${NS}/svc/spicedb on 127.0.0.1:${LOCAL_PORT} never became ready" >&2
    echo "       (port in use? try SPICEDB_LOCAL_PORT=<other> $0)" >&2
    exit 3
}

# No exec — the EXIT trap must survive to tear down the port-forward.
SPICEDB_URL="http://127.0.0.1:${LOCAL_PORT}" "${SCRIPT_DIR}/spicedb-provision.sh" "$@"
