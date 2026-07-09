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
- [x] AuthorizationPolicy: public routes `/w/*`, `/workspaces` (exact bootstrap path — corrected 2026-07-09; a `/workspaces/*` prefix rule never matched `POST /workspaces`), `/health`
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

**§test-personas** *(new 2026-07-08 — precondition for §seed-relationships below)*
> **Insight:** OPA's coarse role gate (`allow.rego` `recognized_roles :=
> {"analyst", "editor", "viewer", "team_admin"}`) is **mode-agnostic** — always
> enforced, regardless of `REGISTER_AUTH_MODE`. This means alice/bob/carol
> (AUTH-TESTING-PLAN's fine-grained personas) need *some* recognized Keycloak
> role each purely to clear OPA before ever reaching SpiceDB — their **SpiceDB
> relationship**, not their Keycloak role, is the actual thing under test.
> This is a *different axis* from the existing `demo-editor`/`demo-analyst`/
> `demo-viewer`/`demo-admin` realm users, which test OPA's Layer 1 role gate
> specifically. No redesign needed — alice/bob/carol are a standard, valid
> ReBAC test-persona set (owner / viewer / no-relation), same convention
> SpiceDB's own docs use. The gap is purely that the accounts don't exist yet.
- [ ] Add 3 users to `infra/helm/keycloak/realms/register-realm-dev.json`: `alice`,
  `bob`, `carol` — each with a baseline recognized role (e.g. `viewer`) sufficient
  to clear the OPA gate. Their SpiceDB relationship (below) is what actually varies.
- [ ] Record each user's Keycloak `sub` (UUID) — required for both SpiceDB
  relationship tuples and the BATS `ALICE_JWT`/`BOB_JWT`/`CAROL_JWT`/`*_SUB` env contract

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
  *For now: manual port-forward invocation. Verified 2026-07-08: `.github/workflows/` only has
  Terraform CI (unrelated); the register app repo has no CI at all; a GitHub-hosted runner has
  no network path to a local k3d cluster regardless. So "wire to CI" is not a dependency gap —
  it correctly comes after the Phase 4 ARC self-hosted runner exists, not before.*
  - [ ] **Design session (guided)**: walk through, interactively, before implementing —
    the config file schema for "intended state" (org→team→workspace assignments), the
    implementation approach (bash+`zed` CLI vs. a small Go/Python tool), where org/team
    membership data originates from, and how the job gets invoked locally pre-CI. Options,
    engineering trade-offs, and best practices to be presented for a joint decision, not
    picked unilaterally by the agent.
- [x] K.6 app service-account write scoping — **decision made 2026-07-06: defer (Option A)**.
  SpiceDB (OSS) has no mechanism to scope a preshared key to specific relations — the
  `owner_user`/`owner_team`-only write restriction in IMPL-PLAN's L2.0 exit criterion is
  enforced today only at the Scala type level (`BootstrapProvisioner` env-narrowing), not by
  SpiceDB itself. For the current phase (local-dev, single operator, no untrusted tenants) a
  single shared preshared key stays as-is; real enforcement is deferred to the Hetzner
  planning item below (Option C). See that item for the full A/B/C option analysis.
- [ ] K.6 CI/CD deployment workflow — **corrected 2026-07-08**: cannot be real CI/CD against
  `local-dev` (GitHub-hosted runners have no network path to a local k3d cluster). Split:
  - [ ] Now: a manually-invoked `helm upgrade --install` + smoke-check script (same shape as
    the provisioning job above), including the header-spoofing gate (B-K5-1–3 — IMPL-PLAN
    K.6 checklist: "header spoofing test is gated in K.6 CI post-deploy step")
  - [ ] Real CI/CD (build+test on every push, deploy-on-merge): lands against **Hetzner**
    once it's reachable — GitHub-hosted runners *can* reach a public Hetzner IP, so this is
    achievable there without waiting for the ARC self-hosted runner. See Phase 4a.

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
- [ ] **Production certificate scheme — decided 2026-07-08, execute as Phase 4b** (after
  Phase 4a bare-IP rollout, see Phase 4 below). Domain: **risquanter.com** (already owned,
  registered at a local provider that operates via **support tickets** — DNS changes are
  manual/slow, not self-service or API-driven). Hostname: **register.risquanter.com**.
  DNS stays at the registrar (simplest, no reason to delegate elsewhere).
  - **HTTP-01, not DNS-01** — chosen specifically because of the support-ticket DNS friction:
    HTTP-01 needs the A record set **once** (one support ticket), then Let's Encrypt's
    automatic challenge/renewal needs no further DNS involvement ever. DNS-01 would need a
    TXT record change (another support ticket) on every renewal cycle — operationally bad
    fit here. Revisit only if a wildcard cert is ever needed.
  - Replace the self-signed issuer with a cert-manager **ACME `ClusterIssuer` (Let's
    Encrypt)** — free, no cost, standard cert-manager production pattern. The Gateway,
    `Certificate`, HTTPRoute, and NetworkPolicy do **not** change; only the issuer swaps
    (see the Multi-Environment Values Overlay item — the issuer is the env-specific piece).
  - [ ] Submit support ticket: A record `register.risquanter.com` → Hetzner server's public IP
  - [ ] Swap `infra/k8s/cert-manager/` `ClusterIssuer` from `selfsigned-local` to an ACME
    issuer (HTTP-01 solver via the existing ingress Gateway)
  - [ ] Verify: `curl https://register.risquanter.com/` gets a browser-trusted cert, no `-k` needed
  - Optionally add an HTTP→HTTPS 301-redirect listener for browser UX.
- [ ] **Keycloak externally reachable** — a browser/client can reach Keycloak to
  complete the OIDC login and obtain a JWT (today Keycloak is internal-only).
  Requires an ingress route to Keycloak + `KC_HOSTNAME_STRICT`/hostname pinned.
  Hostname not yet decided (e.g. a subdomain under risquanter.com) — follows the same
  bare-IP-first (Phase 4a) → real-hostname (Phase 4b) split as the register app once chosen.
- [ ] **Real end-to-end round-trip** (not port-forward, not a hand-minted token):
  browser → Keycloak login → JWT → `https://<host>/w/<key>/…` → OPA gate →
  SpiceDB fine-grained check → allowed/denied as the schema dictates.
- [ ] Only when the above hold is the L2 path **usable**, not merely test-green.

---

## Open — Phase 3: Hardening (independent of L2 path)

- [x] register↔irmin startup-ordering resilience — **app-side fix landed** (register repo,
  2026-07-09): `StartupReadiness.awaitReady` gate — jittered exponential backoff capped at
  5s, bounded by `IRMIN_HEALTHCHECK_BUDGET` (total elapsed budget, default 45s in-app),
  fail-closed after the budget. See register's ADR-031 (startup readiness vs request-path
  resilience) and NOTES.md. `infra/helm/register/values.yaml` now sets
  `IRMIN_HEALTHCHECK_BUDGET=90s` — a conservative initial estimate (2x the app default) for
  full fresh-cluster bootstrap, not yet empirically measured against this cluster.
  - [ ] **[next teardown cycle]** Verify on a real rebuild: register should retry and
    recover instead of crash-looping while mesh-policy/irmin converge. If the crash-loop is
    gone but takes noticeably long, or if it still crash-loops (budget too short), tune
    `IRMIN_HEALTHCHECK_BUDGET` accordingly and record the observed reconcile time here.
- [ ] Automated SpiceDB bats test (regression coverage for HTTP reachability + schema load) — can land after Step 1
- [ ] Retire the last PERMISSIVE exception — switch SpiceDB's kubelet health probe from gRPC (:50051) to HTTP on the gateway (:8080), then delete `spicedb-grpc-probe-permissive` from `peer-authentication.yaml`. SpiceDB is accessed over HTTP REST here (no gRPC calls, ADR-INFRA-010), so the gRPC probe — and its PERMISSIVE exception — are avoidable. Every other service is already STRICT + CiliumNP-only (ADR-INFRA-004 §4)
- [ ] Promote PeerAuthentication to mesh-wide STRICT in `istio-system` (currently per-namespace)
- [ ] ResourceQuota per namespace (complement LimitRange with hard caps on CPU/memory/pod count)
- [ ] PSS: upgrade `infra` namespace from baseline enforce → restricted enforce

---

## ✅ DECIDED — Multi-Environment Values Overlay (ADR-INFRA-014; implement before Phase 4b)

> **Status: decided 2026-07-08, not yet implemented.** Full reasoning and rejected
> alternatives in [ADR-INFRA-014](adr/ADR-INFRA-014.md). Surfaced 2026-07-06 while
> investigating the `register-server` image-tag drift bug — not part of the original
> AUTH-PLAN/Phase rollout.

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

> **Timing clarified 2026-07-08**: Phase 4a (Hetzner, bare IP) can reuse the *same*
> self-signed issuer as local — no collision yet, since neither environment needs ACME.
> The collision only becomes real at the **4a→4b transition**, when Hetzner needs ACME
> while local still needs self-signed. This decision must land before Phase 4b (the
> DNS/cert step), not before Phase 4a — narrows the "before vs. as part of Phase 4"
> question below to specifically "before Phase 4b."

**Decided (ADR-INFRA-014):**
- [x] Resource-selectability mechanism: **Option A — directory split** (`infra/k8s/shared/` +
  `infra/k8s/local/` + `infra/k8s/hetzner/`), not Kustomize, not an ad-hoc carve-out. Mirrors
  the same "shared base + per-env overlay" model chosen for Helm charts — one consistent
  pattern repo-wide instead of a different answer per file type.
- [x] Scope: `register`, `keycloak`, `frontend`, `irmin` charts (surveyed all 7 charts;
  these 4 have real environment-coupled values today — image provenance/pull policy,
  hostname, realm file). `opa` and `spicedb` pull digest-pinned registry images identically
  in both environments and need no overlay (SpiceDB will need one later for its TLS URL
  scheme once Hetzner gets real PKI — tracked in Phase 4a).
- [x] **Two independent ArgoCD instances**, one per cluster, neither registered as a remote
  cluster in the other — no live credential ever crosses the boundary (mirrors ADR-INFRA-011's
  rejection of exported kubeconfigs for CI). Every `Application.spec.destination.server` stays
  `https://kubernetes.default.svc` in both. Consequence: `mesh-policy` becomes two Applications
  (one per cluster's ArgoCD instance), each syncing `infra/k8s/shared` + its own `infra/k8s/<env>`.

**Implementation checklist (not started):**
- [ ] Split `infra/k8s/` into `shared/` (11 of today's 12 files) + `local/cert-manager/` +
  `hetzner/cert-manager/` (per ADR-INFRA-014 §3)
- [ ] Convert `register`, `keycloak`, `frontend`, `irmin` charts to `values.yaml` +
  `values-local.yaml` (extract today's local-only settings) — `values-hetzner.yaml` follows
  once Hetzner specifics are known (Phase 4)
- [ ] Bootstrap Hetzner's own ArgoCD instance (Phase 4a) — see "Bootstrap doc restructure"
  housekeeping item for the shared platform-bootstrap doc this should follow
- [ ] Update `infra/argocd/apps/mesh-policy.yaml` to multi-source (`infra/k8s/shared` +
  `infra/k8s/local`) on the local instance; create the Hetzner-instance equivalent pointing
  at `infra/k8s/shared` + `infra/k8s/hetzner` when Phase 4a starts

---

## ✅ DECIDED — SpiceDB Write-Scoping Enforcement (ADR-INFRA-015; implement before Phase 4b)

> **Status: decided 2026-07-08, not yet implemented.** Full reasoning and rejected
> alternatives in [ADR-INFRA-015](adr/ADR-INFRA-015.md). Surfaced 2026-07-06 while
> reviewing the K.6 app service-account scoping requirement.

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

**Decided (ADR-INFRA-015): B + C.** Separate preshared keys per calling component
(register-server vs. the K.6 runner) *and* an OPA/Envoy ext_authz gateway fronting
SpiceDB, enforcing a per-workload-identity relation-type allowlist on writes. Reasoning:
the product's three trust layers (public/Layer 0, small-team/Layer 1, enterprise/Layer 2)
share one SpiceDB backend on Hetzner — a compromise of the Layer-0-facing app must not
reach Layer-2 org/team relations. Known, accepted residual gap: this scopes *which
relation types* a caller may write, not *which specific resource instances* — a full RCE
compromise of register-server can still forge `owner_user` on an arbitrary workspace
(any workspace, not just its own). Closing that further was evaluated and rejected (see
ADR-INFRA-015 "Alternatives Rejected" — it would require re-implementing
`BootstrapProvisioner`'s own correctness logic a second time in Rego). B+C substantially
reduces blast radius from "full authorization-graph takeover" to "workspace-ownership
forgery + broad read access" — it does not reduce it to zero, and is not a substitute
for hardening register-server against compromise in the first place.

**Implementation checklist (not started):**
- [ ] Create `infra/secrets/spicedb-register.enc.yaml` and `runner-spicedb-token.enc.yaml`
  (the latter's path already planned in ADR-INFRA-011 §4) — separate preshared keys
- [ ] Update `infra/helm/spicedb/values.yaml`/`spicedb.enc.yaml` to a comma-joined
  `preshared-key` covering both callers
- [ ] Deploy a waypoint for the `infra` namespace (does not exist yet — only `register` has one)
- [ ] Build `infra/k8s/opa/spicedb-write-gate.yaml` (EnvoyFilter) + `spicedb_write_gate.rego`
  (per-identity relation allowlist) + its unit test suite
- [ ] Resolve the HTTP-vs-gRPC body-inspection question (register-server calls SpiceDB over
  HTTP/8080, the runner over gRPC/50051 per ADR-INFRA-011 §3 — flagged as an open
  implementation detail in ADR-INFRA-015, not yet solved)
- [ ] If this is ever deferred again in practice, reword the IMPL-PLAN L2.0 exit criterion
  (register repo) to stop claiming credential-level scoping that doesn't exist

---

## Open — Phase 4: Hetzner Migration (K.7)

> **Gate — decided 2026-07-08: Phase 4 does not start until L2 Path Steps 1–4 are
> complete and verified locally** (Step 5 "Usable Exposure" passing against the local
> cluster). Provisioning real paid infrastructure before local fine-grained auth actually
> works would mean debugging L2 issues on Hetzner instead of localhost — strictly worse.
>
> **Sequencing — decided 2026-07-08**: two sub-phases. **4a** stands up Hetzner reachable
> by bare IP only, with the **full GitOps aim from day one** (not a shortcut skipped because
> it's IP-only) — this is where nearly everything below lives. **4b** is the short,
> DNS/certificate-only follow-up once a domain is pointed at it (see Step 5 "Production
> certificate scheme" for the concrete plan — domain, hostname, and DNS approach are
> already decided). Domain (risquanter.com) is already owned; nothing about 4a depends on it.

### Phase 4a — Hetzner, bare IP, full GitOps

> **Note**: K.6 ARC runner (schema apply automation) is part of this phase.
> Until ARC is live, schema apply is manual port-forward (Step 2 §schema above).
>
> Real CI/CD (build+test on push, deploy on merge) becomes achievable here — unlike
> local-dev, GitHub-hosted runners *can* reach a public Hetzner IP. See Step 3's K.6
> CI/CD item.

- [ ] Istio Gateway + HTTPRoute + **self-signed** `ClusterIssuer` reachable via the
  server's bare public IP — same pattern already built and verified for local dev
  (`infra/k8s/istio/ingress-gateway.yaml`, `selfsigned-issuer.yaml`). No domain needed yet.
- [ ] `KC_HOSTNAME_STRICT=true` — can pin to the bare IP initially; revisit once Keycloak's
  own external hostname is decided (Step 5 "Keycloak externally reachable")
- [ ] Terraform remote state (S3-compatible backend for multi-operator / CI access)
- [ ] Keycloak realm switch (`realmFile: realms/register-realm-prod.json` in Keycloak Helm values)
- [ ] SpiceDB TLS: switch from HTTP to HTTPS with cert-manager cert + JVM trust injection once a
  real PKI exists (ADR-INFRA-010). App side needs no type change — `MeshServiceUrl` already
  accepts https; for internet-facing (non-mesh) endpoints the app would use `SecureUrl` instead
- [ ] ARC controller + runner namespace (CI automation for SpiceDB schema lifecycle, ADR-INFRA-011).
  **Not the same thing as the YubiKey below** — the YubiKey secures git commit signing / SOPS
  decryption (who you are), it does not give a workflow network access to the cluster (what a
  runner needs). ARC solves reachability by living *inside* the cluster; no kubeconfig ever
  leaves it (ADR-INFRA-011's explicit reasoning for rejecting the "export kubeconfig to GH
  Secrets" alternative).
- [ ] Runner NetworkPolicy (scoped egress to `spicedb:50051` for `zed` CLI gRPC)
- [ ] YubiKey dual-recipient SOPS (add second recipient to `.sops.yaml` + re-encrypt all secrets)
  — you already have a YubiKey provisioned for GitHub read/write; confirm it's usable as an
  `age-plugin-yubikey` SOPS recipient alongside `sops-age-key` (see `SOPS-YUBIKEY-MODEL.md`)

### Phase 4b — DNS + real certificate (see Step 5 for the full plan)

- [ ] Submit support ticket: A record `register.risquanter.com` → Hetzner public IP
- [ ] Swap `ClusterIssuer` from self-signed to ACME/Let's Encrypt (HTTP-01) — requires the
  Multi-Environment Values Overlay decision above (self-signed for local, ACME for Hetzner)
- [ ] Verify browser-trusted HTTPS, no `-k`/cert warnings

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
