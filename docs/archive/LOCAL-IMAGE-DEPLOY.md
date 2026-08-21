# Local Image Deploy — build → k3d import → ArgoCD rollout

How to get a locally built application image (register-server, frontend) running
in the local k3d cluster (`register-dev`). No registry involved: the Helm charts
use `pullPolicy: Never`, so the kubelet only ever uses images already present in
the k3d node's containerd store — put there by `k3d image import`.

## Version contract

| Where | Role |
|---|---|
| `register/build.sbt` `ThisBuild / version` | **Source of truth** (user-owned bump) |
| `register/.env` `APP_VERSION` | Mirror; compose tags images `local/<name>:${APP_VERSION:-dev}` |
| `infra/helm/<chart>/values.yaml` `image.tag` | **The deploy lever** — ArgoCD rolls on this change |
| `infra/helm/<chart>/Chart.yaml` `appVersion` | Informational only (`helm ls` display) |

Use the **version tag, not `dev`**: a mutable `dev` tag makes it impossible to
tell which build is running (k8s resolves images at pod creation; re-importing
under the same tag changes nothing for running pods, and `kubectl rollout
restart` fights ArgoCD selfHeal). A fresh version tag gives ArgoCD a real diff
and rolls the deployment GitOps-natively.

## Steps

**Order matters: build → import → THEN push.** ArgoCD (auto-sync + selfHeal)
rolls as soon as the values change lands on the git remote; if the image is not
yet in the node store, the pod goes `ErrImageNeverPull`.

```bash
# 0. register/ — bump version if this deploy warrants it (user-owned):
#    build.sbt ThisBuild / version + .env APP_VERSION, kept in sync.
V=$(grep -oP 'APP_VERSION=\K.*' ~/projects/register/.env)

# 1. Build from source (working tree!) — register/
cd ~/projects/register
docker compose build register-server                     # → local/register-server:$V  (~5–10 min, GraalVM native)
docker compose --profile frontend build frontend         # → local/frontend:$V         (profile flag required)

# 2. Import into the k3d node's containerd store
k3d image import local/register-server:$V local/frontend:$V -c register-dev
# verify:
docker exec k3d-register-dev-server-0 crictl images | grep -E "register-server|frontend"

# 3. register-infra/ — bump image.tag and appVersion, then push.
#    image.tag is the deploy lever (ArgoCD rolls on it); appVersion is
#    informational-only (`helm ls` display) but keep it in sync too.
#    infra/helm/register/values.yaml   → image.tag: "$V"
#    infra/helm/register/Chart.yaml    → appVersion: "$V"
#    infra/helm/frontend/values.yaml   → image.tag: "$V"
#    infra/helm/frontend/Chart.yaml    → appVersion: "$V"
cd ~/projects/register-infra
git add infra/helm/register infra/helm/frontend
git commit -m "deploy register + frontend $V"
git push

# 4. Don't wait ~3 min for ArgoCD's git poll — force a refresh
kubectl -n argocd annotate application register argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd annotate application frontend argocd.argoproj.io/refresh=normal --overwrite

# 5. Watch the rollout
kubectl -n register rollout status deployment/register --timeout=180s
kubectl -n register rollout status deployment/frontend --timeout=180s
kubectl -n register get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}'
```

## Gotchas

- **`rollout status` right after `git push` reports success on the OLD
  deployment** — ArgoCD hasn't polled yet. Check
  `kubectl -n argocd get application register -o jsonpath='{.status.sync.revision}'`
  against your pushed SHA, or just do step 4.
- **`kubectl logs deployment/<name>` during a rolling update can pick the old
  Terminating pod.** Check the log timestamps; target the new pod by name.
- **Verifying the running build**: the register app logs code locations
  (`file=Application.scala line=N`) — startup lines (e.g. the
  `StartupReadiness` irmin gate, `auth.mode=...`) identify the build quickly.
- **Old images linger in the node store.** Reclaim when confident:
  `docker exec k3d-register-dev-server-0 crictl rmi docker.io/local/register-server:dev`
- **Builder prerequisite**: `local/graalvm-builder:21` must exist; rebuild it
  only when `hdr-rng`/`vague-quantifier-logic` sources change (see register
  repo's register-dev skill / `docs/user/IMAGE-BUILD-REFERENCE.md`).
- **The build uses the register WORKING TREE, not a git ref** — make sure the
  checkout is what you intend to ship.

## Production (Hetzner) difference

None of this applies: images go to GHCR, ArgoCD Image Updater tracks digests
and writes tags back to git itself (`infra/argocd/apps/register.yaml`
annotations). This runbook is the local-dev substitute for that pipeline.
