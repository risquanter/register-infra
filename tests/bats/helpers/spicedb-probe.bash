# ──────────────────────────────────────────────────────────────────────────────
# Shared SpiceDB probe-pod helper for bats suites (load "helpers/spicedb-probe").
#
# Runs one authenticated POST against the SpiceDB HTTP gateway from a pod in
# the register namespace that is faithful to the real register app's identity:
#  - label app.kubernetes.io/name=register (NetworkPolicies select by it;
#    unlabeled pods fall into default-deny)
#  - restricted-PSS security context (bare pods are rejected by PSS otherwise)
#  - preshared key injected via secretKeyRef — it never materializes in the
#    test runner's environment or output
#
# Log contract: first line is the HTTP status code, remaining lines the
# response body. Collect additionally writes "<out>.phase" with the pod phase.
#
# API:
#   spicedb_probe_apply   <pod> <path> <json-body> [auth-value]
#       (Re)create the probe pod and let it run asynchronously. auth-value is
#       the Bearer value as seen by the POD's shell; default is the literal
#       ${SPICEDB_KEY} (the secretKeyRef env var). Pass another literal to
#       test rejection of a wrong key.
#   spicedb_probe_collect <pod> <out>
#       Wait for Succeeded/Failed (60s), dump logs to <out> and the phase to
#       <out>.phase. Returns 0 iff Succeeded. Does not delete the pod.
#   spicedb_probe_delete  <pod>...
#       Best-effort cleanup.
#   spicedb_api_pod       <pod> <path> <json-body> <out> [auth-value]
#       Synchronous one-shot: apply + collect + delete. Returns 0 iff the pod
#       Succeeded AND the HTTP status is 200.
#
# JSON bodies are passed to the pod via an env var quoted with single quotes
# in the manifest — they must not contain single quotes (canonical JSON with
# double-quoted strings is fine).
# ──────────────────────────────────────────────────────────────────────────────

SPICEDB_URL="${SPICEDB_URL:-http://spicedb.infra.svc.cluster.local:8080}"

spicedb_probe_apply() {
    local pod="$1" path="$2" body="$3" auth="${4:-\${SPICEDB_KEY}}"
    kubectl -n register delete pod "$pod" \
        --ignore-not-found --wait=true >/dev/null 2>&1 || true
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: register
  labels:
    app.kubernetes.io/name: register
spec:
  restartPolicy: Never
  # The probe never calls the Kubernetes API — no token in the container.
  automountServiceAccountToken: false
  containers:
    - name: curl
      # Vendor: curl project (official image org) — https://hub.docker.com/r/curlimages/curl
      # Security disclosure: https://curl.se/docs/security.html
      # Pinned: curl 8.21.0 (digest below; a mutable :latest tag would let a
      # compromised upstream push run with the SpiceDB key in this pod)
      # Cooldown elapsed: released 2026-06-24 → pinned 2026-07-15 (21 days, T2 minor)
      # Approved: ADR-INFRA-012. Reviewed: 2026-07-15
      image: curlimages/curl@sha256:7c12af72ceb38b7432ab85e1a265cff6ae58e06f95539d539b654f2cfa64bb13
      env:
        - name: SPICEDB_KEY
          valueFrom:
            secretKeyRef:
              name: spicedb-preshared-key-register
              key: spicedb-preshared-key
        - name: BODY
          value: '${body}'
      command: ["/bin/sh", "-c"]
      args:
        - >-
          curl -sS -o /tmp/body -w '%{http_code}\n' --max-time 15
          -X POST
          -H "Authorization: Bearer ${auth}"
          -H "Content-Type: application/json"
          -d "\${BODY}"
          ${SPICEDB_URL}${path}
          && cat /tmp/body
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: RuntimeDefault
EOF
}

spicedb_probe_collect() {
    local pod="$1" out="$2" phase="" i
    for i in $(seq 1 30); do
        phase=$(kubectl -n register get pod "$pod" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        case "$phase" in Succeeded|Failed) break ;; esac
        sleep 2
    done
    kubectl -n register logs "$pod" > "$out" 2>/dev/null || true
    echo "$phase" > "${out}.phase"
    [ "$phase" = "Succeeded" ]
}

spicedb_probe_delete() {
    kubectl -n register delete pod "$@" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

spicedb_api_pod() {
    local pod="$1" path="$2" body="$3" out="$4" rc=0
    spicedb_probe_apply "$pod" "$path" "$body" "${5:-}" || true
    spicedb_probe_collect "$pod" "$out" || rc=1
    spicedb_probe_delete "$pod"
    [ "$rc" -eq 0 ] && [ "$(head -n1 "$out")" = "200" ]
}
