# Image Deploy — build → push → rollout, the repetitive loop

The recurring steps to get a locally built application image running in the
cluster, under the **registry model**: build the image, `docker push` it to a
registry the cluster pulls from, bump the chart's `image.tag`, and let ArgoCD
roll the Deployment. This is the loop you run every time you ship a new build —
understand it once here; the other docs reference this file for the details
rather than repeating them.

- **One-time registry setup** is **not** here. Creating the local registry
  (image-repo point 1) is part of reaching Platform Ready — [MANUAL-BOOTSTRAP.md
  §1.1](MANUAL-BOOTSTRAP.md) by hand, or `create_local_registry=true` in
  `envs/local`. The `ghcr-pull` secret for the GHCR points (2 and 3) is created in
  [SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md).
- **First rollout** cites this doc as a precondition
  ([GITOPS-ROLLOUT.md §5](GITOPS-ROLLOUT.md#5-ensure-application-images-are-in-the-registry)):
  the images must be in the registry before the root app syncs.

> **Only three images go through this loop** — the ones built from the
> `risquanter/register` repository: `register-server`, `irmin-prod`, `frontend`.
> Every other workload (PostgreSQL, Keycloak, SpiceDB, OPA, the nginx base) runs
> a public upstream image the node pulls directly from its registry — no build,
> no push, no action here.

---

## The image-repo axis

Which registry the cluster pulls application images from is one of the two axes in
[START-HERE.md](START-HERE.md), and it is **independent of the cluster**: the same
choice works on a local k3d cluster or a Hetzner VM. It is set by the **image-repo
overlay** layered on the chart, through the single field `image.repository`;
nothing else changes. `image.tag` and `pullPolicy: IfNotPresent` are identical for
both repos, so they stay in the shared `values.yaml`. (The overlay was decoupled
from the cluster/environment — [ADR-INFRA-014](adr/ADR-INFRA-014.md).)

| Image repo | `image.repository` | Overlay | Used by points |
|---|---|---|---|
| local-registry | `k3d-registry.localhost:5000/<image>` | `values-localreg.yaml` | 1 (built and `docker push`ed by hand) |
| GHCR | `ghcr.io/risquanter/<image>` | `values-ghcr.yaml` (+ `ghcr-pull` secret) | 2 and 3 (CI pushes; Image Updater tracks the GHCR digest) |

`pullPolicy: IfNotPresent` for both — the kubelet pulls a tag it does not already
have, from whichever registry `image.repository` names. From the GitOps engine's
point of view the image is genuinely "in the registry" in both cases; the
local-registry path mirrors the GHCR pull path exactly, which is the point.

**Switching the axis** is a one-line change to the ArgoCD Application's
`helm.valueFiles`: `values-localreg.yaml` ↔ `values-ghcr.yaml`. The committed
default is `values-localreg.yaml` (point 1); point 2 uses the same local cluster
with `values-ghcr.yaml` plus the `ghcr-pull` secret. Keycloak, which pulls an
upstream image, has no entry here — its overlay is the cluster axis (realm), not
the image repo.

---

## Version contract

| Where | Role |
|---|---|
| `register/build.sbt` `ThisBuild / version` | **Source of truth** (user-owned bump) |
| `register/.env` `APP_VERSION` | Mirror; compose tags images `local/<name>:${APP_VERSION:-dev}` |
| `infra/helm/<chart>/values.yaml` `image.tag` | **The deploy lever** — ArgoCD rolls on this change |
| `infra/helm/<chart>/Chart.yaml` `appVersion` | Informational only (`helm ls` display) |

Use a **fresh version tag per deploy, never a mutable `dev`.** With
`pullPolicy: IfNotPresent`, re-pushing content under a tag the node already has
changes nothing for the running pod — the kubelet will not re-pull. A new
version tag forces the pull and gives ArgoCD a real diff to roll on. A mutable
tag also makes it impossible to tell which build is running.

---

## Local loop (`local-registry`)

```bash
# 0. register/ — bump the version if this deploy warrants it (user-owned):
#    build.sbt ThisBuild / version + .env APP_VERSION, kept in sync.
V=$(grep -oP 'APP_VERSION=\K.*' ~/projects/register/.env)
REG=k3d-registry.localhost:5000

# 1. Build from source (the working tree!) — register/
cd ~/projects/register
docker compose build register-server                 # → local/register-server:$V  (~5–10 min, GraalVM native)
docker compose --profile frontend build frontend     # → local/frontend:$V          (profile flag required)
docker compose build irmin                            # → local/irmin-prod:$V (only if irmin changed)

# 2. Tag for the local registry and push. After the push the image is in the
#    registry — the cluster pulls it exactly as it would pull from GHCR.
docker tag local/register-server:$V $REG/register-server:$V && docker push $REG/register-server:$V
docker tag local/frontend:$V        $REG/frontend:$V        && docker push $REG/frontend:$V
# irmin uses a fixed 3.11 tag unless you changed it:
docker tag local/irmin-prod:3.11    $REG/irmin-prod:3.11    && docker push $REG/irmin-prod:3.11

# 3. register-infra/ — bump image.tag (the deploy lever) and appVersion, then push.
#    infra/helm/register/values.yaml  → image.tag: "$V"   ; Chart.yaml → appVersion: "$V"
#    infra/helm/frontend/values.yaml  → image.tag: "$V"   ; Chart.yaml → appVersion: "$V"
cd ~/projects/register-infra
git add infra/helm/register infra/helm/frontend
git commit -m "deploy register + frontend $V"
git push

# 4. Don't wait ~3 min for ArgoCD's git poll — force a refresh.
kubectl -n argocd annotate application register argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd annotate application frontend argocd.argoproj.io/refresh=normal --overwrite

# 5. Watch the rollout.
kubectl -n register rollout status deployment/register --timeout=180s
kubectl -n register rollout status deployment/frontend --timeout=180s
kubectl -n register get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
```

Verify a tag is in the registry (from the host):

```bash
curl -s http://k3d-registry.localhost:5000/v2/register-server/tags/list | jq
```

---

## GHCR loop (`ghcr`) — points 2 and 3

Switching the image-repo axis to GHCR needs no cluster change — only where images
are pushed and which `image.repository` the chart renders. This is point 2 on a
local cluster and point 3 on Hetzner; both are supported, tested paths.

- **Push** to `ghcr.io/risquanter/<image>` instead of the local registry
  (`docker push`, or let CI build and push on a git push to `risquanter/register`).
  GHCR packages are private by default — a `docker push` (or pull) fails with 403
  until you authenticate with a PAT (`write:packages`/`read:packages`) or make the
  package public. This auth step is the main thing point 2 exists to teach on a
  familiar local cluster before adding a VM.
- **Select GHCR** by layering `values-ghcr.yaml` (sets the GHCR `image.repository`
  + the `ghcr-pull` imagePullSecret) after `values.yaml` in the ArgoCD
  Application's `helm.valueFiles`, in place of `values-localreg.yaml`.
- **In steady state**, ArgoCD Image Updater watches GHCR, tracks the image
  **digest**, and commits the updated `image.repository`/`image.tag` back to git
  itself — the fully automated loop in
  [GITOPS-OPERATIONS.md § The automated deploy loop](GITOPS-OPERATIONS.md#the-automated-deploy-loop).
  You stop running this loop by hand once Image Updater is wired.

The `ghcr-pull` secret (read-only GHCR pull credential) is created during
bootstrap ([SECRETS-BOOTSTRAP.md](SECRETS-BOOTSTRAP.md)); it is the only
cluster-side prerequisite for the GHCR points.

---

## Gotchas

- **`rollout status` right after `git push` reports success on the OLD
  deployment** — ArgoCD has not polled yet. Check
  `kubectl -n argocd get application register -o jsonpath='{.status.sync.revision}'`
  against your pushed SHA, or just do step 4.
- **`kubectl logs deployment/<name>` during a rolling update can pick the old
  Terminating pod.** Check log timestamps; target the new pod by name.
- **Verifying the running build**: the register app logs code locations
  (`file=Application.scala line=N`) — startup lines (the `StartupReadiness` irmin
  gate, `auth.mode=...`) identify the build quickly.
- **Old tags linger in the node store and the registry.** Reclaim node images
  with `docker exec k3d-register-dev-server-0 crictl rmi <image>`; the registry
  container's blobs clear on `k3d registry delete` / cluster teardown.
- **The build uses the register WORKING TREE, not a git ref** — make sure the
  checkout is what you intend to ship.
- **Builder prerequisite**: `local/graalvm-builder:21` must exist; rebuild it
  only when `hdr-rng`/`vague-quantifier-logic` sources change (see the register
  repo's `docs/user/IMAGE-BUILD-REFERENCE.md`).
