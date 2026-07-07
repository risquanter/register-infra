> **⚠️ ARCHIVED (2026-07-07) — not maintained.** This imperative manual `k3s`
> install is superseded by the two supported bootstrap paths:
> [LOCAL-K3D-BOOTSTRAP.md](../LOCAL-K3D-BOOTSTRAP.md) (local k3d) and
> [K3S-GITOPS-BOOTSTRAP.md](../K3S-GITOPS-BOOTSTRAP.md) (Terraform/Hetzner).
> Both share the identical GitOps layer. This doc is retained for reference
> only; its commands are not exercised by any pipeline and may have drifted.

# Phase K Manual Installation  (Linux, hardened)

This document is still command-first, but now includes explicit secure-by-default guidance.

- Scope: single-node `k3s` for local + realistic dev (scaled-down prod-like)
- Goal 1: quick enterprise-auth trial on localhost
- Goal 2: durable dev cluster with sane security defaults
- Principle: idempotent commands whenever possible (`apply`, `upgrade --install`, `--overwrite`)
- Constraint: no dedicated secret-manager service in this baseline

---

## Security posture used in this guide

1. **Least privilege** for credentials (especially GHCR token).
2. **No plaintext secrets on CLI history** (use `read -s`, files with `0600`, stdin pipes).
3. **Namespace scoping** for secrets and service accounts (no cluster-wide default patching).
4. **Defense in depth**: Pod Security labels, RBAC, network policies, secret encryption at rest.
5. **Security limitations** documented at the end.

---

## 0) Prerequisites (one-time)

### 0.1 Install base tools

```bash
# update package index
sudo apt update
# install foundational tools used by later steps
sudo apt install -y curl jq git openssl ca-certificates gnupg lsb-release
```

### 0.2 Install kubectl (pin version)

```bash
# choose kubectl matching your target k3s minor version (±1 minor skew)
K8S_VERSION="v1.35.1"

# download kubectl binary and matching sha256 checksum
curl -fsSLO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
curl -fsSLO "https://dl.k8s.io/${K8S_VERSION}/bin/linux/amd64/kubectl.sha256"

# verify integrity before installing
echo "$(cat kubectl.sha256) kubectl" | sha256sum --check

# install binary
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl
rm -f kubectl.sha256

# verify client
kubectl version --client
```

### 0.3 Install Helm

```bash
# install helm via official script (acceptable for local/dev bootstrap)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# verify install
helm version
```

### 0.4 Verify Docker

```bash
# ensure docker CLI and daemon are available
docker --version
docker info >/dev/null
```

---

## 1) Phase K.1 — k3s bootstrap (with hardening flags)

### 1.1 Install k3s with secret encryption enabled

```bash
# install k3s server with:
# - secrets encryption at rest enabled
# - kubeconfig mode 600 (owner-only)
# - traefik disabled (we use a separate ingress)
# - flannel disabled + network-policy controller disabled — Cilium replaces both (see §1.3a)
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server \
    --secrets-encryption \
    --write-kubeconfig-mode=600 \
    --disable traefik \
    --flannel-backend=none \
    --disable-network-policy" \
  sh -
```

> **Why disable flannel?** Flannel has no native `NetworkPolicy` enforcement. Cilium replaces it with full NetworkPolicy support + better eBPF integration with Istio ambient mode's ztunnel. The node will show `NotReady` until Cilium is installed in §1.3a — this is expected.

### 1.2 Verify secret encryption status

```bash
# verify secret encryption provider status
sudo k3s secrets-encrypt status
```

### 1.3 Configure kubeconfig for your user

```bash
# create user kube dir
mkdir -p ~/.kube

# copy admin kubeconfig
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$USER":"$USER" ~/.kube/config
chmod 600 ~/.kube/config

# local usability tweak
sed -i 's/127.0.0.1/localhost/g' ~/.kube/config

# verify cluster reachability
kubectl get nodes -o wide
```

### 1.3a Install Cilium (CNI — required before namespaces)

The node remains `NotReady` until a CNI is present. Install Cilium now.

```bash
# install Cilium CLI (pinned to latest stable)
CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -fsSLO "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"
curl -fsSLO "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz.sha256sum"
sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm -f cilium-linux-amd64.tar.gz cilium-linux-amd64.tar.gz.sha256sum

cilium version --client
```

```bash
# install Cilium into the cluster
# --set cni.exclusive=false is required: Istio ambient installs its own istio-cni DaemonSet
# alongside Cilium; without this flag Cilium marks itself as the sole CNI and istio-cni fails
# to register when Istio is installed later.
cilium install --version 1.17.0 \
  --set cni.exclusive=false

# wait for all Cilium components to be ready
cilium status --wait

# verify node is now Ready
kubectl get nodes -o wide
```

```bash
# run Cilium connectivity test (optional but recommended first time)
# Note: partial failures are expected at this stage — Istio ambient is not yet installed.
# Tests involving L7 policy or encrypted traffic paths are skipped/failed until §5.
# The || true prevents this from blocking the tutorial.
cilium connectivity test --test-concurrency 1 || true
```

### 1.4 Create base namespaces + baseline labels

```bash
# create namespaces idempotently
kubectl create namespace register --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

# enforce Pod Security admission labels (restricted baseline)
kubectl label ns register \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

kubectl label ns infra \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

# verify
kubectl get ns --show-labels | grep -E 'register|infra|observability'
```

#### Note on infra namespace mesh enrolment

The `infra` namespace (PostgreSQL, Keycloak) is enrolled in Istio ambient mesh
at §2.4. This makes `app → postgres` and `app → keycloak` traffic mTLS-encrypted
via ztunnel automatically with no changes to the Helm charts or application.

If liveness/readiness probes fail for postgres or keycloak after enrolment
(visible as `CrashLoopBackOff` or `Liveness probe failed` events), roll back by
removing the ambient label from the infra namespace:

```bash
# rollback: remove infra from the mesh (run after §2.4 if probes trip)
kubectl label namespace infra istio.io/dataplane-mode- --overwrite

# verify pods recover
kubectl -n infra get events --sort-by=.lastTimestamp | tail -20

# alternative: exclude specific ports from ztunnel interception instead of
# dis-enrolling the whole namespace (try this before full rollback)
kubectl -n infra patch statefulset register-postgres-postgresql \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/metadata/annotations","value":{"traffic.sidecar.istio.io/excludeInboundPorts":"5432"}}]'
```

### 1.5 Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true

kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s
```

### 1.6 (Optional) metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system rollout status deploy/metrics-server --timeout=180s
kubectl top nodes || true
```

---

## 2) Phase K.2 — Istio ambient + auth hardening

Istio is installed immediately after the cluster bootstrap so ztunnel is running before any workload pods are created. This ensures mesh interception applies from each pod's first packet. Both the `register` and `infra` namespaces are enrolled in the mesh (`meshEnroll: true`) with PeerAuthentication STRICT mTLS. Health probes are handled via CiliumNetworkPolicy (allowing `169.254.7.127/32`) and port-level PERMISSIVE PeerAuthentication.

### 2.1 Install Istio CLI

```bash
curl -L https://istio.io/downloadIstio | sh -
ISTIO_DIR=$(ls -d istio-*/ | head -n1)
export PATH="$PWD/${ISTIO_DIR}bin:$PATH"
istioctl version --remote=false
```

### 2.2 Install Kubernetes Gateway API CRDs

Istio waypoints require the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) CRDs. These are **not** included in a default k3s install and must be applied before `istioctl waypoint apply` — otherwise you get:

```
Error: missing Kubernetes Gateway CRDs need to be installed before applying a waypoint
```

```bash
# install Gateway API CRDs (standard channel — covers HTTPRoute, Gateway, GatewayClass etc.)
# version must be compatible with Istio 1.25: v1.2.x or later
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# verify CRDs are registered
kubectl get crd gateways.gateway.networking.k8s.io
kubectl get crd httproutes.gateway.networking.k8s.io
```

### 2.3 Install ambient profile

```bash
istioctl install -y --set profile=ambient
kubectl -n istio-system get pods
```

### 2.4 Enroll namespace + waypoint

```bash
# enroll register namespace — workload traffic becomes mTLS via ztunnel
kubectl label namespace register istio.io/dataplane-mode=ambient --overwrite

# enroll infra namespace — makes app→postgres and app→keycloak mTLS automatically.
# ztunnel intercepts transparently; no chart or application changes needed.
kubectl label namespace infra istio.io/dataplane-mode=ambient --overwrite

# TEST: verify postgres and keycloak pods remain healthy after enrolment
# (allow ~30s for ztunnel to reconcile, then check)
kubectl -n infra get pods
kubectl -n infra get events --sort-by=.lastTimestamp | tail -20

# If pods enter CrashLoopBackOff or probes fail, see rollback note in §1.4.

# install waypoint for L7 policy in the register namespace
istioctl waypoint apply -n register --enroll-namespace
kubectl -n register get gateway
```

### 2.5 Apply JWT + policy resources

These files live in the infra repo at `infra/k8s/istio/`. If you are running from the app repo directly, the equivalent manifests are in the same relative paths.

```bash
# from the root of register-infra
kubectl apply -f infra/k8s/istio/request-authentication.yaml
kubectl apply -f infra/k8s/istio/authorization-policy.yaml
kubectl apply -f infra/k8s/istio/envoy-filter-strip-headers.yaml
```

### 2.6 Mesh trust checks

```bash
# invalid JWT should fail before app logic
curl -i -H "Authorization: Bearer INVALID" https://<INGRESS>/w/<key>/risk-trees

# forged identity header must not grant access
curl -i -H "x-user-id: 00000000-0000-0000-0000-000000000001" https://<INGRESS>/w/<key>/risk-trees
```

Expected: invalid JWT `401`; forged identity rejected/ignored.

---

## 3) Phase K.3 — GHCR pull path (least privilege + no CLI secret leakage)

### 2.0 GitHub token requirements

- Prefer **fine-grained PAT** scoped only to the required package/repo.
- Minimum permission: read access for package pulls.
- Short expiry and regular rotation.
- Do not store token in shell startup files.

### 3.1 Read credentials securely (non-export, one-time shell vars)

```bash
# disable command echo for secret entry; do not export variables
read -r -p "GitHub username: " GHCR_USER
read -r -s -p "GHCR token (read-only): " GHCR_PAT; echo

# optional safety guard: ensure token is non-empty
test -n "$GHCR_PAT"
```

### 3.2 Create a dedicated runtime service account (do NOT patch default SA)

```bash
# create dedicated SA used by app pods
kubectl -n register create serviceaccount register-runtime \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3.3 Create namespace-scoped imagePullSecret idempotently

```bash
# create/update pull secret in register namespace only
kubectl -n register create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USER" \
  --docker-password="$GHCR_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3.4 Attach imagePullSecret to dedicated SA only

```bash
# idempotent patch: service account used by your deployment only
kubectl -n register patch serviceaccount register-runtime --type='merge' \
  -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'

# verify
kubectl -n register get sa register-runtime -o yaml | grep -A3 imagePullSecrets
```

### 3.5 Immediately remove local secret material

```bash
# clear in-memory vars from current shell
unset GHCR_PAT
unset GHCR_USER

# if docker login was used manually, ensure config file is owner-only
test -f ~/.docker/config.json && chmod 600 ~/.docker/config.json || true
```

> GitHub best practice for CI/CD: prefer GitHub Actions + OIDC/federated identity to avoid long-lived static secrets in pipelines.

---

## 4) Phase K.4 — PostgreSQL (hardened install pattern)

### 4.1 Create a local values file with strict permissions

```bash
# create temp values file with owner-only permissions
umask 077
cat > /tmp/register-postgres-values.yaml <<'YAML'
auth:
  postgresPassword: "REPLACE_ME_STRONG_POSTGRES_PASSWORD"
primary:
  persistence:
    enabled: true
    size: 10Gi
  containerSecurityContext:
    enabled: true
    runAsNonRoot: true
YAML
```

### 4.2 Install/upgrade chart idempotently

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
helm repo update

helm upgrade --install register-postgres bitnami/postgresql \
  --namespace infra \
  --create-namespace \
  -f /tmp/register-postgres-values.yaml

kubectl -n infra rollout status statefulset/register-postgres-postgresql --timeout=300s
kubectl -n infra get pvc
```

### 4.3 Create databases idempotently

```bash
# create DBs only if missing
kubectl -n infra exec register-postgres-postgresql-0 -- bash -lc '
  psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '\''register_app'\''" | grep -q 1 || psql -U postgres -c "CREATE DATABASE register_app";
  psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '\''keycloak'\''" | grep -q 1 || psql -U postgres -c "CREATE DATABASE keycloak";
'
```

### 4.4 Validate connectivity

```bash
kubectl -n infra exec register-postgres-postgresql-0 -- bash -lc "psql -U postgres -d register_app -c 'SELECT 1;'"
kubectl -n infra exec register-postgres-postgresql-0 -- bash -lc "psql -U postgres -d keycloak -c 'SELECT 1;'"
```

### 4.5 Cleanup temporary secret file

```bash
shred -u /tmp/register-postgres-values.yaml
```

---

## 5) Phase K.5 — Keycloak (external DB, hardened secret flow)

> **Note:** Keycloak is deployed from a local Helm chart at
> `infra/helm/keycloak/` using the official upstream image
> `quay.io/keycloak/keycloak:26.0`. The previous Bitnami chart was
> abandoned after Bitnami removed all Keycloak images from Docker Hub.

### 5.1 Create values file with minimal secret exposure

```bash
umask 077
cat > /tmp/keycloak-values.yaml <<'YAML'
image:
  repository: quay.io/keycloak/keycloak
  tag: "26.0"
  pullPolicy: Never    # for k3d — pre-imported into containerd
database:
  host: postgresql.infra.svc.cluster.local
  port: 5432
  name: keycloak
  user: bn_keycloak
admin:
  user: admin
resources:
  requests:
    memory: 512Mi
    cpu: 250m
  limits:
    memory: 1Gi
    cpu: 1000m
YAML
```

### 5.2 Install Keycloak idempotently

```bash
# For GitOps (ArgoCD manages the chart via infra/argocd/apps/keycloak.yaml):
kubectl apply -f infra/argocd/apps/root.yaml

# For manual install outside ArgoCD:
helm upgrade --install keycloak ./infra/helm/keycloak \
  --namespace infra \
  -f /tmp/keycloak-values.yaml

kubectl -n infra rollout status deployment/keycloak --timeout=300s
```

### 5.3 Bootstrap realm locally

```bash
kubectl -n infra port-forward svc/keycloak 8081:80
```

Then configure:

- realm: `register`
- clients: `register-api` (confidential), `register-web` (public + PKCE)
- mappers: `sub -> x-user-id`, `email -> x-user-email`, roles claim

### 5.4 Verify OIDC metadata

```bash
curl -s http://localhost:8081/realms/register/.well-known/openid-configuration | jq .issuer
curl -s http://localhost:8081/realms/register/protocol/openid-connect/certs | jq .keys[0].kid
```

### 5.5 Cleanup temp values

```bash
shred -u /tmp/keycloak-values.yaml
```

---

## 6) RBAC + namespace hardening add-ons (recommended)

### 6.1 Restrict who can read secrets in `register`

```bash
# role deliberately excludes secrets read permissions
cat <<'YAML' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: register-dev-operator
  namespace: register
rules:
  - apiGroups: [""]
    resources: ["pods","services","configmaps","events"]
    verbs: ["get","list","watch","create","update","patch","delete"]
  - apiGroups: ["apps"]
    resources: ["deployments","statefulsets","daemonsets","replicasets"]
    verbs: ["get","list","watch","create","update","patch","delete"]
YAML
```

Bind only trusted users/groups to this role.

### 6.2 Default-deny network policy (register namespace)

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: register
spec:
  podSelector: {}
  policyTypes: ["Ingress","Egress"]
YAML
```

Then add explicit allow policies for required traffic paths.

---

## 7) Phase K.6 — CI/CD minimum with GitHub security practices

1. PR workflow: format/lint/test/SCA.
2. Main workflow: build + push GHCR image with immutable tag (`git-sha`).
3. Deploy workflow: Helm deploy to `local-dev`.
4. Provisioning workflow: SpiceDB graph reconcile.
5. Rollback runbook: `helm history` + `helm rollback`.

Security controls in GitHub:

- Enable branch protection + required reviews.
- Enable Dependabot + secret scanning + push protection.
- Prefer OIDC federation for cloud auth; avoid long-lived cloud keys.
- Use environment protections for non-dev deploys (required reviewers).

Validation:

```bash
helm -n register ls
helm -n register history <release-name>
kubectl -n register get pods
kubectl -n register get events --sort-by=.lastTimestamp | tail -n 30
```

Rollback:

```bash
helm -n register rollback <release-name> <revision>
```

---

## 8) Phase K.7 — ArgoCD GitOps + Image Updater

ArgoCD watches the Git repo for Helm chart changes and syncs them to the cluster. ArgoCD Image Updater closes the loop by detecting new GHCR image tags and committing the updated tag back to the repo — fully automated, no manual steps.

### 8.1 Install ArgoCD

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=ClusterIP

kubectl -n argocd rollout status deploy/argocd-server --timeout=180s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s
kubectl -n argocd rollout status deploy/argocd-application-controller --timeout=180s
```

### 8.2 Install ArgoCD CLI

```bash
ARGOCD_VERSION=$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest | jq -r .tag_name)
curl -fsSLO "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
curl -fsSLO "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/cli_checksums.txt"
grep argocd-linux-amd64 cli_checksums.txt | sha256sum --check
chmod +x argocd-linux-amd64
sudo mv argocd-linux-amd64 /usr/local/bin/argocd
rm -f cli_checksums.txt
argocd version --client
```

### 8.3 First login + change admin password

```bash
# port-forward ArgoCD API server
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
PF_PID=$!
sleep 3

# retrieve generated admin password
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

# login
argocd login localhost:8080 \
  --username admin \
  --password "$ARGOCD_PASS" \
  --insecure

# rotate immediately — do not keep the generated password
read -r -s -p "New ArgoCD admin password: " NEW_ARGOCD_PASS; echo
argocd account update-password \
  --account admin \
  --current-password "$ARGOCD_PASS" \
  --new-password "$NEW_ARGOCD_PASS"

unset ARGOCD_PASS NEW_ARGOCD_PASS
kill $PF_PID 2>/dev/null || true

# delete the bootstrap secret — no longer needed
kubectl -n argocd delete secret argocd-initial-admin-secret
```

### 8.4 Connect GitHub repository

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
PF_PID=$!
sleep 3

read -r -p "GitHub repo URL (https://github.com/org/repo): " GH_REPO
read -r -p "GitHub username: " GH_USER
read -r -s -p "GitHub PAT (repo read): " GH_PAT; echo

argocd repo add "$GH_REPO" \
  --username "$GH_USER" \
  --password "$GH_PAT" \
  --insecure

unset GH_USER GH_PAT
kill $PF_PID 2>/dev/null || true
```

### 8.5 Create the Application

This assumes your Helm chart is at `infra/helm/register/` in the repo, with `values.yaml` as the base values file.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
PF_PID=$!
sleep 3

argocd app create register \
  --repo "$GH_REPO" \
  --path infra/helm/register \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace register \
  --revision HEAD \
  --values values.yaml \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# trigger immediate sync and wait
argocd app sync register
argocd app wait register --health --timeout 120

kill $PF_PID 2>/dev/null || true
unset GH_REPO
```

### 8.6 Install ArgoCD Image Updater

```bash
helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --set config.argocd.insecure=true

kubectl -n argocd rollout status deploy/argocd-image-updater --timeout=120s
```

### 8.7 Give Image Updater GHCR read access

```bash
read -r -p "GitHub username: " GH_USER
read -r -s -p "GHCR token (read:packages): " GH_PAT; echo

kubectl -n argocd create secret generic ghcr-image-updater \
  --from-literal=username="$GH_USER" \
  --from-literal=password="$GH_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

unset GH_USER GH_PAT
```

### 8.8 Annotate Application for automated image tag commits

Replace `<org>/<image>` with your actual GHCR image path.

```bash
kubectl -n argocd annotate application register \
  "argocd-image-updater.argoproj.io/image-list=register=ghcr.io/<org>/<image>" \
  "argocd-image-updater.argoproj.io/register.update-strategy=digest" \
  "argocd-image-updater.argoproj.io/register.helm.image-name=image.repository" \
  "argocd-image-updater.argoproj.io/register.helm.image-tag=image.tag" \
  "argocd-image-updater.argoproj.io/write-back-method=git" \
  "argocd-image-updater.argoproj.io/git-branch=main" \
  "argocd-image-updater.argoproj.io/register.pull-secret=secret:argocd/ghcr-image-updater#username" \
  --overwrite
```

Image Updater will write detected tag changes to `infra/helm/register/.argocd-source-register.yaml` and commit them. ArgoCD then detects the git drift and syncs.

### 8.9 Verify the full automated loop

```bash
# watch Image Updater detect a new image push
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-image-updater -f

# inspect sync history
argocd app history register

# confirm running pod image digest
kubectl -n register get pods -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}'
```

The full automated loop:

```
git push
  → GitHub Actions: sbt test → docker build → push ghcr.io/<org>/<image>:<sha>
  → Image Updater: detects new digest, commits updated tag to infra/helm/register/
  → ArgoCD: detects git drift, runs helm upgrade on cluster
  → kubectl -n register get pods   ← new pod running within ~60s
```

---

## 9) Operational hygiene (rotate/revoke/audit)

### 9.1 Rotate GHCR token quickly

1. Revoke old token in GitHub.
2. Create new least-privilege token.
3. Recreate secret:

```bash
read -r -p "GitHub username: " GHCR_USER
read -r -s -p "New GHCR token: " GHCR_PAT; echo

kubectl -n register create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USER" \
  --docker-password="$GHCR_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

unset GHCR_USER GHCR_PAT
```

### 9.2 Audit checkpoints

```bash
kubectl -n register get events --sort-by=.lastTimestamp | tail -n 40
kubectl -n register get secret ghcr-pull -o yaml >/dev/null
kubectl auth can-i get secrets -n register --as=<subject>
```

---

## 10) Fast health-check bundle

```bash
kubectl get nodes
kubectl get ns
kubectl -n infra get pods
kubectl -n register get pods
kubectl -n cert-manager get pods
kubectl -n istio-system get pods
kubectl -n argocd get pods
kubectl top nodes || true
```

---

## 11) Security limitations / operational assumptions (must-read)

This setup is intentionally simple and does **not** eliminate all risk.

1. **No dedicated secret-manager service** in baseline:
   - Kubernetes Secrets are still base64 objects in etcd.
   - Mitigation here: at-rest encryption + strict RBAC + minimal secret lifetime in shell.

2. **Single-node k3s** is not HA:
   - Node compromise = cluster compromise.
   - Good for local/dev realism, not production resilience.

3. **Installer convenience scripts** (`curl | sh`) are used:
   - Acceptable for local bootstrap, weaker than fully pinned artifact verification.

4. **Port-forwarded admin surfaces** (Keycloak):
   - Keep sessions short, avoid public exposure, close terminal when done.

5. **Default-deny network policy requires explicit allow rules**:
   - If omitted, pods may have broader east-west access than intended.

6. **Human-operated secrets handling remains a risk**:
   - Shoulder surfing, terminal logging, shell history mistakes are still possible.
   - Mitigate with `read -s`, non-exported vars, immediate `unset`, short token TTL.

If you later need stronger controls without running a full external secret manager service, next incremental option is encrypted GitOps secrets (e.g., SOPS/age or Sealed Secrets) with strict key custody and rotation.
