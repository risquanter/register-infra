# ──────────────────────────────────────────────────────────────────────────────
# Shared register-app probe-pod helper for bats suites
# (load "helpers/register-probe").
#
# Runs one HTTP request against the register application Service from a pod in
# the register namespace, so the request traverses the waypoint and nothing
# else. Three properties make the result attributable to mesh policy:
#
#  - The target is the register Service, not the frontend Service. Service-
#    addressed traffic from a mesh pod is routed through the waypoint, and the
#    nginx SPA server is not on that path. A request sent to the ingress would
#    pass through nginx first, whose routing table also stops /admin, so an
#    ingress result cannot tell which component refused.
#  - The target is the Service name, not a pod IP. A pod IP skips the waypoint
#    and the policy with it.
#  - With `token` the pod fetches its own Keycloak token in-cluster, so a
#    refusal cannot be explained by a missing credential. The token is created
#    and used inside the pod and never reaches the test runner or the pod spec.
#
# Pod identity matches the real application's: label
# app.kubernetes.io/name=register (the NetworkPolicies select by it, and an
# unlabelled pod falls into namespace default-deny) and a restricted-PSS
# security context (a bare pod is rejected by the namespace's PSS labels
# otherwise).
#
# Log contract: first line is the HTTP status code, remaining lines the
# response body. The single line TOKEN_FAILED replaces both when `token` was
# requested and the Keycloak exchange did not return one — callers skip on it
# rather than reading an unauthenticated result as an authenticated one.
#
# API:
#   register_probe <pod> <method> <path> <out> [token]
#       Synchronous: create the pod, wait for it, write the log to <out>,
#       delete the pod. Returns 0 iff the pod reached Succeeded.
#   register_probe_status <out>     first line of a collected log
#   register_probe_body   <out>     everything after the first line
#   register_probe_delete <pod>...  best-effort cleanup
# ──────────────────────────────────────────────────────────────────────────────

REGISTER_URL="${REGISTER_URL:-http://register.register.svc.cluster.local:8090}"
KEYCLOAK_TOKEN_URL="${KEYCLOAK_TOKEN_URL:-http://keycloak.infra.svc.cluster.local/realms/register/protocol/openid-connect/token}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-register-web}"
# Demo realm fixtures, already carried by the other suites in this repo — not
# a credential with any standing outside a test realm.
KEYCLOAK_TEST_USER="${KEYCLOAK_TEST_USER:-demo-editor}"
KEYCLOAK_TEST_PASSWORD="${KEYCLOAK_TEST_PASSWORD:-editor-demo-2026}"

register_probe_apply() {
    local pod="$1" method="$2" path="$3" want_token="${4:-}"

    local token_step="TOKEN=''"
    local auth_arg=""
    if [ "$want_token" = "token" ]; then
        # The response is read with sed because the curl image carries no jq.
        token_step='TOKEN=$(curl -sS --max-time 15 \
            -d "grant_type=password" \
            -d "client_id=${KC_CLIENT}" \
            -d "username=${KC_USER}" \
            -d "password=${KC_PASSWORD}" \
            "${KC_URL}" \
          | sed -n "s/.*\"access_token\":\"\([^\"]*\)\".*/\1/p")
          if [ -z "${TOKEN}" ]; then echo TOKEN_FAILED; exit 0; fi'
        auth_arg='-H "Authorization: Bearer ${TOKEN}"'
    fi

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
      # Pinned: curl 8.21.0 (digest below) — the same digest the SpiceDB probe
      # helper already runs, so this adds no new external artifact.
      # Cooldown elapsed: released 2026-06-24 → pinned 2026-07-15 (21 days, T2 minor)
      # Approved: ADR-INFRA-012. Reviewed: 2026-07-15
      image: curlimages/curl@sha256:7c12af72ceb38b7432ab85e1a265cff6ae58e06f95539d539b654f2cfa64bb13
      env:
        - name: KC_URL
          value: "${KEYCLOAK_TOKEN_URL}"
        - name: KC_CLIENT
          value: "${KEYCLOAK_CLIENT_ID}"
        - name: KC_USER
          value: "${KEYCLOAK_TEST_USER}"
        - name: KC_PASSWORD
          value: "${KEYCLOAK_TEST_PASSWORD}"
      command: ["/bin/sh", "-c"]
      args:
        - |
          ${token_step}
          curl -sS -o /tmp/body -w '%{http_code}\n' --max-time 15 \\
            -X ${method} ${auth_arg} \\
            "${REGISTER_URL}${path}"
          cat /tmp/body
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

register_probe_collect() {
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

register_probe_delete() {
    kubectl -n register delete pod "$@" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

register_probe() {
    local pod="$1" method="$2" path="$3" out="$4" want_token="${5:-}" rc=0
    register_probe_apply "$pod" "$method" "$path" "$want_token" || true
    register_probe_collect "$pod" "$out" || rc=1
    register_probe_delete "$pod"
    [ "$rc" -eq 0 ]
}

register_probe_status() { head -n1 "$1"; }
register_probe_body()   { tail -n +2 "$1"; }
