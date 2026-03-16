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
| **L2 — AuthZ**           | ✓ AuthorizationPolicy | ✓ 25 tests (role gates, viewer deny, admin cache) | — | ✓ OPA ext_authz live behaviour |
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

### Phase 2 — OPA Unit Tests

25 tests in `tests/opa/allow_test.rego` covering:

- Health endpoint bypass (`/health`, `/ready`)
- Role-based access for `analyst`, `editor`, `team_admin`
- Viewer write protection (POST/PUT/PATCH/DELETE denied)
- Admin-only cache management gate
- Unauthenticated request denial (default deny)
- Unknown/unrecognised role rejection
- Edge cases (empty paths, missing headers)

### Phase 3 — Trivy Security Scans

**3a — Static config scan** (`trivy config infra/`):
Scans all manifests and Helm charts for HIGH/CRITICAL misconfigurations.
Known exceptions are filtered automatically:

| ID | Severity | Description | Justification |
|----|----------|-------------|---------------|
| KSV-0014 | HIGH | Keycloak readOnlyRootFilesystem | Writes to `/opt/keycloak/data/` at runtime |
| KSV-0053 | HIGH | deployer Role pods/exec | Required for GitOps troubleshooting |
| KSV-0056 | HIGH | deployer Role network management | Required for NetworkPolicy deployment |

Any finding **not** in this exception list causes a hard failure.

**3b — Live compliance scans** (`trivy k8s --compliance`):

| Framework | Gate Type | Expected |
|-----------|-----------|----------|
| PSS Baseline (`k8s-pss-baseline-0.1`) | Hard gate — 0 failures required | 11/11 PASS |
| NSA Hardening (`k8s-nsa-1.0`) | Soft — 2 known exceptions tolerated | ~22 PASS, 2 known FAIL |

NSA known exceptions (counted as FAIL):
- **1.1** Immutable container file systems — Keycloak exception
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

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `INGRESS` | `http://localhost:8080` | Ingress endpoint for HTTP tests |
| `KEYCLOAK_URL` | `http://keycloak.infra.svc.cluster.local/...` | Token endpoint |
| `KEYCLOAK_CLIENT_ID` | `register-api` | OIDC client |
| `KEYCLOAK_TEST_USER` | `testuser` | Test user username |
| `KEYCLOAK_TEST_PASSWORD` | `testpassword` | Test user password |
| `KEYCLOAK_TOKEN` | (empty) | Pre-fetched JWT (skips auto-fetch) |
| `KEYCLOAK_VIEWER_USER` | (empty) | Viewer-only test user |
| `KEYCLOAK_VIEWER_PASSWORD` | (empty) | Viewer-only password |

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
│       ├── networkpolicy.rego
│       ├── peerauthentication.rego
│       └── requestauthentication.rego
└── opa/
    └── allow_test.rego             # OPA unit tests (25 tests)
```
