# GitOps Rollout — shared handoff from platform to GitOps

Everything from **"ArgoCD pods are Running"** onward. This sequence is
**identical** for every point (any cluster, any image repo) — the per-point
differences (git-auth method, TLS issuer, image repo) are called out inline and
summarised in [Environment differences](#environment-differences).

- **Starting point**: the cluster is **Platform Ready** — Cilium, Istio ambient,
  cert-manager, and ArgoCD installed with pods `Running`, and the image registry
  reachable. This is the cut-off point where the bootstrap tracks end; it is
  defined in full under [Platform Ready — the precondition](#platform-ready--the-precondition)
  below. Reached by either track: [MANUAL-BOOTSTRAP.md](MANUAL-BOOTSTRAP.md)
  (by hand, local) or [TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md)
  (Terraform, local or Hetzner)
- **Ending point**: the root App-of-Apps is applied, ArgoCD manages the whole
  stack from git, and the auth chain is verified
- **The boundary**: the moment you `kubectl apply -f infra/argocd/apps/root.yaml`
  — after that you stop running `kubectl`/`helm` by hand for anything in the
  GitOps layer

> **Local port note.** The ArgoCD UI/API steps below port-forward to
> `localhost:9090`. Any free local port works; 9090 avoids the k3d loadbalancer,
> which binds host `:8080`/`:8443`.

---

## Platform Ready — the precondition

**Platform Ready is the cut-off point**, not a separate stage: the moment both
bootstrap tracks stop and this guide begins. It is a state to verify, not another
tutorial. The cluster is Platform Ready when all of the following hold:

| # | Component | Ready condition | Verify |
|---|---|---|---|
| 1 | **Cluster** | Single node, k3s with `flannel-backend=none`, `disable-network-policy`, `disable=traefik`. (Hetzner also `secrets-encryption=true`; k3d does not encrypt Secrets at rest — see note.) | `kubectl get nodes` → one `Ready` node |
| 2 | **Cilium (CNI)** | Installed in `kube-system`, `cni.exclusive=false`, `operator.replicas=1`. Pod networking and NetworkPolicy enforcement live. | `cilium status --wait` |
| 3 | **Gateway API CRDs** | Standard-channel CRDs applied (needed by Istio waypoints and the ingress Gateway). | `kubectl get crd gateways.gateway.networking.k8s.io` |
| 4 | **Istio ambient** | `base`, `istio-cni` (`profile=ambient`), `ztunnel`, `istiod` all in `istio-system`. ztunnel DaemonSet Running on the node. | `kubectl -n istio-system get pods` all Running; `istioctl version` |
| 5 | **cert-manager** | Installed in `cert-manager` with `crds.enabled=true`. Ready to issue certs (self-signed locally, ACME on Hetzner). | `kubectl -n cert-manager get pods` all Running |
| 6 | **ArgoCD** | Installed in `argocd`, `server.insecure=true`, service `ClusterIP`. Server + repo-server + controller pods Running. | `kubectl -n argocd get pods` all Running |
| 7 | **ArgoCD Image Updater** | Installed in `argocd`, `config.argocd.insecure=true`. (Idle until GHCR images are in use.) | `kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-image-updater` |
| 8 | **Image repo reachable** | Point 1 (local-registry): the k3d-managed registry answers from host and cluster. Points 2 & 3 (GHCR): the `ghcr-pull` imagePullSecret is present (or the packages are public). See [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md). | `curl -s http://k3d-registry.localhost:5000/v2/_catalog` (point 1) |

> **Note — Secret encryption at rest.** Hetzner k3s runs with
> `--secrets-encryption=true`; k3d does not encrypt Secrets in the embedded
> datastore. This is the only at-rest difference between the two environments and
> does not affect any step below. It is not a security gap for local dev: the k3d
> datastore lives only in a Docker volume on your workstation.

One-shot check:

```bash
kubectl get nodes                      # one Ready node
kubectl -n kube-system get pods        # Cilium
kubectl -n istio-system get pods       # istiod, ztunnel, istio-cni
kubectl -n cert-manager get pods       # cert-manager
kubectl -n argocd get pods             # ArgoCD + Image Updater
```

All pods `Running`/`Completed` and one node `Ready` → start below at step 1.
ArgoCD is **not** yet enrolled in the mesh and the root App-of-Apps is **not**
yet applied — those are the first steps of this guide.

---

## Where this fits

| Step | Doc |
|---|---|
| Reach Platform Ready — the cluster + platform (by-hand **or** automated track) | [MANUAL-BOOTSTRAP.md](MANUAL-BOOTSTRAP.md) / [TERRAFORM-BOOTSTRAP.md](TERRAFORM-BOOTSTRAP.md) |
| Create + apply the encrypted secrets | [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md) |
| **Enroll ArgoCD, connect git, apply the root app, run tests** | **This guide** |
| Day-to-day GitOps workflow, repo layout, glossary | [GITOPS-OPERATIONS.md](GITOPS-OPERATIONS.md) |

---

## 1) Enroll ArgoCD in the mesh

> **Why ArgoCD must be inside the mesh.** ArgoCD is a high-value target: its
> `application-controller` has broad cluster-wide RBAC, and its `repo-server`
> **executes arbitrary code** (renders Helm, runs Kustomize, evaluates config
> plugins). A supply-chain attack that poisons a chart or git hook gets code
> execution inside `repo-server`. The relevant threat model is not "who sniffs
> the wire" but "what a compromised pod can reach."
>
> When ArgoCD is installed, its namespace does not yet carry the
> `istio.io/dataplane-mode: ambient` label, so ztunnel does not intercept its
> traffic and the server ↔ repo-server ↔ controller connections are plaintext on
> the pod network. From inside `repo-server` an attacker could then sniff
> controller traffic, forge gRPC to `argocd-server`, or harvest ServiceAccount
> tokens. Enrolling the namespace gives every pod a SPIFFE identity and mutual
> authentication, so even a fully compromised `repo-server` cannot impersonate
> the controller or read its traffic.
>
> **Two accommodations must be applied first.** The ArgoCD chart ships
> per-component NetworkPolicies written for a non-mesh cluster; Istio ambient
> changes two things they don't account for:
>
> 1. **Kubelet health probes.** ztunnel SNATs kubelet probes to the link-local
>    `169.254.7.127`; the chart's default-deny drops that source, so
>    `repo-server` (8084) and `application-controller` (8082) fail liveness and
>    CrashLoopBackOff. A narrow CiliumNetworkPolicy allows only that link-local
>    source to the probe port — strictly more secure than a PeerAuthentication
>    PERMISSIVE exception, because the port stays STRICT mTLS for all pod traffic.
> 2. **Intra-namespace HBONE.** In ambient, pod-to-pod traffic is HBONE on TCP
>    15008; Cilium sees 15008, not the app port, so the chart's app-port
>    NetworkPolicies drop `server → redis` and `server → repo-server` once
>    meshed. An ingress-only HBONE allow fixes it (an egress rule would cut off
>    `server → kube-apiserver`).
>
> Both live in `infra/k8s/network-policy/argocd.yaml` and **must** be applied
> imperatively here, before enrollment — they cannot come from the mesh-policy
> Application, which is delivered by ArgoCD itself (a circular dependency).
> mesh-policy adopts and reconciles the same file at steady state.

```bash
# 1) Apply the ambient accommodations BEFORE enrolling (probe CiliumNPs + HBONE).
kubectl apply -f infra/k8s/network-policy/argocd.yaml

# 2) Enroll the argocd namespace in the mesh. The namespace chart also declares
#    argocd with meshEnroll: true (infra/helm/namespaces/values.yaml), so once
#    that syncs the label is under GitOps governance and cannot drift.
kubectl label namespace argocd istio.io/dataplane-mode=ambient

# 3) Restart so all argocd pods are recreated cleanly inside the mesh. istio-cni
#    programs a pod's mesh redirection at creation, so pre-existing pods must be
#    recreated to be cleanly meshed.
kubectl -n argocd rollout restart deployment,statefulset
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=180s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s

# VERIFICATION: label set, all argocd pods Ready (no CrashLoopBackOff).
kubectl get namespace argocd --show-labels | grep dataplane-mode
kubectl -n argocd get pods
```

> The imperative label closes the ~60-second window before ArgoCD's first sync;
> the declarative `meshEnroll: true` makes the enrollment permanent and
> drift-proof once the namespaces app syncs (§6).

---

## 2) Rotate the ArgoCD admin password

> ArgoCD generates a random admin password on install and stores it as a
> Kubernetes Secret. Rotate it immediately and delete the bootstrap secret —
> auto-generated credentials should never persist.

```bash
kubectl -n argocd port-forward svc/argocd-server 9090:80 &
PF_PID=$!
sleep 3

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

# --insecure = skip TLS check to the ArgoCD server over the local port-forward
# (plain HTTP locally); it does not affect any other connection.
argocd login localhost:9090 --username admin --password "$ARGOCD_PASS" --insecure

read -r -s -p "New ArgoCD admin password: " NEW_PASS; echo
argocd account update-password \
  --account admin --current-password "$ARGOCD_PASS" --new-password "$NEW_PASS"

unset ARGOCD_PASS NEW_PASS
kubectl -n argocd delete secret argocd-initial-admin-secret
kill $PF_PID 2>/dev/null || true
```

---

## 3) Apply the encrypted secrets

The PostgreSQL, Keycloak, and SpiceDB workloads read their credentials from
Kubernetes Secrets that must exist **before** ArgoCD syncs them. Apply them now,
by hand, with a YubiKey touch:

> **See [SECRETS-BOOTSTRAP.md §6](SECRETS-BOOTSTRAP.md#6-apply-the-secrets-to-the-cluster).**
> There is no cluster-side age key to inject — ArgoCD does not decrypt anything;
> the operator applies the decrypted Secrets directly.

---

## 4) Connect ArgoCD to the git repository

> ArgoCD maintains an allow list of trusted repositories — only registered repos
> can be referenced in Application manifests. `argocd repo add` adds your repo
> and stores the credential as a Kubernetes Secret in the `argocd` namespace.

The git-auth method is the one per-environment difference here:

| Environment | Method | Why |
|---|---|---|
| **Local (k3d)** | SSH **deploy key** | Read-only, scoped to one repo, no hardware dependency inside the cluster |
| **Hetzner** | HTTPS + **PAT** | Same trust scope; PAT with `read:repo` is simplest for a headless server |

Both are equivalent in trust (read-only, single repo). ArgoCD runs as a pod — it
cannot use your YubiKey or personal SSH agent, so it gets its own credential.

**Local — SSH deploy key:**

```bash
# Generate a dedicated, read-only, non-hardware keypair for ArgoCD.
ssh-keygen -t ed25519 -C "argocd@register-dev" -f ~/.ssh/argocd_deploy_key -N ""
cat ~/.ssh/argocd_deploy_key.pub
# Add this public key at: GitHub repo → Settings → Deploy keys → Add deploy key
# (leave "Allow write access" UNCHECKED — ArgoCD only reads).

kubectl -n argocd port-forward svc/argocd-server 9090:80 &
PF_PID=$!; sleep 3
argocd login localhost:9090 --username admin --insecure
argocd repo add git@github.com:risquanter/register-infra.git \
  --ssh-private-key-path ~/.ssh/argocd_deploy_key \
  --insecure-skip-server-verification
kill $PF_PID 2>/dev/null || true
rm ~/.ssh/argocd_deploy_key   # ArgoCD stored it as a Secret; remove the disk copy
```

**Hetzner — HTTPS + PAT:**

```bash
kubectl -n argocd port-forward svc/argocd-server 9090:80 &
PF_PID=$!; sleep 3
read -r -p "GitHub repo URL (https://github.com/org/repo): " GH_REPO
read -r -p "GitHub username: " GH_USER
read -r -s -p "GitHub PAT (read:repo scope): " GH_PAT; echo
argocd repo add "$GH_REPO" --username "$GH_USER" --password "$GH_PAT" --insecure
unset GH_USER GH_PAT
kill $PF_PID 2>/dev/null || true
```

> **Deploying from a fork?** The Application manifests and AppProject
> `sourceRepos` reference `git@github.com:risquanter/register-infra.git`. Replace
> the repoURL in every file under `infra/argocd/` that carries it (use the SSH
> form for local), commit, and push before applying the root app:
> ```bash
> grep -rl "git@github.com:risquanter/register-infra.git" infra/argocd/ \
>   | xargs sed -i "s|git@github.com:risquanter/register-infra.git|<your-fork-ssh-url>|g"
> ```

---

## 5) Ensure application images are in the registry

The root app deploys `register`, `irmin`, and `frontend` with
`pullPolicy: IfNotPresent`. Their images must be pushed to the registry the
cluster pulls from **before** the root app syncs, or those Applications report
`Degraded` (`ImagePullBackOff`). This is a one-time precondition here; the same
loop is how you ship every later build.

- Build and push the three images — see [IMAGE-DEPLOY.md](IMAGE-DEPLOY.md).
  The local registry (point 1) was created and wired into the cluster by the track
  that got you to Platform Ready ([checklist #8](#platform-ready--the-precondition));
  for the GHCR points (2 & 3) you push to GHCR instead.
- The image-repo axis (`local-registry` ↔ `ghcr`) is a values choice, not a
  cluster change — see [IMAGE-DEPLOY.md § the image-repo axis](IMAGE-DEPLOY.md#the-image-repo-axis).
- The public upstream images (PostgreSQL, Keycloak, SpiceDB, OPA, nginx) need no
  action — the node pulls them directly.

---

## 6) Apply the root App-of-Apps — the handoff

> **The single most important command.** The root Application points ArgoCD at
> `infra/argocd/apps/`. ArgoCD discovers every child Application there and
> deploys it. Adding a service later = adding one YAML file to that directory and
> pushing.

```bash
# This is the LAST kubectl apply. After it, ArgoCD manages the GitOps layer.
kubectl apply -f infra/argocd/apps/root.yaml
```

ArgoCD then discovers and deploys:

| ArgoCD Application | What it deploys | Source |
|---|---|---|
| `namespaces` | `argocd`, `register`, `infra`, `observability`, `kyverno` namespaces — Pod Security labels, mesh enrollment, LimitRanges | `infra/helm/namespaces/` |
| `kyverno` | Kyverno admission controller (wave 1, `kyverno` project/namespace) | Upstream Helm chart v3.7.1 (remote) |
| `postgresql` | PostgreSQL (StatefulSet) in `infra` | Bitnami Helm chart (remote) |
| `keycloak` | Keycloak IdP in `infra` (init container copies `/opt/keycloak` to emptyDir for `readOnlyRootFilesystem`) | `infra/helm/keycloak/` (`quay.io/keycloak/keycloak:26.0`) |
| `spicedb` | SpiceDB authorization service in `infra` (wave 3) | `infra/helm/spicedb/` (`ghcr.io/authzed/spicedb`) |
| `opa` | OPA ext_authz server (2 replicas + PDB) in `register` | `infra/helm/opa/` |
| `irmin` | Irmin GraphQL persistence backend (StatefulSet + PVC) in `register` | `infra/helm/irmin/` |
| `mesh-policy` | Istio JWT/auth, PeerAuthentication, NetworkPolicies, RBAC, ingress Gateway | `infra/k8s/` (raw YAML) |
| `register` | Application API server (8090 API, 8091 health) in `register` | `infra/helm/register/` |
| `frontend` | Frontend SPA (nginx) in `register` | `infra/helm/frontend/` |

---

## 7) Watch the sync

```bash
kubectl -n argocd port-forward svc/argocd-server 9090:80 &
PF_PID=$!; sleep 3
argocd login localhost:9090 --username admin --insecure

argocd app list
argocd app wait namespaces  --health --timeout 60
argocd app wait postgresql  --health --timeout 300
argocd app wait keycloak    --health --timeout 300
argocd app wait irmin       --health --timeout 120
argocd app wait mesh-policy --health --timeout 60
argocd app wait frontend    --health --timeout 60
argocd app wait register    --health --timeout 120
kill $PF_PID 2>/dev/null || true

# Or browse the UI: kubectl -n argocd port-forward svc/argocd-server 9090:80
# then open http://localhost:9090 (username admin, the password from §2).
```

---

## 8) Install the Istio waypoint

> **What is a waypoint?** Ambient mode has two proxy layers: **ztunnel** (L4,
> already running — mTLS for all pod traffic) and the **waypoint** (L7,
> per-namespace Envoy — JWT validation, header stripping, OPA ext_authz,
> AuthorizationPolicy). The auth chain in [SECURITY-FLOW.md](SECURITY-FLOW.md)
> runs entirely in the waypoint; without it, only ztunnel's L4 mTLS is in effect.
>
> `istioctl waypoint apply` is the officially supported method and handles
> internal wiring that is complex to replicate as static YAML — an accepted
> imperative step alongside the bootstrap layer.

```bash
# PREREQUISITE: the register namespace exists (created by the namespaces app, §6).
kubectl get ns register --show-labels | grep ambient

istioctl waypoint apply -n register --enroll-namespace

# VERIFICATION: a Gateway object exists in the register namespace.
kubectl -n register get gateway
```

---

## 9) Verify the ingress gateway

> The ingress Gateway (distinct from the waypoint — it is the *entry point* from
> outside the cluster) terminates **HTTPS on :443** and is deployed by the
> `mesh-policy` Application from `infra/k8s/istio/ingress-gateway.yaml`. There is
> deliberately **no plaintext :80** — JWTs and capability URLs must not cross the
> wire in cleartext. This section is verification only; no imperative step.
>
> **The one per-environment difference is the TLS issuer**: locally a
> **self-signed** `ClusterIssuer` (`infra/k8s/cert-manager/selfsigned-issuer.yaml`);
> Hetzner swaps in an ACME/Let's Encrypt issuer bound to the real domain. The
> Gateway and HTTPRoute are identical. See [ADR-INFRA-007 §2](adr/ADR-INFRA-007.md).

```bash
# VERIFICATION: Gateway PROGRAMMED, its LoadBalancer Service has an EXTERNAL-IP,
# and the TLS secret was issued by cert-manager.
kubectl -n register get gateway register-ingress
kubectl -n register get svc register-ingress-istio
kubectl -n register get secret register-ingress-tls

# End-to-end (local: -k because the cert is self-signed):
curl -sk https://localhost:8443/ | head -1        # → HTTP/1.1 200 OK
```

> **AuthorizationPolicy public paths.** With L7 enforcement active, only paths
> in `allow-capability-urls`
> ([authorization-policy.yaml](../infra/k8s/istio/authorization-policy.yaml)) are
> reachable without a JWT — `/w/*`, `/health`, plus the SPA root `/` and static
> assets. Anything not whitelisted is default-denied (403).

---

## 10) Configure Keycloak

> Keycloak (deployed in §6) is the identity provider: it handles login, issues
> JWTs, and exposes a JWKS endpoint that Istio uses to validate token signatures.
> Realm configuration is stored in PostgreSQL, not in git.

```bash
kubectl -n infra port-forward svc/keycloak 8081:80
# Open http://localhost:8081.
```

Configure in the admin UI:

1. **Realm**: `register` (an isolated tenant; the `master` realm is admin-only).
2. **Client `register-api`** — confidential, service account enabled.
3. **Client `register-web`** — public, PKCE enabled.
4. **User** — a test user with a password.
5. **Realm roles** — `analyst` (read), `editor` (read+write), `team_admin`
   (team settings + cache).
6. **Protocol mappers** — ensure the JWT carries the claims the mesh/OPA expect:
   `sub` (→ `x-user-id`), `email` (→ `x-user-email`), and `realm_access.roles`.

```bash
# VERIFICATION: OIDC discovery + JWKS + a test-user token.
curl -s http://localhost:8081/realms/register/.well-known/openid-configuration | jq .issuer
# Expected: "http://keycloak.infra.svc.cluster.local/realms/register"
curl -s http://localhost:8081/realms/register/protocol/openid-connect/certs | jq .keys[0].kid
curl -s -X POST "http://localhost:8081/realms/register/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=register-web \
  -d username=<test-user> -d password=<test-password> | jq -r .access_token
```

---

## 11) Test the authentication chain

> These verify the security invariants from [SECURITY-FLOW.md](SECURITY-FLOW.md):
> the mesh rejects invalid tokens, strips forged headers, and blocks direct pod
> access. Run them after every Istio policy change. Prerequisites: §8 (waypoint)
> and §10 (realm + test user). For the full Layer 0/1/2 walkthrough see
> [TESTING.md § Curl Demo](TESTING.md#curl-demo--defence-layers-02).

```bash
kubectl -n register port-forward svc/register 8090:8090 &
REGISTER_PF=$!; sleep 2
TOKEN=$(curl -s -X POST \
  "http://localhost:8081/realms/register/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=register-web \
  -d username=demo-editor -d password=editor-demo-2026 | jq -r .access_token)

# T2 — invalid JWT rejected (expect 401)
curl -si -H "Authorization: Bearer this.is.not.a.valid.jwt" http://localhost:8090/health | head -1

# T3 — forged identity header does not bypass auth (expect 401)
curl -si -H "x-user-id: 00000000-0000-0000-0000-000000000001" http://localhost:8090/health | head -1

# Valid JWT (expect 200 once register is running)
curl -si -H "Authorization: Bearer $TOKEN" http://localhost:8090/health | head -1

# T1 — direct pod access blocked by NetworkPolicy
POD_IP=$(kubectl -n register get pods -l app.kubernetes.io/name=register \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
if [ -n "$POD_IP" ]; then
  kubectl run curltest --rm -i --restart=Never --image=curlimages/curl -- \
    curl -s --connect-timeout 5 "http://${POD_IP}:8091/health" \
    && echo "FAIL: direct pod access succeeded" || echo "PASS: direct pod access blocked"
fi
kill $REGISTER_PF 2>/dev/null || true

# mTLS active — HBONE means encrypted; NONE/TCP means plaintext (not meshed).
istioctl ztunnel-config workloads
kubectl get ns --show-labels | grep ambient
istioctl proxy-status
```

---

## 12) Post-deploy security verification

After ArgoCD has synced everything, verify these properties. Items marked
**(prod only)** apply when the production realm is active
(`realm.realmFile: realms/register-realm-prod.json` in the Keycloak Helm values).

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | Waypoint running | `kubectl -n register get gtw waypoint` | `PROGRAMMED: True` |
| 2 | OPA healthy | `kubectl -n register get pods -l app.kubernetes.io/name=opa` | `Running`, `Ready` |
| 3 | PeerAuth STRICT | `kubectl -n register get pa -o jsonpath='{..mode}'` | `STRICT` |
| 4 | JWT chain works | acquire token, decode, verify `aud`/`roles` | `aud: register-api` |
| 5 | ROPC rejected **(prod only)** | `bats tests/bats/opa-authz.bats` — GROUP 8 passes | 8.1, 8.2 PASS |
| 6 | Conftest clean | `./tests/run-regression.sh --static-only` | 0 failures |
| 7 | Header stripping | `bats tests/bats/header-security.bats` — GROUP 1 | 1.1–1.5 PASS |

---

## Environment differences

Everything in the GitOps layer (Helm charts, ArgoCD Applications, Istio policies,
OPA rules, NetworkPolicies, Pod Security labels) is portable as-is. The remaining
differences fall on the two axes from [START-HERE.md](START-HERE.md).

**Image-repo axis** (independent of the cluster — points 1 vs 2/3):

| Area | local-registry (point 1) | GHCR (points 2 & 3) |
|---|---|---|
| Application images | pushed to the k3d registry (`k3d-registry.localhost:5000/*`); `IfNotPresent` | pushed to GHCR (`ghcr.io/risquanter/*`), Image Updater tracks digest; `IfNotPresent` |
| Overlay (register/irmin/frontend) | `values-localreg.yaml` | `values-ghcr.yaml` (+ `ghcr-pull` secret) |

**Cluster axis** (local k3d vs Hetzner — points 1/2 vs 3):

| Area | Local (k3d) | Hetzner (k3s) |
|---|---|---|
| Git auth for ArgoCD | SSH deploy key | HTTPS + PAT |
| TLS issuer | self-signed `ClusterIssuer` | ACME / Let's Encrypt |
| Secrets at rest | not available in k3d | k3s `--secrets-encryption` (AES-CBC) |
| Keycloak hostname | permissive | `KC_HOSTNAME_STRICT=true` (bare IP, then domain) |
| Keycloak realm | dev realm (`values-local.yaml`) | `register-realm-prod.json` (`values-hetzner.yaml`) |

> The image-repo difference is expressed as overlays decoupled from the cluster
> ([ADR-INFRA-014](adr/ADR-INFRA-014.md)): the shared `values.yaml` holds
> `image.tag` and `pullPolicy`; `values-localreg.yaml` sets `image.repository` to
> the local k3d registry and `values-ghcr.yaml` sets it to GHCR (plus the
> `ghcr-pull` imagePullSecret) — layered via each Application's `helm.valueFiles`.
> Keycloak has no image-repo choice (upstream image); its `values-local.yaml` /
> `values-hetzner.yaml` overlay carries the cluster-axis realm file. See
> [IMAGE-DEPLOY.md § the image-repo axis](IMAGE-DEPLOY.md#the-image-repo-axis).
> The remaining cluster differences (cert issuer self-signed↔ACME,
> `KC_HOSTNAME_STRICT`, ingress host) are still tracked —
> see [TODO.md](TODO.md) § Multi-Environment Values Overlay.

---

## Day-to-day GitOps workflow

Editing files, committing, previewing (`argocd app diff`), the automated deploy
loop (CI → GHCR → Image Updater → ArgoCD), the repo layout, and the glossary are
in the shared operations reference — identical regardless of environment:

- [GITOPS-OPERATIONS.md — Making changes](GITOPS-OPERATIONS.md#making-changes--the-gitops-workflow)
- [GITOPS-OPERATIONS.md — The automated deploy loop](GITOPS-OPERATIONS.md#the-automated-deploy-loop)
- [GITOPS-OPERATIONS.md — Repository layout](GITOPS-OPERATIONS.md#repository-layout)
- [GITOPS-OPERATIONS.md — Troubleshooting](GITOPS-OPERATIONS.md#troubleshooting)
