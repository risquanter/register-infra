# Testing Infrastructure

> Security-aware regression pipeline for the register-infra platform.

## Overview

The test pipeline validates the full security stack across four phases,
mapping to the three defence layers (L0 Network/mTLS, L1 Identity/AuthN,
L2 AuthZ) plus cross-cutting hardening concerns.

```
Phase 1 — Conftest     static YAML policy checks (no cluster)
Phase 2 — OPA unit     authorization policy logic  (no cluster)
Phase 3 — Trivy        config + compliance scans   (3a static, 3b live)
Phase 4 — Bats         live cluster assertions      (cluster required)
```

### Layer ↔ Phase Coverage Matrix

|                          | Phase 1 Conftest | Phase 2 OPA | Phase 3 Trivy | Phase 4 Bats |
|--------------------------|:---:|:---:|:---:|:---:|
| **L0 — Network / mTLS** | ✓ PeerAuth, NetworkPolicy, CiliumNP | — | ✓ NSA 2.0 pod/ns selectors | ✓ SPIFFE, ztunnel, connectivity |
| **L1 — Identity / AuthN** | ✓ RequestAuth, EnvoyFilter | — | — | ✓ JWT accept/reject, header stripping |
| **L2 — AuthZ**           | ✓ AuthorizationPolicy | ✓ 43 tests (public routes, role gates, viewer deny, admin cache) | — | ✓ OPA ext_authz live behaviour |
| **Hardening**            | — | — | ✓ PSS baseline, NSA framework, KSV misconfigs | ✓ non-root, readOnlyFS, hostNS, probes |

---

## Prerequisites

All tools run on **Debian 12+** (tested on Debian 13 trixie, amd64).
The same tools work identically in CI containers.

### Required Tools

| Tool | Version | Purpose | Install |
|------|---------|---------|---------|
| **bats-core** | ≥ 1.10 | Live cluster test runner | `sudo apt install bats` |
| **conftest** | ≥ 0.55 | Static YAML policy checks | See below |
| **opa** | ≥ 1.0 | OPA unit test runner | See below |
| **trivy** | ≥ 0.60 | Security scanning (static + live) | See below |
| kubectl | ≥ 1.28 | Cluster interaction (bats + Trivy k8s) | Pre-installed |
| curl | any | HTTP probing (bats) | Pre-installed |
| jq | ≥ 1.6 | JSON parsing | Pre-installed |

### Tool Installation (Debian)

```bash
# bats-core (Debian package)
sudo apt install bats

# OPA (static binary)
OPA_VERSION=1.4.2
curl -L -o /tmp/opa \
  "https://openpolicyagent.org/downloads/v${OPA_VERSION}/opa_linux_amd64_static"
sudo install /tmp/opa /usr/local/bin/opa

# conftest (static binary)
CONFTEST_VERSION=0.58.0
curl -L "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz" \
  | tar xz -C /tmp conftest
sudo install /tmp/conftest /usr/local/bin/conftest

# Trivy (official install script)
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
  | sh -s -- -b /tmp/trivy-bin
sudo install /tmp/trivy-bin/trivy /usr/local/bin/trivy
```

### Cluster Requirement

Phases 3b and 4 require a running Kubernetes cluster (k3d local or
remote). Phases 1, 2, and 3a run without any cluster.

---

## Running Tests

### Full Pipeline

```bash
# Strict mode (default) — fails on skips + failures
./tests/run-regression.sh

# Allow skips — for feature branches or partial environments
./tests/run-regression.sh --allow-skip
```

### Selective Phases

```bash
# Static only (Phases 1 + 2 + 3a) — no cluster needed
./tests/run-regression.sh --static-only

# Bats only (Phase 4)
./tests/run-regression.sh --bats-only

# Skip Trivy entirely
./tests/run-regression.sh --no-trivy
```

### Individual Phase Runs

```bash
# Conftest against a single manifest
conftest test infra/k8s/istio/peer-authentication.yaml \
  -p tests/conftest/policy

# OPA unit tests
opa test infra/helm/opa/policies tests/opa -v

# Trivy static config scan
trivy config infra/ --severity HIGH,CRITICAL

# Trivy live compliance
trivy k8s --compliance k8s-pss-baseline-0.1 \
  --include-namespaces register,infra --report summary

# Bats (all suites)
bats --tap tests/bats/

# Bats (single suite)
bats tests/bats/mtls-enforcement.bats
```

---

## Exit Codes

| Code | Meaning |
|:----:|---------|
| `0`  | All tests passed |
| `1`  | One or more test phases failed |
| `2`  | Tests were skipped and `--strict` mode is active (default) |

---

## Test Suites

### Phase 1 — Conftest Static Policies

| Policy File | Targets | Checks |
|-------------|---------|--------|
| `peerauthentication.rego` | peer-authentication.yaml | STRICT mode, no DISABLE, PERMISSIVE only on known health ports |
| `authorizationpolicy.rego` | authorization-policy.yaml | ALLOW action, no DENY on identity headers |
| `requestauthentication.rego` | request-authentication.yaml | Issuer present, JWKS URI set |
| `envoyfilter.rego` | envoy-filter-strip-headers.yaml | Header strip filter exists |
| `networkpolicy.rego` | network-policy/*.yaml | Default deny, port restrictions, selector presence |
| `ciliumnetworkpolicy.rego` | network-policy/*.yaml | CIDR 169.254.7.127/32 restriction, port count, no fromEntities:world |
| `keycloak-realm.rego` | realms/register-realm-prod.json | ROPC disabled, implicit flow off, sslRequired, required roles present |
| `kyvernopolicy.rego` | kyverno/inject-seccomp-profile.yaml | failurePolicy=Ignore, seccomp RuntimeDefault, scoped to register ns |

### Phase 2 — OPA Unit Tests

43 tests in `tests/opa/allow_test.rego` covering:

- Health endpoint bypass (`/health`)
- Layer 0 public route bypass (`/w/*`, `/workspaces` — no identity required; OPA matches the first path segment, so this covers the exact bootstrap path `POST /workspaces`)
- Role-based access for `analyst`, `editor`, `viewer`, `team_admin`
- Viewer read allowed, viewer write protection (POST/PUT/PATCH/DELETE denied)
- Admin-only cache management gate
- Unauthenticated request denial on protected routes (default deny)
- Unknown/unrecognised role rejection
- Header-based input tests (primary mesh wire format)
- THREAT-CATALOG L1 deny-integration tests (deny rules flow through allow)
- Edge cases (empty roles, missing realm_access, multi-role)

### Phase 3 — Trivy Security Scans

**3a — Static config scan** (`trivy config infra/`):
Scans all manifests and Helm charts for HIGH/CRITICAL misconfigurations.
Known exceptions are filtered automatically:

| ID | Severity | Description | Justification |
|----|----------|-------------|---------------|
| KSV-0053 | HIGH | deployer Role pods/exec | Required for GitOps troubleshooting |
| KSV-0056 | HIGH | deployer Role network management | Required for NetworkPolicy deployment |

Any finding **not** in this exception list causes a hard failure.

**3b — Live compliance scans** (`trivy k8s --compliance`):

| Framework | Gate Type | Expected |
|-----------|-----------|----------|
| PSS Baseline (`k8s-pss-baseline-0.1`) | Hard gate — 0 failures required | 11/11 PASS |
| NSA Hardening (`k8s-nsa-1.0`) | Soft — 1 known exception tolerated | ~23 PASS, 1 known FAIL |

NSA known exceptions (counted as FAIL):
- **4.1** LimitRange — Trivy flags individual pods without explicit resource limits
  (LimitRange defaults apply but Trivy doesn't detect this)

NSA manual controls (status `—`, not counted as PASS or FAIL):

Trivy cannot programmatically verify these controls and marks them as
*Manual*. They are excluded from pass/fail tallies automatically.

| ID | Control | Our Status | Notes |
|----|---------|:----------:|-------|
| **3.0** | Use CNI plugin that supports NetworkPolicy API | **OK** | Cilium is our CNI; supports NetworkPolicy + CiliumNetworkPolicy |
| **5.0** | Control plane disable insecure port | **OK** | k3s does not expose insecure API port (--insecure-port is removed since K8s 1.24) |
| **6.0** | Ensure kube config file permission | **OK** | k3d manages kubeconfig; file permissions are 0600 by default |
| **8.0** | Audit policy is configured | **N/A** | k3d local dev cluster; audit logging not configured (acceptable for dev) |

### Phase 4 — Bats Live Tests

| Suite | Tests | Layer | Key Checks |
|-------|:-----:|-------|------------|
| `header-security.bats` | 17 | L1+L2 | Envoy filter chain, JWT accept/reject, header stripping, C1 guard |
| `mtls-enforcement.bats` | 14 | L0 | PeerAuth STRICT, SPIFFE enrollment, PERMISSIVE exceptions |
| `network-isolation.bats` | 23 | L0 | Default-deny, HBONE, per-service, CiliumNP, negative tests |
| `opa-authz.bats` | 19 | L2 | OPA infra, public routes, auth/unauth, viewer deny, admin gate |
| `health-probes.bats` | 12 | L0+hardening | Readiness, health endpoints, probe config, port isolation |
| `pod-security.bats` | 15 | Hardening | automount, non-root, readOnlyFS, hostNS, LimitRange |
| `spicedb.bats` | 10 | L2 | SpiceDB health/PDB, register wiring (secret + env), live mesh probe (HTTP gateway through HBONE), schema loaded, wrong-key rejection |

#### Trivy Overlap

Tests in `pod-security.bats` are marked with `# TRIVY-OVERLAP` comments
where Trivy compliance scans cover the same control. These tests provide
defence-in-depth (Trivy validates posture, bats validates live state)
and are candidates for removal if redundancy is deemed undesirable.

#### Skip Behaviour

Some bats tests skip gracefully when prerequisites are missing:

| Condition | Affected Tests | Resolution |
|-----------|----------------|------------|
| No waypoint deployed | header-security Groups 1–3, opa-authz Groups 3–6 | Deploy waypoint (LOCAL-K3D-BOOTSTRAP §9–11) |
| Ingress unreachable | All HTTP-based tests | Configure ingress + port mapping |
| No Keycloak token | Authenticated request tests (Groups 3, 5, 6) | Set `KEYCLOAK_TOKEN` or configure test user |
| istioctl not found | SPIFFE sync check (3.4 in mtls-enforcement) | Install istioctl |

---

## Curl Demo — Defence Layers 0–2

This section demonstrates each authorization layer with curl commands
against the local k3d cluster. The layers build on each other:

| Layer | What | Enforcer | Status |
|-------|------|----------|--------|
| **L0** | Workspace key in URL (capability URL) | Application | Active |
| **L1** | + valid JWT → mesh-injected `x-user-id` | Waypoint + OPA | Active |
| **L2** | + SpiceDB relationship check | Application → SpiceDB | Future |

> **Prerequisites:** local k3d cluster running with all ArgoCD apps
> synced, waypoint deployed (`istioctl waypoint apply -n register
> --enroll-namespace`), and Keycloak realm provisioned with test users.
> See [LOCAL-K3D-BOOTSTRAP.md](LOCAL-K3D-BOOTSTRAP.md) §1–§11.

### Setup: port-forwards

```bash
# Keycloak — token endpoint (ROPC enabled in dev realm)
kubectl -n infra port-forward svc/keycloak 8081:80 &

# Register app — through the k3d loadbalancer (traffic hits the waypoint)
# The k3d cluster maps localhost:8080 → loadbalancer:80 → waypoint → app.
# If the loadbalancer is not configured, port-forward the waypoint directly:
#   kubectl -n register port-forward svc/waypoint 8080:80 &
```

### Layer 0 — Capability URL (no identity)

Layer 0 routes (`/w/*`, and the exact bootstrap path `/workspaces`) require
only the workspace key (bootstrap needs no credential at all in this mode).
No JWT, no identity header. The waypoint's AuthorizationPolicy marks
these as public, and OPA's allow policy bypasses role checks.

```bash
# L0: public route — no Authorization header needed.
curl -si http://localhost:8080/w/demo-workspace-key/risk-trees | head -1
# Expected: HTTP/1.1 200 OK (if workspace exists) or 404 (if not)
#           NOT 401 or 403 — those indicate a policy misconfiguration.

# L0: workspace bootstrap — also public.
curl -si http://localhost:8080/workspaces | head -1
# Expected: 200 or 404 — never 401/403.
```

### Layer 1 — JWT Identity (Keycloak + waypoint + OPA)

Protected routes require a valid JWT. The waypoint validates the
signature, strips forged headers, injects `x-user-id`/`x-user-roles`,
and OPA gates on role claims.

```bash
# Get a JWT from Keycloak (ROPC — dev realm only).
# Test users: demo-editor, demo-analyst, demo-viewer, demo-admin
TOKEN=$(curl -s -X POST \
  "http://localhost:8081/realms/register/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=register-web" \
  -d "username=demo-editor" \
  -d "password=editor-demo-2026" \
  | jq -r .access_token)

# Verify the token has the expected claims:
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss, sub, aud: .aud, roles: .realm_access.roles}'
# Expected: iss=http://keycloak.infra.svc.cluster.local/realms/register
#           aud contains "register-api", roles contains "editor"
```

#### L1 positive: authenticated request

```bash
# Editor reads risk trees — should succeed.
curl -si -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/risk-trees/rt-1 | head -1
# Expected: 200 (or 404 if resource doesn't exist — but NOT 401/403)

# Editor writes — should succeed (editor has recognised role, not viewer-only).
curl -si -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "test"}' \
  http://localhost:8080/risk-trees | head -1
# Expected: 200/201/400 — NOT 401/403
```

#### L1 negative: missing or invalid JWT

```bash
# No token on a protected route → 401 (AuthorizationPolicy requires JWT).
curl -si http://localhost:8080/risk-trees/rt-1 | head -1
# Expected: HTTP/1.1 401 Unauthorized

# Garbage token → 401 (RequestAuthentication rejects invalid signature).
curl -si -H "Authorization: Bearer this.is.not.a.valid.jwt" \
  http://localhost:8080/risk-trees/rt-1 | head -1
# Expected: HTTP/1.1 401 Unauthorized

# Forged x-user-id header without JWT → 401 (header stripped, no principal).
curl -si -H "x-user-id: 00000000-0000-0000-0000-000000000001" \
  http://localhost:8080/risk-trees/rt-1 | head -1
# Expected: HTTP/1.1 401 Unauthorized
```

#### L1 role gating: viewer vs editor

```bash
# Get a viewer token.
VIEWER_TOKEN=$(curl -s -X POST \
  "http://localhost:8081/realms/register/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=register-web" \
  -d "username=demo-viewer" \
  -d "password=viewer-demo-2026" \
  | jq -r .access_token)

# Viewer reads — should succeed (viewer is a recognised role).
curl -si -H "Authorization: Bearer $VIEWER_TOKEN" \
  http://localhost:8080/risk-trees/rt-1 | head -1
# Expected: 200 or 404 — NOT 403

# Viewer writes — should be denied by OPA (viewer + write method = denied).
curl -si -X POST -H "Authorization: Bearer $VIEWER_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "test"}' \
  http://localhost:8080/risk-trees | head -1
# Expected: HTTP/1.1 403 Forbidden
```

#### L1 admin gate: cache management

```bash
# Get an admin token.
ADMIN_TOKEN=$(curl -s -X POST \
  "http://localhost:8081/realms/register/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=register-web" \
  -d "username=demo-admin" \
  -d "password=admin-demo-2026" \
  | jq -r .access_token)

# Admin clears cache — should succeed.
curl -si -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  http://localhost:8080/cache/clear-all | head -1
# Expected: 200 or 204 — NOT 403

# Editor tries cache route — should be denied by OPA (admin gate).
curl -si -X POST -H "Authorization: Bearer $TOKEN" \
  http://localhost:8080/cache/clear-all | head -1
# Expected: HTTP/1.1 403 Forbidden
```

### Layer 2 — SpiceDB Instance Authorization (deployed, not yet enforced)

Layer 2 adds per-resource permission checks via SpiceDB. The application
calls `SpiceDB.check(userId, permission, resourceRef)` after OPA allows
the request. Both must allow — neither can unilaterally grant access.

Infrastructure status: SpiceDB runs in the `infra` namespace (ArgoCD app
`spicedb`) with the authorization schema loaded, and the register chart
injects `SPICEDB_URL`/`SPICEDB_TOKEN`. Enforcement is not active yet —
`REGISTER_AUTH_MODE` is still `capability-only`, so the app never consults
SpiceDB. See [ADR-INFRA-010](adr/ADR-INFRA-010.md) (SpiceDB runtime) and
TODO.md L2 Path Step 2 §auth-mode-switch for the remaining rollout steps.

```bash
# Future: editor with SpiceDB relationship can access specific resource.
#   curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/risk-trees/rt-1
#   → 200 (OPA allows editor role + SpiceDB confirms user→rt-1 relationship)

# Future: editor WITHOUT SpiceDB relationship gets 403.
#   curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/risk-trees/rt-999
#   → 403 (OPA allows, SpiceDB denies — no relationship in graph)
```

### Automated equivalents

The curl demos above are fully automated by the bats regression suite:

| Curl Demo | Bats Suite | Test Group |
|-----------|------------|------------|
| L0 public routes | `opa-authz.bats` | Group 2: public route bypass |
| L1 JWT accept/reject | `header-security.bats` | Groups 2–3: JWT validation |
| L1 header stripping | `header-security.bats` | Group 1: forged header rejection |
| L1 role gating | `opa-authz.bats` | Groups 3–6: auth/unauth, viewer, admin |
| Network isolation (T1) | `network-isolation.bats` | Group 4: direct pod access blocked |

Run all automated tests: `./tests/run-regression.sh`

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `INGRESS` | `http://localhost:8080` | Ingress endpoint for HTTP tests |
| `KEYCLOAK_URL` | `http://localhost:8081/realms/register/protocol/openid-connect/token` | Token endpoint (port-forward) |
| `KEYCLOAK_CLIENT_ID` | `register-web` | OIDC client (ROPC-enabled in dev realm) |
| `KEYCLOAK_TEST_USER` | `demo-editor` | Test user username |
| `KEYCLOAK_TEST_PASSWORD` | `editor-demo-2026` | Test user password |
| `KEYCLOAK_TOKEN` | (empty) | Pre-fetched JWT (skips auto-fetch) |
| `KEYCLOAK_VIEWER_USER` | `demo-viewer` | Viewer-only test user |
| `KEYCLOAK_VIEWER_PASSWORD` | `viewer-demo-2026` | Viewer-only password |
| `KEYCLOAK_ADMIN_USER` | `demo-admin` | Admin test user |
| `KEYCLOAK_ADMIN_PASSWORD` | `admin-demo-2026` | Admin password |

---

## CI Integration

### Design Principles

The pipeline is built around plain CLI tools with no CI-specific
dependencies. Every phase produces machine-parseable output:

- **Conftest**: exits non-zero on policy violations
- **OPA**: exits non-zero on test failures, `-v` flag for verbose output
- **Trivy**: JSON output (`--format json`) for programmatic parsing; table
  output for human review; `--quiet` suppresses progress bars
- **Bats**: TAP output (`--tap`) — a widely supported format
  ([TAP protocol](https://testanything.org/))

### GitHub Actions

No third-party or single-maintainer Actions are required. The pipeline
runs entirely via `run:` steps with official tool binaries.

**Minimal workflow structure** (not a complete workflow — adapt to your repo):

```yaml
jobs:
  static-checks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # Install tools — cache these in practice
      - name: Install conftest
        run: |
          curl -sL https://github.com/open-policy-agent/conftest/releases/download/v0.58.0/conftest_0.58.0_Linux_x86_64.tar.gz \
            | tar xz -C /usr/local/bin conftest
      - name: Install OPA
        run: |
          curl -sL -o /usr/local/bin/opa https://openpolicyagent.org/downloads/v1.4.2/opa_linux_amd64_static
          chmod +x /usr/local/bin/opa
      - name: Install Trivy
        run: |
          curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
            | sh -s -- -b /usr/local/bin
      - name: Static analysis
        run: ./tests/run-regression.sh --static-only

  live-tests:
    runs-on: ubuntu-latest
    needs: static-checks
    steps:
      - uses: actions/checkout@v4
      - name: Install tools
        run: |
          sudo apt-get update && sudo apt-get install -y bats
          # ... same tool installs as above ...
      - name: Create k3d cluster
        run: |
          curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
          k3d cluster create ci-test -p "8080:80@loadbalancer"
      - name: Deploy workloads
        run: |
          # Apply manifests / ArgoCD sync
          kubectl apply -k infra/
      - name: Live tests
        run: ./tests/run-regression.sh --bats-only --allow-skip
```

### Key CI Considerations

1. **Split static vs live jobs.** `--static-only` runs Phases 1+2+3a
   without a cluster. This catches most regressions instantly. The
   `--bats-only` job runs Phase 4 after deploying the stack.

2. **Tool caching.** All four tools are static binaries (except bats
   from apt). Cache `conftest`, `opa`, and `trivy` (plus Trivy's
   `~/.cache/trivy/` policy DB) between runs.

3. **Trivy DB download.** The first `trivy` run downloads the checks
   bundle (~236 KB). Subsequent runs use the cache. In CI, either:
   - Cache `~/.cache/trivy/` between jobs, or
   - Accept the one-time download cost (~1s)

4. **No special Actions required.** All tools are installed via `curl` +
   `install`. The only Actions dependency is `actions/checkout@v4`
   (official, org-maintained). No single-maintainer Actions.

5. **TAP output.** Bats TAP output is written to
   `/tmp/bats-regression-output.tap`. Upload this as an artifact for
   test dashboards.

6. **Exit code semantics.** Use `--allow-skip` in CI for feature-branch
   builds where the full stack may not be deployed. Use strict mode
   (default) for release/main branch builds.

7. **Trivy offline mode.** For air-gapped CI, download the Trivy DB
   separately and pass `--skip-db-update --skip-check-update`. Not
   needed for GitHub-hosted runners.

8. **Parallel execution.** Phases 1, 2, and 3a are independent — a
   matrix strategy or parallel job setup can cut wall-clock time.
   Phase 3b and 4 both need a live cluster and can share one.

---

## File Structure

```
tests/
├── run-regression.sh               # Pipeline wrapper (all phases)
├── bats/
│   ├── header-security.bats        # L1+L2: identity header security
│   ├── health-probes.bats          # L0: probe reachability + config
│   ├── mtls-enforcement.bats       # L0: mTLS + mesh identity
│   ├── network-isolation.bats      # L0: NetworkPolicy + CiliumNP
│   ├── opa-authz.bats              # L2: OPA ext_authz behaviour
│   └── pod-security.bats           # Hardening: pod security posture
├── conftest/
│   └── policy/
│       ├── authorizationpolicy.rego
│       ├── ciliumnetworkpolicy.rego
│       ├── envoyfilter.rego
│       ├── keycloak-realm.rego
│       ├── kyvernopolicy.rego
│       ├── networkpolicy.rego
│       ├── peerauthentication.rego
│       └── requestauthentication.rego
└── opa/
    └── allow_test.rego             # OPA unit tests (43 tests)
```
