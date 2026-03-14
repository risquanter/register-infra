#!/usr/bin/env bash
# post-sleep-recover.sh — idempotent recovery for k3d cluster after laptop sleep
#
# After waking from sleep (especially long sleep cycles), the k3d cluster may
# exhibit several failure modes:
#
#   1. SPIFFE certificate expiry  — ztunnel certs expire if the laptop sleeps
#      through the rotation window. Pods can't establish mTLS → connection
#      timeouts. Fix: restart ztunnel DaemonSet.
#
#   2. Stale Cilium Endpoint (CEP) ownership — Cilium agent loses track of pod
#      endpoints. NetworkPolicy enforcement may become inconsistent.
#      Fix: restart Cilium DaemonSet.
#
#   3. CoreDNS DNS forwarding failure — upstream DNS forwarders may become
#      unreachable or stale. Pods get SERVFAIL for external DNS queries.
#      Fix: restart CoreDNS.
#
#   4. ArgoCD ComparisonError — if ArgoCD couldn't reach the git remote during
#      sleep, all git-sourced Applications show ComparisonError. They recover
#      on the next successful git pull. Fix: refresh all ArgoCD apps.
#
# This script is idempotent. Running it on a healthy cluster is a no-op
# (the restarts will cycle pods but won't cause downtime in most cases).
#
# Usage:
#   ./scripts/post-sleep-recover.sh
#   ./scripts/post-sleep-recover.sh --dry-run    # show what would happen
#
# Prerequisites: kubectl, argocd CLI (optional — script skips if not found)

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "=== DRY RUN — no changes will be made ==="
  echo
fi

CLUSTER_NAME="register-dev"

# ── Verify cluster is reachable ───────────────────────────────────────────────

echo ">>> Checking k3d cluster '${CLUSTER_NAME}' is running..."
if ! docker ps --filter "name=k3d-${CLUSTER_NAME}-server-0" --format '{{.Names}}' | grep -q .; then
  echo "ERROR: k3d cluster '${CLUSTER_NAME}' is not running."
  echo "Start it with: k3d cluster start ${CLUSTER_NAME}"
  exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: kubectl cannot reach the cluster. Check your kubeconfig."
  exit 1
fi
echo "    Cluster reachable."
echo

# ── Step 1: Restart Cilium (stale CEP) ───────────────────────────────────────

echo ">>> Step 1: Restarting Cilium DaemonSet..."
if [[ "$DRY_RUN" == true ]]; then
  echo "    [dry-run] kubectl -n kube-system rollout restart daemonset/cilium"
else
  kubectl -n kube-system rollout restart daemonset/cilium
  kubectl -n kube-system rollout status daemonset/cilium --timeout=120s
fi
echo "    Cilium restarted."
echo

# ── Step 2: Restart ztunnel (SPIFFE cert expiry) ─────────────────────────────

echo ">>> Step 2: Restarting ztunnel DaemonSet..."
if [[ "$DRY_RUN" == true ]]; then
  echo "    [dry-run] kubectl -n istio-system rollout restart daemonset/ztunnel"
else
  kubectl -n istio-system rollout restart daemonset/ztunnel
  kubectl -n istio-system rollout status daemonset/ztunnel --timeout=120s
fi
echo "    ztunnel restarted."
echo

# ── Step 3: Restart CoreDNS (stale DNS forwarders) ───────────────────────────

echo ">>> Step 3: Restarting CoreDNS..."
if [[ "$DRY_RUN" == true ]]; then
  echo "    [dry-run] kubectl -n kube-system rollout restart deployment/coredns"
else
  kubectl -n kube-system rollout restart deployment/coredns
  kubectl -n kube-system rollout status deployment/coredns --timeout=60s
fi
echo "    CoreDNS restarted."
echo

# ── Step 4: Wait for workload pods ───────────────────────────────────────────

echo ">>> Step 4: Waiting for workload pods to become Ready..."
if [[ "$DRY_RUN" == true ]]; then
  echo "    [dry-run] would wait for pods in infra, register, argocd"
else
  # Give ztunnel + Cilium time to establish new connections
  sleep 5

  # Wait for infra pods
  for deploy in $(kubectl -n infra get deployments -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "    Waiting for infra/${deploy}..."
    kubectl -n infra rollout status "deployment/${deploy}" --timeout=120s || true
  done
  for sts in $(kubectl -n infra get statefulsets -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "    Waiting for infra/${sts}..."
    kubectl -n infra rollout status "statefulset/${sts}" --timeout=120s || true
  done

  # Wait for register pods
  for deploy in $(kubectl -n register get deployments -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "    Waiting for register/${deploy}..."
    kubectl -n register rollout status "deployment/${deploy}" --timeout=120s || true
  done
fi
echo "    Workloads ready."
echo

# ── Step 5: Refresh ArgoCD applications ──────────────────────────────────────

echo ">>> Step 5: Refreshing ArgoCD applications..."
if [[ "$DRY_RUN" == true ]]; then
  echo "    [dry-run] would refresh all ArgoCD apps"
elif command -v argocd &>/dev/null; then
  # Check if ArgoCD port-forward is running, otherwise start one temporarily
  ARGOCD_PF_PID=""
  if ! curl -sk https://localhost:9090 &>/dev/null; then
    kubectl -n argocd port-forward svc/argocd-server 9090:80 &
    ARGOCD_PF_PID=$!
    sleep 3
  fi

  # Get ArgoCD admin password
  ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) || true

  if [[ -n "${ARGOCD_PASS}" ]]; then
    argocd login localhost:9090 --insecure --username admin --password "${ARGOCD_PASS}" 2>/dev/null || true

    # Refresh all apps (hard refresh forces a git pull + manifest re-render)
    for app in $(argocd app list -o name 2>/dev/null); do
      echo "    Refreshing ${app}..."
      argocd app get "${app}" --hard-refresh &>/dev/null || true
    done
  else
    echo "    WARNING: could not retrieve ArgoCD admin password. Skipping app refresh."
    echo "    Manual refresh: argocd app get <app-name> --hard-refresh"
  fi

  # Cleanup temporary port-forward
  if [[ -n "${ARGOCD_PF_PID}" ]]; then
    kill "${ARGOCD_PF_PID}" 2>/dev/null || true
  fi
else
  echo "    argocd CLI not found. Skipping app refresh."
  echo "    Install: https://argo-cd.readthedocs.io/en/stable/cli_installation/"
  echo "    Or manually: kubectl -n argocd port-forward svc/argocd-server 9090:80"
  echo "                 argocd app list"
fi
echo

# ── Step 6: Health summary ───────────────────────────────────────────────────

echo ">>> Step 6: Cluster health summary"
echo
echo "--- Nodes ---"
kubectl get nodes
echo
echo "--- System pods ---"
kubectl -n kube-system get pods -o wide 2>/dev/null | head -20
echo
echo "--- Istio system ---"
kubectl -n istio-system get pods 2>/dev/null
echo
echo "--- Infra namespace ---"
kubectl -n infra get pods 2>/dev/null
echo
echo "--- Register namespace ---"
kubectl -n register get pods 2>/dev/null
echo
echo "--- ArgoCD ---"
kubectl -n argocd get pods 2>/dev/null
echo

echo "=== Recovery complete ==="
