---
name: infra-dev
description: "Dev workflow for the register-infra project. Use for: kubectl cluster inspection, helm lint/template/upgrade, ArgoCD sync and diff, SOPS encrypt/decrypt, bats/conftest test invocation, k3d cluster management, zed SpiceDB CLI, post-sleep recovery, image import, and common operational one-liners."
user-invokable: false
---

# Register Infra Dev Workflow

## Cluster State

```bash
# All ArgoCD applications — sync + health status
kubectl get applications -n argocd

# Pods across all workload namespaces
kubectl get pods -n register && kubectl get pods -n infra && kubectl get pods -n argocd

# Recent events (last 20, sorted)
kubectl get events -n register --sort-by=.lastTimestamp | tail -20
kubectl get events -n infra    --sort-by=.lastTimestamp | tail -20

# Resource usage
kubectl top pods -n register
kubectl top pods -n infra
```

---

## Post-Sleep Recovery

Run this after laptop suspend if pods are in CrashLoopBackOff or the waypoint is unhealthy:

```bash
./scripts/post-sleep-recover.sh
```

Check waypoint health after recovery:

```bash
kubectl -n register get pods -l gateway.istio.io/managed=istio.io-mesh-controller
kubectl -n register rollout status deployment/waypoint 2>/dev/null || true
```

---

## k3d Cluster

```bash
# List clusters
k3d cluster list

# Start/stop
k3d cluster start register-dev
k3d cluster stop register-dev

# Import a locally-built image (avoids registry push for dev)
k3d image import <image>:<tag> -c register-dev
# Examples:
k3d image import register-server:prod -c register-dev
k3d image import local/frontend:dev  -c register-dev
k3d image import irmin-prod:latest   -c register-dev
```

---

## Helm

```bash
# Lint a chart (catches YAML and template errors)
helm lint infra/helm/<chart>

# Render templates locally (no cluster connection)
helm template <release> infra/helm/<chart> --namespace <ns> | less

# Render with custom values
helm template opa infra/helm/opa --namespace register -f infra/helm/opa/values.yaml

# Diff against live cluster (requires helm-diff plugin)
helm diff upgrade <release> infra/helm/<chart> -n <ns>

# Upgrade (use ArgoCD in normal operation; this is for emergency manual apply)
helm upgrade --install <release> infra/helm/<chart> -n <ns> --atomic
```

---

## ArgoCD

```bash
# Login (default local port-forward)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
argocd login localhost:8080 --insecure --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

# Sync a single application
argocd app sync <app-name>

# Show diff (what ArgoCD would apply)
argocd app diff <app-name>

# Force refresh (re-read git)
argocd app get <app-name> --refresh

# List all apps with sync status
argocd app list
```

---

## SOPS

```bash
# Encrypt a new secret file (software age key)
PUBKEY=$(grep "^# public key:" ~/.config/sops/age/keys.txt | awk '{print $4}')
sops --encrypt --age "$PUBKEY" <plaintext>.yaml > infra/secrets/<name>.enc.yaml
rm <plaintext>.yaml   # never commit plaintext

# Decrypt for inspection (pipe to stdout, never write to disk)
sops --decrypt infra/secrets/<name>.enc.yaml

# Edit in-place (decrypts, opens $EDITOR, re-encrypts on save)
sops infra/secrets/<name>.enc.yaml

# Verify ArgoCD can decrypt (requires the age key Secret in argocd namespace)
kubectl -n argocd get secret sops-age -o jsonpath='{.data.keys\.txt}' | base64 -d | head -3
```

---

## OPA Unit Tests

```bash
# Run all OPA unit tests
opa test infra/helm/opa/policies/ tests/opa/ -v

# Run with coverage
opa test infra/helm/opa/policies/ tests/opa/ --coverage

# Evaluate a single rule against example input (debugging)
opa eval -d infra/helm/opa/policies/allow.rego \
  -i <input.json> "data.register.authz.allow"
```

---

## Conftest (Static Policy Checks)

```bash
# Run all conftest policies against all k8s manifests
conftest test infra/k8s/ --policy tests/conftest/

# Run against a specific directory
conftest test infra/k8s/istio/ --policy tests/conftest/

# Run against rendered Helm output
helm template opa infra/helm/opa | conftest test - --policy tests/conftest/

# Run static checks only (no cluster needed — use in CI or offline)
./tests/run-regression.sh --static-only
```

---

## Bats (Behavioural Tests — Requires Running Cluster)

```bash
# Run all bats suites
bats tests/bats/

# Run a single suite
bats tests/bats/header-security.bats
bats tests/bats/opa-authz.bats
bats tests/bats/mtls-enforcement.bats

# Run with TAP output
bats --tap tests/bats/

# Full regression (static + live)
./tests/run-regression.sh
```

Prerequisites: running cluster, waypoint healthy, Keycloak reachable.
Set `KEYCLOAK_TOKEN` env var for JWT-dependent tests:

```bash
export KEYCLOAK_TOKEN=$(curl -s -X POST \
  http://keycloak.infra.svc.cluster.local/realms/register/protocol/openid-connect/token \
  -d "grant_type=password&client_id=register-api&username=<user>&password=<pass>" \
  | jq -r .access_token)
```

---

## SpiceDB (`zed` CLI)

All `zed` commands require port-forward to the SpiceDB Service (HTTP REST on :8080):

```bash
# Port-forward (keep running in a separate terminal)
kubectl -n infra port-forward svc/spicedb 8080:8080 &

# Apply schema from register repo (DO NOT copy schema.zed here — ADR-INFRA-011)
zed schema write \
  --endpoint localhost:8080 \
  --token "$(sops --decrypt infra/secrets/spicedb.enc.yaml | yq .stringData.spicedb-preshared-key)" \
  < /path/to/register/infra/spicedb/schema.zed

# Read current schema
zed schema read \
  --endpoint localhost:8080 \
  --token "<preshared-key>"

# Write a test relationship
zed relationship create \
  --endpoint localhost:8080 --token "<preshared-key>" \
  "workspace:<workspaceId>#editor@user:<userId>"

# Check a permission
zed permission check \
  --endpoint localhost:8080 --token "<preshared-key>" \
  "workspace:<workspaceId>" design_write "user:<userId>"
```

---

## Common Debugging One-Liners

```bash
# Check Istio ambient enrollment status
kubectl get namespace register -o jsonpath='{.metadata.labels}' | jq

# Check ztunnel logs (ambient mTLS decisions)
kubectl -n istio-system logs -l app=ztunnel --tail=50 -f

# Check waypoint proxy logs (L7 policy decisions)
kubectl -n register logs -l gateway.istio.io/managed=istio.io-mesh-controller --tail=50 -f

# OPA decision logs
kubectl -n register logs -l app.kubernetes.io/name=opa --tail=50 -f

# ArgoCD sync full details
kubectl -n argocd describe application <app-name>

# Decode a SOPS secret value that ArgoCD has decrypted and applied
kubectl -n <ns> get secret <name> -o jsonpath='{.data.<key>}' | base64 -d

# Port-forward to any service for local testing
kubectl -n register port-forward svc/register  8090:8090 &
kubectl -n infra    port-forward svc/keycloak  8081:80   &
kubectl -n infra    port-forward svc/spicedb   8080:8080 &
kubectl -n argocd   port-forward svc/argocd-server 8443:443 &
```

---

## Istio / Ambient Diagnostics

```bash
# Check PeerAuthentication
kubectl get peerauthentication -A

# Check AuthorizationPolicy
kubectl get authorizationpolicy -n register

# Check RequestAuthentication
kubectl get requestauthentication -n register

# Verify waypoint is enrolled as Gateway
kubectl -n register get gateway

# Istio config dump (debug filter chain order on waypoint)
kubectl -n register exec -it \
  $(kubectl -n register get pod -l gateway.istio.io/managed=istio.io-mesh-controller -o name | head -1) \
  -- pilot-agent request GET config_dump | jq '.configs[].dynamic_listeners'

# Check NetworkPolicy
kubectl get networkpolicy -n register
kubectl get networkpolicy -n infra
```
