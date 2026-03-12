# Action Plan: Sync register-infra with register v2

**Created:** 2026-03-12  
**Status:** In progress  
**Source analysis:** [infra-k8s-sync-register-v2.md](../../../register/docs/prompts/infra-k8s-sync-register-v2.md)

---

## Standing Instructions (apply to every section)

> **User is in charge of resolving new decisions not covered in original plans
> or any ambiguities discovered.** Stop and surface them before proceeding.

> **Quality check required after each section completes:**  
> Did we follow clean code, GitOps, and security best practices?  
> Can we avoid repetition or otherwise improve the implementation?  
> Summarise findings before moving to the next section.

> **Educational explanations required:**  
> Every command block must be preceded by a plain-language explanation of
> what the command does and why — covering the Kubernetes, GitOps, or
> security concept involved. Aim for one or two sentences per command so the
> reasoning is visible alongside the action.

---

## Image State Reference

| Image | Docker daemon tag | k3d (in-cluster) tag | Values.yaml ref | Action |
|---|---|---|---|---|
| Register server | `register-server:prod` | `register-server:local` (stale) | `tag: "local"` | Import prod tag + update chart to `"prod"` |
| Irmin | `local/irmin-prod:3.11` | `local/irmin:3.11` (dev, stale) | `repository: local/irmin, tag: "3.11"` | Import prod image + update chart |
| Frontend | `local/frontend:dev` | not imported | (chart does not exist) | Import + create chart |
| OPA | `openpolicyagent/opa:0.70.0-envoy` | same (pulled from registry) | chart value | No import needed |

**Rule for local dev:** k3d uses `pullPolicy: Never`. Images must be explicitly
imported with `k3d image import`. Docker daemon = source of truth for local builds.

---

## Section 0 — Import all required images into k3d

> **Standing instruction + quality check apply.**

These imports are prerequisites for every subsequent section. Do them first so
ArgoCD can pull images the moment the charts are in sync.

`k3d image import` copies an image from the host Docker daemon into the
containerd registry inside every k3d node. This is necessary because k3d
clusters use containerd, not Docker, and `pullPolicy: Never` tells Kubernetes
*never* to reach out to a registry — so the image must already be present in
containerd or the pod will fail with `ErrImageNeverPull`.

```bash
# Register: import the current prod build, which supersedes the stale :local import
k3d image import register-server:prod -c register-dev

# Irmin: import the new slim prod image (replaces the dev image in-cluster)
k3d image import local/irmin-prod:3.11 -c register-dev

# Frontend: new image, first import
k3d image import local/frontend:dev -c register-dev
```

`crictl images` queries the containerd image store inside the k3d node
directly (bypassing Docker), so the output is the ground truth of what
Kubernetes can actually schedule. If a tag is missing here, the pod will
fail regardless of what `docker images` shows on the host.

**Verify:**
```bash
docker exec k3d-register-dev-server-0 \
  crictl images 2>/dev/null | grep -E "register-server|irmin|frontend"
```

**Status:** [ ] pending

---

## Section 1 — Unblock OPA and irmin SyncErrors (P1.1)

> **Standing instruction + quality check apply.**

**Root cause:** `spec.selector` is immutable on Deployment (OPA) and StatefulSet
(irmin). The label standardisation in the previous session mutated these fields.
ArgoCD cannot patch them; the old resources must be deleted so ArgoCD recreates them.

`spec.selector` on a Deployment or StatefulSet is immutable after creation —
Kubernetes permanently rejects any patch that changes it. ArgoCD cannot work
around this; it will retry indefinitely and report `SyncError`. The only
escape is to delete the resource entirely so ArgoCD can recreate it from
scratch with the new selector already in place. ArgoCD's `selfHeal: true`
flag means it continuously reconciles the cluster to git — once the blocking
resource is gone, ArgoCD recreates it within ~30 seconds.

```bash
# Delete OPA Deployment — ArgoCD self-heal recreates within ~30s.
# All OPA pods disappear briefly; the waypoint returns 403 while they restart
# because ext_authz (OPA) is the authorization gate and it is fail-closed.
kubectl -n register delete deployment opa

# Delete irmin StatefulSet but KEEP the PVC (--cascade=orphan).
# Without --cascade=orphan, Kubernetes would delete the PersistentVolumeClaim
# too, erasing all stored risk-tree data permanently.
# The orphaned PVC is re-adopted when ArgoCD recreates the StatefulSet
# with the same name.
kubectl -n register delete statefulset irmin --cascade=orphan

# Watch for recreation — both should reach Running within ~60s
kubectl -n register get pods -w
```

`argocd app get --show-operation` prints the result of the last sync
operation (its Phase and Message), confirming whether ArgoCD successfully
applied the resource after the delete.

**Verify:**
```bash
argocd app get argocd/opa --show-operation   | grep "Phase:"   # → Succeeded
argocd app get argocd/irmin --show-operation | grep "Phase:"   # → Succeeded
```

**Status:** [ ] pending

---

## Section 2 — Fix register ports (P1.2 + P2.4, must ship atomically)

> **Standing instruction + quality check apply.**

**Root cause:** register server v2 binds API on **8090** and health probes on
**8091**. The Helm chart declares `service.port: 8080`, exposes only one
container port (`http`/8080), and probes via `port: http`. Result: probes hit
the wrong port; service routes to the wrong port; pod crashes every ~30s.

**Files changed (atomic):**
- `infra/helm/register/values.yaml` — ports + image tag
- `infra/helm/register/templates/deployment.yaml` — dual ports + probe targets
- `infra/helm/register/templates/service.yaml` — port 8090
- `infra/k8s/istio/peer-authentication.yaml` — health port 8080 → 8091
- `infra/k8s/network-policy/register.yaml` — CiliumNetworkPolicy health port 8080 → 8091

`rollout status` blocks until the Deployment reaches its desired replica
count with the new pod spec, or times out. It is the canonical way to
confirm a rollout completed rather than polling `get pods` manually.
Grepping the logs for `port=8090` confirms the running binary is the v2
build (the old stale image printed `port=8080`).

**Verify:**
```bash
kubectl -n register rollout status deployment/register --timeout=120s
kubectl logs -n register -l app.kubernetes.io/name=register | grep "port=8090"
kubectl -n register get pods -l app.kubernetes.io/name=register  # Ready: 1/1
```

**Status:** [ ] pending

---

## Section 3 — Switch irmin to prod image (P2.1)

> **Standing instruction + quality check apply.**

**Root cause:** `local/irmin:3.11` (dev, ~650 MB, opam, uid 1000, cannot set
`readOnlyRootFilesystem`) is deployed. `local/irmin-prod:3.11` (slim Alpine,
static irmin binary, uid 65532) is available and removes these constraints.

**Files changed:**
- `infra/helm/irmin/values.yaml` — repository + uid
- `infra/helm/irmin/templates/statefulset.yaml` — runAsUser/Group/fsGroup 1000→65532, add `readOnlyRootFilesystem: true`

`rollout status` on a StatefulSet waits for the controller to finish its
ordered rolling update (one pod at a time). `describe pod | grep Image`
confirms the scheduler actually pulled the prod image tag rather than
falling back to a cached layer of the old one.

**Verify:**
```bash
kubectl -n register rollout status statefulset/irmin --timeout=60s
kubectl -n register describe pod irmin-0 | grep "Image:"   # → local/irmin-prod:3.11
```

**Status:** [ ] pending

---

## Section 4 — Clean up auth env vars in register chart (P2.2)

> **Standing instruction + quality check apply.**

**Root cause:** `KEYCLOAK_ISSUER` is set as a plain-text `value:` in values.yaml
but is not used in `capability-only` auth mode. It is misleading and would be a
security issue if Keycloak integration were activated without converting it to a
`secretKeyRef`. Remove it for now; it will be re-added properly (via Secret)
when Keycloak JWT mode is enabled.

**Files changed:**
- `infra/helm/register/values.yaml` — remove KEYCLOAK_ISSUER; add explicit
  `REGISTER_AUTH_MODE: capability-only` to make the active mode visible.

`kubectl exec -- env` reads environment variables from the live running
container. This verifies that ArgoCD successfully applied the updated
ConfigMap/values and that the pod restarted with the new environment —
not that the git file was changed, but that the change actually reached
the process.

**Verify:**
```bash
kubectl -n register exec -it deploy/register -- env | grep -E "AUTH|KEYCLOAK"
# → REGISTER_AUTH_MODE=capability-only
# → no KEYCLOAK_ISSUER in output
```

**Status:** [ ] pending

---

## Section 5 — Frontend Helm chart + ArgoCD app + mesh config (P3.1–P3.4)

> **Standing instruction + quality check apply.**

**Root cause:** The frontend nginx SPA server does not exist in the cluster at
all. ADR-INFRA-007 documents the architecture; this section implements it.

**Files created:**
- `infra/helm/frontend/Chart.yaml`
- `infra/helm/frontend/values.yaml`
- `infra/helm/frontend/templates/_helpers.tpl`
- `infra/helm/frontend/templates/deployment.yaml`
- `infra/helm/frontend/templates/service.yaml`
- `infra/helm/frontend/templates/serviceaccount.yaml`
- `infra/argocd/apps/frontend.yaml`

**Files changed:**
- `infra/argocd/projects/app.yaml` — no change needed (Deployment already whitelisted)
- `infra/k8s/network-policy/register.yaml` — 3 new policies (frontend ingress, frontend→register egress, frontend health probe)
- `infra/k8s/istio/peer-authentication.yaml` — new `frontend-probe-permissive` entry (port 8080 PERMISSIVE for kubelet probes)

**Key values:**
```
image:          local/frontend:dev, pullPolicy: Never
containerPort:  8080 (nginx, uid 101)
service.port:   8080
env BACKEND_URL: http://register.register.svc.cluster.local:8090
securityContext: runAsUser/Group 101, readOnlyRootFilesystem: true
volumes:        emptyDir at /tmp (nginx writes temp files there)
```

`argocd app wait --health` polls ArgoCD until the app's health status
reaches `Healthy`, which means ArgoCD has applied all resources AND the
pod's readiness probe is passing. It is stricter than `--sync-policy`
alone because it verifies the workload is actually serving traffic, not
just that the manifests were applied.

`curl` against a port-forward validates the full path end-to-end: kubelet
proxy → nginx pod → (for API paths) register service → register pod.

**Verify:**
```bash
argocd app wait argocd/frontend --health --timeout 120
kubectl -n register get pods -l app.kubernetes.io/name=frontend  # Running + Ready
curl -s http://localhost:<port-forward>/ | grep -q '<html'       # serves SPA
curl -s -H 'Accept: application/json' localhost:<port>/health    # proxied to backend
```

**Status:** [ ] pending

---

## Section 6 — Istio Gateway + HTTPRoute for external ingress (P3.5) [DEFERRED]

> **Blocked on:** real domain name + DNS A record + cert-manager ClusterIssuer.  
> Not needed for local k3d (use `kubectl port-forward svc/frontend 8080:8080 -n register`).  
> Implement when deploying to Hetzner.

**Status:** [ ] deferred

---

## Ambiguities / Decisions Required

These were identified during analysis. **Do not proceed past the relevant
section until the user has resolved the item.**

| # | Section | Question | Status |
|---|---|---|---|
| A1 | §2 | `/workspaces` (exact) vs `/workspaces/*` (wildcard) in AuthorizationPolicy — does `POST /workspaces` require JWT or is it public? The current policy whitelists `/workspaces/*` (trailing wildcard only). | ❓ open |
| A2 | §5 | Frontend ingress path: should the Istio Gateway route ALL traffic to the frontend (and let nginx split API vs HTML), or should the HTTPRoute split at the Istio level? ADR-INFRA-007 says nginx handles all splitting — confirmed? | ✅ confirmed (ADR-INFRA-007) |
| A3 | §6 | Domain name for production TLS certificate | ❓ deferred to Hetzner phase |
