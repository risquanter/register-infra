# Outstanding Tasks — register-infra

> Canonical task list. All pending work is tracked here.
> Uses terminology from AUTHORIZATION-PLAN.md (L0/L1/L2 layers, Phase K).
>
> **Responsibility boundary**: this repo covers infrastructure (Helm charts,
> Istio manifests, OPA policies, NetworkPolicies, SOPS secrets, ArgoCD apps).
> Application-side authorization code lives in `register` and is tracked by
> `docs/prompt-l2-agent.md` in that repo.
>
> **Cross-repo design decisions resolved 2026-07-04 (updated 2026-07-05):**
> - SpiceDB TLS: HTTP in-cluster — mesh (HBONE mTLS) provides encryption.
>   ~~Register app must change `SpiceDbConfig.url` type from `SecureUrl` → `SafeUrl`~~
>   → **RESOLVED**: Wave 0C shipped `MeshServiceUrl` (accepts `http://` and `https://`;
>   mesh mTLS assumed) in `SpiceDbConfig.scala`. No app-side change pending.
>   Revisit for Hetzner (Phase 4) with a real PKI. See ADR-INFRA-010, IMPL-PLAN §C.
> - PostgreSQL SpiceDB DB provisioning: idempotent PostSync Job on the `postgresql` ArgoCD app.
>   Works on fresh and existing clusters. See Pre-SpiceDB §3 below.
>
> **Register app wave status (re-verified against CODE 2026-07-06 — all app-side blockers cleared):**
> - Waves 0B, 0C, 0D, 1, 2, 4–5, 6 ✅ — confirmed in code.
> - **Wave 3 ✅ implemented**: `auth/AuthorizationServiceSpiceDB.scala`, wired in fine-grained
>   mode (`Application.scala` `chooseAuthorizationService`), OTel `authz.check.total` /
>   `authz.check.latency_ms` emitted, T-U1–T-U14 unit tests present.
> - **`register.spicedb` config block ✅ landed** in `application.conf` (commit `1219827`,
>   2026-07-05): `url = ${?SPICEDB_URL}`, `token = ${?SPICEDB_TOKEN}`,
>   `consistency = ${?SPICEDB_CONSISTENCY}`, `timeoutSeconds = ${?SPICEDB_TIMEOUT_SECONDS}`.
>   No in-file defaults for url/token — fine-grained mode fails closed at startup if unset.
>   **These are now the confirmed env var names for Step 2 §register-helm-values below —
>   no longer a proposal.**
> - **`BootstrapProvisionerSpiceDB` ✅ implemented and wired** (commit `1219827`) — writes
>   `owner_user`/`owner_team` tuples via `WriteRelationships` (`OPERATION_TOUCH`) in
>   fine-grained mode. Unblocks BATS §BOOT once the image is deployed.
> - **server-it T-S1–T-S10 ✅ implemented** (commit `d226d17`, 2026-07-06) — `spicedb` service
>   added to `docker-compose.server-it.yml`, `AuthorizationServiceSpiceDBItSpec` covers all 10 cases.
> - **No app-side code blockers remain.** The only outstanding dependency for the L2 path is
>   operational: **a register image built from current `main` deployed to the cluster.**
>   AUTH-PHASES.md was re-checked and has itself been refreshed to match (as of `85ebbd9`).

---

## Completed

### Phase K — Infrastructure Foundation

- [x] K.1 Local K8s bootstrap (k3d + k3s)
- [x] K.2 Container registry (GHCR + k3d image import)
- [x] K.3 PostgreSQL (Helm chart, SOPS secret, ArgoCD app)
- [x] K.4 Keycloak (Helm chart, realm import, SOPS secret, ArgoCD app)
- [x] K.5 Istio ambient (ztunnel, waypoint, PeerAuthentication STRICT)
- [x] K.6 ArgoCD (root app-of-apps, self-heal, projects)

### L0 — Workspace Capability (capability-only mode)

- [x] `REGISTER_AUTH_MODE=capability-only` in register Helm values
- [x] AuthorizationPolicy: public routes `/w/*`, `/workspaces/*`, `/health`
- [x] OPA `allow.rego`: health + capability routes bypass role checks

### L1 — Identity + Ownership (infra side)

- [x] RequestAuthentication: Keycloak JWT validation, JWKS, audience `register-api`
- [x] AuthorizationPolicy: `requestPrincipals: ["*"]` for protected routes (split into `require-jwt` + `allow-capability-urls`, 2026-07-04)
- [x] EnvoyFilter: strip `x-user-id`, `x-user-email`, `x-user-roles` before JWT validation
- [x] PeerAuthentication: STRICT mTLS per namespace (register, argocd, infra)
- [x] OPA ext_authz: role-based coarse gate, fail-closed, 100ms timeout
- [x] OPA `allow.rego`: viewer write block, admin cache gate, recognized_roles set
- [x] NetworkPolicy: default-deny-all + 15 targeted allow rules (HBONE, waypoint, OPA, DNS, cross-ns)
- [x] CiliumNetworkPolicy: health probe rules (ztunnel SNAT 169.254.7.127/32)
- [x] Kyverno: `inject-seccomp-profile` ClusterPolicy (ADR-INFRA-008)
- [x] Keycloak realm split: dev (`directAccessGrantsEnabled: true`) / prod (`false`)
- [x] Frontend Helm chart + ArgoCD app + NetworkPolicies

### Tests

- [x] 6 bats test suites: header-security, health-probes, mtls-enforcement, network-isolation, opa-authz, pod-security
- [x] 43 OPA unit tests (`tests/opa/allow_test.rego`, 313 lines)
- [x] 8 conftest policies (structural validation of all K8s resource types)
- [x] `run-regression.sh` runner script

### Retired

- [x] ~~waypoint-pss-patch PostSync Job~~ → replaced by Kyverno (ADR-INFRA-008)

---

## L2 Path — Step 0: Pre-SpiceDB Infrastructure Preparation

> **No app-side dependency. Merge anytime.**
> These are additive changes. Completing them before Step 1 reduces that step to
> secret + ArgoCD app only.
>
> Schema blocker resolved: `infra/spicedb/schema.zed` ✅ committed in `register` repo (2026-07-04).
> Per ADR-INFRA-011 and AUTH-PHASES hand-off: register-infra reads this from the `register` checkout.
> Do NOT copy it here.

**§1 — Chart source** ✅
- [x] Official authzed chart (`https://authzed.github.io/helm-charts`) returns HTTP 200 with HTML — no `index.yaml` served, chart does not exist as a usable registry (confirmed 2026-07-05)
- [x] Community chart (`pschichtel/spicedb`) rejected unconditionally — not the primary vendor org (ADR-INFRA-012 §3)
- [x] **Decision: local Helm chart** under `infra/helm/spicedb/` — same pattern as Keycloak, OPA, register, irmin. Container image (`ghcr.io/authzed/spicedb`) is the only external artifact.

**§2 — AppProject extension** ✅
- [x] `batch/Job` added to `infra/argocd/projects/infra.yaml` `namespaceResourceWhitelist` (2026-07-05)

**§3 — PostgreSQL SpiceDB database provisioning** ✅
- [x] DB-init implemented as a **Helm pre-install/pre-upgrade hook** in `infra/helm/spicedb/templates/db-init-job.yaml`
  - Runs before SpiceDB pods start on every `helm upgrade --install`
  - Idempotent SQL: `CREATE DATABASE IF NOT EXISTS`, `CREATE ROLE IF NOT EXISTS`, `GRANT`
  - Reads `postgres-credentials / postgres-password` (superuser) and `spicedb-credentials / db-password` (spicedb_user password)
  - Image: `bitnami/postgresql@sha256:e93732718...` (pre-ADR approved, digest-pinned)
  - Note: `spicedb-credentials` secret must be manually applied before ArgoCD syncs:
    `sops --decrypt infra/secrets/spicedb.enc.yaml | kubectl apply -f -`

**§4 — NetworkPolicy stubs** ✅
- [x] Added to `infra/k8s/network-policy/infra.yaml`: `register→spicedb:8080` ingress, `spicedb→postgresql:5432` egress, kubelet probe CiliumNP on 50051, runner stub (commented, Phase 4)
- [x] Added to `infra/k8s/network-policy/register.yaml`: `register→spicedb:8080` egress (2026-07-05)

---

## L2 Path — Step 1: SpiceDB Running

> **Blocked by**: Step 0 §1 (chart confirmed), Step 0 §3 (DB provisioning Job deployed).
> App-side dependency: none. `register` Wave 3 not needed yet.
> Ref: ADR-INFRA-010, ADR-INFRA-002 (fail-closed availability).

**§secrets**
- [ ] Create `infra/secrets/spicedb.enc.yaml` (SOPS age encryption, same key as `keycloak.enc.yaml`):
  ```yaml
  apiVersion: v1
  kind: Secret
  metadata:
    name: spicedb-credentials   # matches spicedb.credentialsSecretName in values.yaml
    namespace: infra
  stringData:
    preshared-key: "<random ≥32 chars>"
    datastore-uri: "postgresql://spicedb_user:<password>@postgresql.infra.svc.cluster.local:5432/spicedb"
  ```
  - Generate preshared key: `openssl rand -hex 32`
  - Preshared-key constraint (app side, ADR-022/`SpiceDbToken`): printable ASCII, ≤2048 chars — `openssl rand -hex` output satisfies this
  - `spicedb_user` password must match what the DB-init Job sets (use the same value)
  - Encrypt: `sops --encrypt --age "$(grep 'public key' ~/.config/sops/age/keys.txt | awk '{print $4}')" spicedb-plain.yaml > infra/secrets/spicedb.enc.yaml && rm spicedb-plain.yaml`

**§local-chart** ✅ — all files created 2026-07-05
- [x] `infra/helm/spicedb/Chart.yaml`
- [x] `infra/helm/spicedb/values.yaml` (ADR-INFRA-012 T2 approval record, v1.53.0, digest-pinned)
- [x] `infra/helm/spicedb/templates/_helpers.tpl`
- [x] `infra/helm/spicedb/templates/serviceaccount.yaml`
- [x] `infra/helm/spicedb/templates/deployment.yaml`
- [x] `infra/helm/spicedb/templates/service.yaml` (ports 8080 http + 50051 grpc)
- [x] `infra/helm/spicedb/templates/pdb.yaml` (minAvailable: 1, ADR-INFRA-002)
- [x] `infra/helm/spicedb/templates/db-init-job.yaml` (Helm pre-install/pre-upgrade hook)
- [x] `helm lint infra/helm/spicedb` — 0 errors

**§argocd-app** ✅
- [x] `infra/argocd/apps/spicedb.yaml` created — single-source local chart, `project: infra`, `CreateNamespace=false`

**§smoke-test**
- [ ] Verify SpiceDB pods healthy: `kubectl -n infra get pods -l app.kubernetes.io/name=spicedb`
  (label set by `_helpers.tpl` in local chart — same convention as all other charts in this repo)
- [ ] Verify PDB: `kubectl -n infra get pdb`
- [ ] Verify HTTP reachable from register namespace:
  ```bash
  kubectl -n register run -it --rm verify-spicedb --image=curlimages/curl --restart=Never -- \
    curl -si -H "Authorization: Bearer <preshared-key>" \
    http://spicedb.infra.svc.cluster.local:8080/v1/schema/read
  ```
  Expected: `200 OK` with empty or existing schema JSON

---

## L2 Path — Step 2: Schema Applied + App Wired

> **Blocked by**: Step 1 (SpiceDB running).
> **Register app dependency — RESOLVED (re-verified 2026-07-06)**: Wave 3 adapter, the
> `register.spicedb` config block, and `BootstrapProvisionerSpiceDB` are all merged
> (commit `1219827`). No app-side code blocker remains. The only outstanding dependency
> for this step is operational: **a register image built from current `main` deployed**
> to the cluster. `schema.zed` can be applied independently of that.

**§schema**
- [ ] Apply `infra/spicedb/schema.zed` from `register` repo checkout via port-forward:
  ```bash
  kubectl -n infra port-forward svc/spicedb 8080:8080 &
  zed schema write --endpoint localhost:8080 --token <preshared-key> \
    < /path/to/register/infra/spicedb/schema.zed
  # verify
  zed schema read --endpoint localhost:8080 --token <preshared-key>
  ```
  - Do NOT copy schema.zed here — it must stay in the `register` repo (ADR-INFRA-011)
  - Schema is at `register/infra/spicedb/schema.zed` ✅ (committed 2026-07-04)
  - Note: schema includes `permission admin_workspace = owner_user + owner_team->manage_team`
    (added beyond AUTH-PLAN §L2.1 original — required by Wave 5 rotate/delete; AUTH-PHASES Phase 0)

**§register-helm-values**
- [ ] Add to `infra/helm/register/values.yaml` env block:
  ```yaml
  - name: SPICEDB_URL          # confirmed name — application.conf `spicedb.url = ${?SPICEDB_URL}`
    value: "http://spicedb.infra.svc.cluster.local:8080"   # HTTP in-cluster — mesh encrypts
  - name: SPICEDB_TOKEN        # confirmed name — application.conf `spicedb.token = ${?SPICEDB_TOKEN}`
    valueFrom:
      secretKeyRef:
        name: spicedb-preshared-key-register   # copy of preshared key in register namespace
        key: spicedb-preshared-key
  # optional, both have SpiceDbConfig case-class defaults if unset:
  # - name: SPICEDB_CONSISTENCY       # "minimize-latency" (default) | "fully-consistent"
  # - name: SPICEDB_TIMEOUT_SECONDS   # default 10
  ```
  - The secret `spicedb-preshared-key-register` must exist in the `register` namespace:
    create `infra/secrets/spicedb-register.enc.yaml` with the same token value, namespace: register
  - ~~Register app prerequisite: `SpiceDbConfig.url` must accept `http://`~~ → **RESOLVED**:
    `MeshServiceUrl` accepts http/https (Wave 0C ✅, `SpiceDbConfig.scala`)
  - ⚠ No in-file defaults for url/token — if either env var is unset, fine-grained mode
    fails closed at startup (by design, per `application.conf` comment)

**§auth-mode-switch** *(requires Wave 3 deployed image)*
> Valid modes (IMPL-PLAN): `capability-only`, `identity`, `fine-grained`.
> ⚠ **`identity` mode does NOT consult SpiceDB** — it wires `AuthorizationServiceNoOp`
> (AUTH-PLAN: "Wired when register.auth.mode = capability-only or identity").
> The SpiceDB end-to-end demo requires `fine-grained`. Switch in two stages:
- [ ] Stage 1: `REGISTER_AUTH_MODE` `capability-only` → `identity` in `infra/helm/register/values.yaml`
      (JWT required, any authenticated user with the key allowed; SpiceDB not consulted)
- [x] Stage 1 infra impact (Wave 6, landed 2026-07-05) — **corrected 2026-07-06**: the bootstrap
      endpoint's actual path is `POST /workspaces` (exact, no trailing content — "bootstrap" is
      just its internal name, see `WorkspaceLifecycleEndpoints.scala`), not `/workspaces/bootstrap`.
      A `/workspaces/*` prefix rule never matched that exact path, so it was dead weight in
      `allow-capability-urls` and has been removed (`infra/k8s/istio/authorization-policy.yaml`).
      No move to `require-jwt` was needed: that policy's ALLOW rule has no path restriction, so
      `/workspaces` is already covered whenever a valid JWT is presented, matching Wave 6's intent.
      Still verify OPA `allow.rego` does not treat `/workspaces` as a public capability route
      outside capability-only mode.
- [ ] Stage 2: `REGISTER_AUTH_MODE` `identity` → `fine-grained` (SpiceDB consulted on every check)
- [ ] Verify end-to-end (fine-grained): `curl -H "Authorization: Bearer <keycloak-token>" http://<ingress>/w/<key>/risk-trees` → 200 (OPA allows, SpiceDB allows owner)
- [ ] Verify fail-closed: same request without token → denied. ⚠ AUTH-TESTING-PLAN asserts
      **403** for missing/expired JWT (B-L1-2/3, B-FC-2); Istio commonly returns 401 for
      invalid tokens. Verify actual codes and reconcile with the register team if the
      BATS assertions need amending — do not silently change either side

**§seed-relationships** *(for demo + BATS §L2 — must match AUTH-TESTING-PLAN pre-seeded state)*
- [ ] Seed test tuples via port-forward (user IDs are Keycloak `sub` UUIDs):
  ```bash
  zed relationship create workspace:<ws1Id> owner_user user:<aliceSub>   # alice = owner
  zed relationship create workspace:<ws1Id> viewer     user:<carolSub>   # carol = viewer
  zed relationship create risk_tree:<tree1Id> workspace workspace:<ws1Id> # tree→ws inheritance
  # bob: intentionally NO tuples (negative-case user)
  ```
  (Previous plan seeded `editor`/`viewer` only — corrected to match AUTH-TESTING-PLAN §L2:
  owner_user + viewer + tree-inheritance tuple, three users alice/bob/carol)
- [ ] End-to-end curl demo: Keycloak token (owner) → Istio headers → OPA gate (pass) → app → SpiceDB `check(ViewWorkspace/DesignWrite, workspace)` → allow

---

## L2 Path — Step 3: Provisioning Job + CI (K.6)

> **Blocked by**: Step 1 (SpiceDB running).
> These are independent of Wave 3 and can be done in parallel with Step 2.
> Ref: AUTH-PLAN §K.6, AUTH-PHASES Phase 3, **IMPL-PLAN §K.6 Amendment (bidirectional reconcile)**.

- [ ] K.6 authorization graph provisioning job — idempotent write of org/team→workspace
  relationships sourced from a config file in git, with **full bidirectional reconcile**
  (IMPL-PLAN §K.6 Amendment):
  - `to_write = intended − actual`; `to_delete = actual − intended` (orphans = privilege creep)
  - On drift: log each orphaned tuple at WARN with full detail; fail pipeline when
    `strict-drift = true` (default), warn-and-continue otherwise
  - **Scope: team/org relations only** (`editor`, `analyst`, `viewer`, `team_admin`, `org_member`).
    **Never manage `owner_user`/`owner_team`** — those are app-lifecycle-written (Wave 6);
    BATS B-K6-4 asserts the job leaves them untouched
  *For now: manual port-forward invocation; automated via ARC runner in Phase 4 (Step 5).*
- [x] K.6 app service-account write scoping — **decision made 2026-07-06: defer (Option A)**.
  SpiceDB (OSS) has no mechanism to scope a preshared key to specific relations — the
  `owner_user`/`owner_team`-only write restriction in IMPL-PLAN's L2.0 exit criterion is
  enforced today only at the Scala type level (`BootstrapProvisioner` env-narrowing), not by
  SpiceDB itself. For the current phase (local-dev, single operator, no untrusted tenants) a
  single shared preshared key stays as-is; real enforcement is deferred to the Hetzner
  planning item below (Option C). See that item for the full A/B/C option analysis.
- [ ] K.6 CI/CD deployment workflow: Helm-based `helm upgrade --install` for `local-dev` target,
  triggered manually or on `main` push; post-deploy smoke check **must include the header-spoofing
  gate** (B-K5-1–3 — IMPL-PLAN K.6 checklist: "header spoofing test is gated in K.6 CI post-deploy step")

---

## L2 Path — Step 4: BATS Verification

> **Blocked by**: Step 2 fully live. ⚠ §L2/§L2W/§FC require auth mode = **`fine-grained`**
> (not `identity` — see Step 2 §auth-mode-switch) + Wave 3 deployed.
> Wave 6 ✅ landed app-side 2026-07-05 — §BOOT needs the Wave 6 **image deployed**, no longer code.
> Register-side gate: T-U1–T-U7 (Wave 3 mock-adapter unit tests) must pass before §L2/§FC run
> (AUTH-TESTING-PLAN §W3).
> Env var contract for all suites (REGISTER_URL, ALICE_JWT, BOB_JWT, CAROL_JWT, WS1_KEY, WS1_ID,
> TREE1_ID, SPICEDB_URL, SPICEDB_TOKEN + EXPIRED_JWT, WRONG_REALM_JWT for §L1): AUTH-TESTING-PLAN §Prerequisites.
> Ref: AUTH-PHASES Phase 3–4, AUTH-TESTING-PLAN.

- [ ] BATS §L0 (B-L0-1–3): capability-only mode — likely already covered by existing bats suites; verify against AUTH-TESTING-PLAN §L0 test IDs
- [ ] BATS §K5 (B-K5-1–3): header spoofing — likely covered by `header-security.bats`; verify against AUTH-TESTING-PLAN §K5
- [ ] BATS §L1 (B-L1-1–4): identity mode — requires `REGISTER_AUTH_MODE=identity` + Wave 2 image deployed; needs `EXPIRED_JWT` + `WRONG_REALM_JWT` fixtures (second throwaway realm or saved expired token)
- [ ] BATS §L2 / §L2W: fine-grained read/write — requires `fine-grained` mode + Wave 3 deployed + schema applied + seed tuples (owner_user/viewer/tree — Step 2 §seed-relationships)
- [ ] BATS §FC (B-FC-1–3): fail-closed behaviour — requires Wave 3 deployed; SpiceDB unavailable → **403, not 503** (block via NetworkPolicy or scale down during test); B-FC-3 additionally asserts the anonymous sentinel UUID `00000000-…-000000000000` has zero tuples
- [ ] BATS §BOOT (B-BOOT-1–3): bootstrap ownership lifecycle — app-side blocker cleared: `BootstrapProvisionerSpiceDB` is implemented and wired in fine-grained mode (commit `1219827`), writing `owner_user`/`owner_team` tuples via `WriteRelationships`. Only remaining dependency is the image deploy (Step 2)
- [ ] BATS §K6 (B-K6-1–4): drift detection — requires K.6 provisioning job + Wave 3 deployed; B-K6-4 asserts ownership tuples survive a provisioning run
- [ ] All suites pass → authorization-complete gate for any non-dev environment (AUTH-TESTING-PLAN §Completion Criteria)

> ⚠ **BATS passing ≠ L2 usable.** The suites above run via `kubectl port-forward`
> with pre-obtained JWTs (the `REGISTER_URL`/`ALICE_JWT` env contract). They
> exercise the auth *logic* but bypass real external exposure. See Step 5.

---

## L2 Path — Step 5: Usable Exposure (L2 completion blocker)

> The L2 fine-grained rollout **cannot be considered complete** until the
> functionality it gates is actually reachable and usable by a real client —
> not just via port-forward. A user must be able to authenticate and exercise
> every L2 auth feature end-to-end through the front door.

- [x] **Ingress live over HTTPS (local) — DONE + verified from a clean bootstrap (2026-07-08).**
  `register-ingress` Gateway terminates HTTPS on 443; cert-manager self-signed
  `ClusterIssuer` (`infra/k8s/cert-manager/selfsigned-issuer.yaml`) issues the
  `register-ingress-tls` cert; the `world→gateway:443` CiliumNetworkPolicy
  (`network-policy/register.yaml`) admits external traffic; everything else stays
  default-deny. All GitOps-deployed (mesh-policy). Verified: `curl -k https://localhost:8443/`
  → `200` serving the frontend SPA. No plaintext :80. Hetzner still needs the ACME issuer
  (see "Production certificate scheme" below) — that's the only remaining piece of this item.
  Foundation re-verified in the same rebuild: keycloak DB, kyverno, ArgoCD-ambient all green;
  the `register` app deployed from `local/register-server:dev` (⚠ confirm this is built from
  current `main` before trusting L2 behavior — see the operational note at the top of this file).
- [ ] **Production certificate scheme (incremental, do near the end of Hetzner rollout)** —
  replace the self-signed issuer with a best-practice OSS/free scheme: a
  cert-manager **ACME `ClusterIssuer` (Let's Encrypt)** bound to the real domain
  with an HTTP-01 (via the ingress Gateway) or DNS-01 solver, auto-renewing. Not a
  dirty hack — this is the standard cert-manager production pattern. The Gateway,
  `Certificate`, HTTPRoute, and NetworkPolicy do not change; only the issuer swaps
  (see the Multi-Environment Values Overlay item — the issuer is the env-specific piece).
  Optionally add an HTTP→HTTPS 301-redirect listener for browser UX.
- [ ] **Keycloak externally reachable** — a browser/client can reach Keycloak to
  complete the OIDC login and obtain a JWT (today Keycloak is internal-only).
  Requires an ingress route to Keycloak + `KC_HOSTNAME_STRICT`/hostname pinned.
- [ ] **Real end-to-end round-trip** (not port-forward, not a hand-minted token):
  browser → Keycloak login → JWT → `https://<host>/w/<key>/…` → OPA gate →
  SpiceDB fine-grained check → allowed/denied as the schema dictates.
- [ ] Only when the above hold is the L2 path **usable**, not merely test-green.

---

## Open — Phase 3: Hardening (independent of L2 path)

- [ ] **[next teardown cycle]** register↔irmin startup-ordering resilience — register
  self-terminates with `Irmin health check returned false` and CrashLoopBackOffs when it
  starts before mesh-policy has applied the register↔irmin HBONE/NetworkPolicy rules (or
  before irmin's GraphQL is ready). It self-heals on retry once policies land, but the
  crash-loop is noisy and slows every fresh bootstrap. Fix options: an initContainer that
  waits for `irmin:8080` reachability, a longer startup `initialDelaySeconds`, or a bounded
  retry on the irmin health check in the app. Bundle into the next batch so the next
  rebuild verifies register comes up clean without the transient crash-loop.
- [ ] Automated SpiceDB bats test (regression coverage for HTTP reachability + schema load) — can land after Step 1
- [ ] Retire the last PERMISSIVE exception — switch SpiceDB's kubelet health probe from gRPC (:50051) to HTTP on the gateway (:8080), then delete `spicedb-grpc-probe-permissive` from `peer-authentication.yaml`. SpiceDB is accessed over HTTP REST here (no gRPC calls, ADR-INFRA-010), so the gRPC probe — and its PERMISSIVE exception — are avoidable. Every other service is already STRICT + CiliumNP-only (ADR-INFRA-004 §4)
- [ ] Promote PeerAuthentication to mesh-wide STRICT in `istio-system` (currently per-namespace)
- [ ] ResourceQuota per namespace (complement LimitRange with hard caps on CPU/memory/pod count)
- [ ] PSS: upgrade `infra` namespace from baseline enforce → restricted enforce

---

## ⚠ UNDER DESIGN — Multi-Environment Values Overlay (decide before Phase 4)

> **Status: not scoped, not agreed, not started.** This is not part of the original
> AUTH-PLAN/Phase rollout — it surfaced 2026-07-06 while investigating the
> `register-server` image-tag drift bug (see git history on this date) and is recorded
> here so it isn't lost, not because it's been committed to.

**The problem:** every Helm chart with environment-specific values (`register`, `keycloak`,
and eventually `spicedb`) currently has exactly **one** `values.yaml`, hand-edited in place
to hold whatever the current target environment needs (e.g. Keycloak's
`realmFile: "realms/register-realm-dev.json"`, register's `image.pullPolicy: Never`). This
is the same anti-pattern that produced the `register-server:prod`/`local/register-server:dev`
drift: nothing forces the "flip this value when you change environments" step, so it silently
doesn't happen.

**The candidate fix:** split each affected chart's values into a shared base (`values.yaml`)
plus one overlay file per environment (`values-local.yaml`, `values-hetzner.yaml`), with a
separate ArgoCD `Application` per environment/destination layering
`valueFiles: [values.yaml, values-<env>.yaml]`. This generalizes the pattern the repo already
half-uses for Keycloak's realm split, minus the manual-flip failure mode.

**Concrete case that needs this — the TLS ClusterIssuer (added 2026-07-08):**
`infra/k8s/cert-manager/selfsigned-issuer.yaml` is a **self-signed** `ClusterIssuer` for local
dev, but it lives in the shared `infra/k8s/` path that the `mesh-policy` Application syncs to
**every** environment. On Hetzner that would wrongly apply the self-signed issuer instead of the
ACME/Let's Encrypt one (see Step 5 "Production certificate scheme"). The issuer is the only
env-specific piece of the ingress (Gateway/HTTPRoute/Certificate/NetworkPolicy are all shared),
so it is the minimal, concrete driver for this overlay decision: some `infra/k8s/` resources must
be selectable per environment. Until resolved, Hetzner must not blindly sync the self-signed issuer.

**Open questions, not yet decided:**
- [ ] How to make specific `infra/k8s/` resources (starting with the cert-manager ClusterIssuer) environment-selectable — per-env directories + per-env `mesh-policy` Applications, Kustomize overlays, or excluding env-specific resources from the shared glob.
- [ ] Scope: just `register` + `keycloak` (the two charts with real env-specific values today), or every chart pre-emptively?
- [ ] Whether this needs a second ArgoCD instance on the Hetzner cluster (pointed at the same repo, different values/destination) or one ArgoCD instance managing both clusters via `destination.server`
- [ ] Whether to land this **before** Phase 4 starts (clean split from day one) or **as part of** Phase 4 (Hetzner forces the split anyway, so do it once)
- [ ] Draft as an ADR-INFRA before implementing — this changes how every future environment-specific value gets added, not just a one-time fix

---

## ⚠ UNDER DESIGN — SpiceDB Write-Scoping Enforcement (elaborate before Phase 4)

> **Status: decision made for now (defer), real enforcement not yet planned.** Surfaced
> 2026-07-06 while reviewing the K.6 app service-account scoping requirement. Recorded here
> so the deferral doesn't quietly become permanent by default.

**The problem:** SpiceDB (OSS/self-hosted) has no mechanism to scope a preshared key to a
subset of relations or operations — a valid key grants full read/write access to the entire
API. This conflicts with IMPL-PLAN's L2.0 exit criterion, which calls for the register app's
credential to write **only** `owner_user`/`owner_team` on `workspace`, and the K.6
provisioning job's credential to write everything *except* those two relations (BATS
B-K6-4). Neither restriction is enforceable by SpiceDB itself today; the only real boundary
is Scala-level (`BootstrapProvisioner` env-narrowing in the app), which doesn't survive a
compromised process holding the shared token.

**Options considered (2026-07-06 analysis):**
- **A — Defer (chosen for now):** keep the single shared preshared key. Zero engineering
  cost; matches ADR-INFRA-010; acceptable while this is local-dev, single-operator, no
  untrusted tenants. Accepted risk: a compromised register-server or runner pod can write
  arbitrary SpiceDB relations, not just the ones it's supposed to.
- **B — Multiple preshared keys** (one for the app, one for the CI/runner): cheap
  (one more SOPS secret + Helm value), but provides isolation-of-exposure on leak, **not**
  actual least-privilege — both keys remain equally privileged over the whole API. Do not
  present this as satisfying the exit criterion if it's ever implemented.
- **C — Enforcement gateway (candidate for Hetzner):** an OPA/Envoy ext_authz gate fronting
  SpiceDB's service, keyed to mesh workload identity (SPIFFE, not a bearer token), inspecting
  `WriteRelationships` payloads against an allow-list per caller identity. This is the only
  option that provides real least-privilege, and reuses the K.5 OPA-ext_authz pattern this
  repo already has for the register API. Real cost: a new waypoint, a new OPA policy +
  its own test suite, latency on every SpiceDB write, and an ongoing obligation to keep the
  allow-list in lockstep with `schema.zed`.

**Decision:** **A for now.** C is the leading candidate for real enforcement, but is
**not yet planned** — no ADR, no design, no sizing.

**Open questions, not yet decided:**
- [ ] Draft as an ADR-INFRA before implementing Option C
- [ ] Confirm Option C is actually warranted at Hetzner scale (single-operator prod vs. genuinely multi-tenant) before committing the engineering cost
- [ ] If C is deferred again at that point, reword the IMPL-PLAN L2.0 exit criterion (register repo) to stop claiming credential-level scoping that doesn't exist — an inaccurate exit criterion is worse than an honest gap
- [ ] Whether Option B is worth doing as a cheap interim step regardless of the A vs. C timeline (isolation-of-exposure, not access control)

---

## Open — Phase 4: Hetzner Migration (K.7)

> **Note**: K.6 ARC runner (schema apply automation) is part of this phase.
> Until ARC is live, schema apply is manual port-forward (Step 2 §schema above).

- [ ] Istio Gateway + HTTPRoute (requires domain name + DNS A record + cert-manager ClusterIssuer)
- [ ] `KC_HOSTNAME_STRICT=true` (currently false; pin when external hostname is stable)
- [ ] Terraform remote state (S3-compatible backend for multi-operator / CI access)
- [ ] Keycloak realm switch (`realmFile: realms/register-realm-prod.json` in Keycloak Helm values)
- [ ] SpiceDB TLS: switch from HTTP to HTTPS with cert-manager cert + JVM trust injection once a
  real PKI exists (ADR-INFRA-010). App side needs no type change — `MeshServiceUrl` already
  accepts https; for internet-facing (non-mesh) endpoints the app would use `SecureUrl` instead
- [ ] ARC controller + runner namespace (CI automation for SpiceDB schema lifecycle, ADR-INFRA-011)
- [ ] Runner NetworkPolicy (scoped egress to `spicedb:50051` for `zed` CLI gRPC)
- [ ] YubiKey dual-recipient SOPS (add second recipient to `.sops.yaml` + re-encrypt all secrets)

---

## Deferred — Blocked on App-Side Changes

- [ ] `infra/secrets/register-db.enc.yaml` — **UNBLOCKED 2026-07-05**: `WorkspaceStorePostgres.scala` exists and `workspaceStore.backend = "postgres"` is an accepted config value (`REGISTER_WORKSPACE_STORE_BACKEND`); Flyway + `REGISTER_DB_USER`/`REGISTER_DB_PASSWORD`/`REGISTER_DB_NAME` env hooks are in `application.conf`. Create the secret + Helm values when switching the backend (ADR-INFRA-006)
- [ ] Chainsaw test framework — deferred; OPA unit tests + bats + conftest cover the same assertions (ADR-INFRA-005)
- [ ] CI workflows (`.github/workflows/ci.yaml`, `regression.yaml`) — create when GitHub Actions CI is set up (ADR-INFRA-005)

---

## Open — Housekeeping

- [ ] **Bootstrap doc restructure (supersedes the "Hetzner doc parity" chore)** — the
  bootstrap has three parts: ① provision a cluster (env-specific: k3d vs Terraform),
  ② install the platform layer (Cilium → Istio ambient → cert-manager → ArgoCD +
  ambient accommodations → SOPS secrets → repo → waypoint — **identical** across envs),
  ③ GitOps rollout (root app-of-apps — **identical**). Today ②+③ are duplicated in
  `LOCAL-K3D-BOOTSTRAP.md` and `K3S-GITOPS-BOOTSTRAP.md`, which is why they drift (local
  got the ArgoCD-ambient + kube-proxy fixes; Hetzner didn't). Restructure into **one
  shared "platform bootstrap + GitOps rollout" doc + two thin "provision a cluster"
  prefixes**, with a short "environment differences" table (cert issuer self-signed↔ACME,
  `secrets-encryption`, `KC_HOSTNAME_STRICT`, realm dev/prod, image build vs registry pull).
  Land it **with** the Multi-Environment Values Overlay decision — same "shared vs per-env"
  problem. Doc-only (no teardown needed).
- [ ] **Observability namespace**: `infra/helm/namespaces/values.yaml` declares an `observability` namespace with no ArgoCD app, no ADR, and no workloads. Review `docs/` and the `register` repo docs to determine scope, then either remove it (YAGNI) or link it to a concrete ADR and deployment plan. Input from register docs: the app exports OTLP (`OTEL_EXPORTER_OTLP_ENDPOINT`, default `localhost:4317`) and Wave 3 adds `authz.check.total` / `authz.check.latency_ms` metrics — an OTel collector + backend would give the SpiceDB rollout observability from day one.
- [ ] **Cross-repo status alignment**: done 2026-07-04; re-run 2026-07-05 against code (found AUTH-PHASES.md stale); **re-run 2026-07-06 — all three flagged app-side blockers confirmed resolved in code** (`register.spicedb` block, `BootstrapProvisionerSpiceDB`, server-it T-S1–T-S10), and AUTH-PHASES.md itself has since been refreshed to match (`85ebbd9`). **No app-side code blocker remains on the L2 critical path** — only an image deploy. Next re-run trigger: register image deployed to cluster (then re-verify Step 2 §auth-mode-switch status codes and Step 4 BATS suites live).

---

## Operational Notes

- **After-sleep recovery**: the k3d cluster may need `scripts/post-sleep-recover.sh` after laptop suspend. Run it before testing if pods are in CrashLoopBackOff or waypoint is unhealthy.
- **Conftest**: 880 assertions across 8 policies. Run `./tests/run-regression.sh --static-only` for offline validation.
- **Live tests**: `bats tests/bats/` requires a running cluster with the waypoint healthy.
