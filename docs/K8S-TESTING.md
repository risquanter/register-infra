# Kubernetes Infrastructure Testing Guide

This document explains how to validate the register-infra stack at every layer —
from static file checks that run locally in seconds, to live cluster assertions
that verify the security invariants the platform is built on.

**Who this is for**: engineers who have completed the cluster bootstrap
(see [K3S-GITOPS-BOOTSTRAP.md](K3S-GITOPS-BOOTSTRAP.md)) and want to
understand what "done" looks like and how to catch regressions.

---

## Mental model: four testing layers

Infrastructure testing follows the same principle as application testing — catch
problems as early and cheaply as possible.

```
Layer 4: Live cluster integration tests   ← most realistic, slowest, needs a running cluster
Layer 3: Kubernetes manifest validation   ← fast, no cluster needed
Layer 2: Helm chart linting + rendering   ← fast, no cluster needed
Layer 1: Terraform static analysis        ← fastest, no cloud credentials needed
```

Work from the bottom up. Most problems are caught at layers 1–3 before
anything touches a real server.

---

## Prerequisites — install the test toolchain

Run this once on your workstation. None of these tools require a running cluster.

```bash
# ── tflint — Terraform linter ────────────────────────────────────────────────
# Catches provider-specific mistakes that terraform validate misses,
# e.g. using an instance type that doesn't exist on Hetzner.
curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
tflint --version

# ── trivy — security scanner for IaC files ────────────────────────────────────
# Scans Terraform, Helm, and k8s YAML for known misconfigurations.
# Maintained by Aqua Security — widely used in production pipelines.
curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | bash -s -- -b /usr/local/bin
trivy --version

# ── kubeconform — Kubernetes manifest schema validator ────────────────────────
# Validates YAML against the real Kubernetes API schemas.
# Catches "field does not exist" errors before kubectl apply.
# Replacement for the unmaintained kubeval tool.
KUBECONFORM_VERSION=$(curl -fsSL https://api.github.com/repos/yannh/kubeconform/releases/latest | jq -r .tag_name)
curl -fsSLO "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz"
tar xzvf kubeconform-linux-amd64.tar.gz kubeconform
sudo mv kubeconform /usr/local/bin/
rm kubeconform-linux-amd64.tar.gz
kubeconform -v

# ── kube-linter — Kubernetes security best practice checker ──────────────────
# Checks manifests for common security mistakes:
# missing resource limits, containers running as root, missing liveness probes etc.
# Maintained by Stackrox (Red Hat).
curl -fsSLO "https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux.tar.gz"
tar xzvf kube-linter-linux.tar.gz
sudo mv kube-linter /usr/local/bin/
rm kube-linter-linux.tar.gz
kube-linter version

# ── pluto — deprecated API version detector ───────────────────────────────────
# Kubernetes removes old API versions in minor releases (e.g. v1beta1 → v1).
# Pluto warns you before an upgrade breaks your manifests.
# Maintained by Fairwinds.
curl -fsSL https://raw.githubusercontent.com/FairwindsOps/pluto/master/hack/install.sh | bash
pluto version

# ── Helm (if not already installed) ──────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# ── conftest — OPA/Rego policy checker for static YAML validation ─────────────
# Tests Kubernetes manifests against custom policies without a cluster.
# See §4.6 and ADR-INFRA-005.
CONFTEST_VERSION=$(curl -fsSL https://api.github.com/repos/open-policy-agent/conftest/releases/latest | jq -r .tag_name)
curl -fsSLO "https://github.com/open-policy-agent/conftest/releases/download/${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION#v}_Linux_x86_64.tar.gz"
tar xzf conftest_*.tar.gz conftest && sudo mv conftest /usr/local/bin/ && rm conftest_*.tar.gz
conftest --version

# ── bats-core — Bash Automated Testing System ────────────────────────────────
# TAP-output test framework for the live-cluster regression suite.
# See §4.7 and ADR-INFRA-005.
git clone https://github.com/bats-core/bats-core.git /tmp/bats-install
sudo /tmp/bats-install/install.sh /usr/local && rm -rf /tmp/bats-install
bats --version
```

---

## Layer 1 — Terraform static analysis

These checks run without cloud credentials and take under 10 seconds.

### What each tool does

| Tool | What it checks |
|---|---|
| `terraform fmt` | File is formatted canonically — cosmetic but enforced in CI |
| `terraform validate` | Syntax is valid and all variable references resolve |
| `tflint` | Provider-specific rules (Hetzner instance types, deprecated args) |
| `trivy config` | Security misconfigurations (open firewall rules, unencrypted storage) |

### Run the checks

```bash
cd infra/terraform

# 1. check formatting — exit code 1 means at least one file needs reformatting
terraform fmt -check -recursive
# to auto-fix: terraform fmt -recursive

# 2. validate syntax and references
terraform init -backend=false   # initialise without connecting to state backend
terraform validate

# 3. provider-specific linting
tflint --recursive

# 4. security misconfiguration scan
trivy config .
```

### What to look for in trivy output

```
MEDIUM: Security group rule allows ingress from 0.0.0.0/0 on port 22
```

This would mean your SSH firewall rule is open to the internet — a real
security problem. The current `variables.tf` uses `var.operator_cidr` to
restrict this, so this finding should not appear if the variable is set.

```
LOW: No encryption enabled for volume
```

Informational at this scale. k3s secret encryption at rest addresses the
higher-level concern.

---

## Layer 2 — Helm chart linting and rendering

Helm charts are templates. Testing them means both checking the template
structure and checking the rendered output (the final YAML that Kubernetes
will process).

### Run the checks

```bash
# ── Chart structure lint ──────────────────────────────────────────────────────
# Checks Chart.yaml, values.yaml structure, and any values.schema.json.
helm lint infra/helm/register/
helm lint infra/helm/namespaces/
helm lint infra/helm/opa/
helm lint infra/helm/keycloak/
helm lint infra/helm/frontend/
helm lint infra/helm/irmin/

# ── Render and inspect output ─────────────────────────────────────────────────
# helm template renders the chart to plain YAML without talking to a cluster.
# Pipe through less to browse the output, or save to a file for further analysis.
helm template register infra/helm/register/ | less
helm template namespaces infra/helm/namespaces/ | less

# ── Validate rendered output against Kubernetes API schemas ───────────────────
# kubeconform -strict: fails on any unknown field (catches typos in field names)
# kubeconform -summary: prints a one-line pass/fail summary
helm template register infra/helm/register/ \
  | kubeconform -strict -summary

helm template namespaces infra/helm/namespaces/ \
  | kubeconform -strict -summary

# ── Security best practice check on rendered output ───────────────────────────
helm template register infra/helm/register/ \
  | kube-linter lint -

# ── Deprecated API version check ─────────────────────────────────────────────
# Run before upgrading your cluster's Kubernetes version.
helm template register infra/helm/register/ | pluto detect -
```

### Adding a values schema (recommended)

A schema file causes `helm lint` to type-check values, catching configuration
errors before they reach the cluster. Create
`infra/helm/register/values.schema.json`:

```json
{
  "$schema": "http://json-schema.org/schema#",
  "type": "object",
  "required": ["image", "replicaCount", "resources"],
  "properties": {
    "replicaCount": {
      "type": "integer",
      "minimum": 1,
      "description": "Number of application pod replicas."
    },
    "image": {
      "type": "object",
      "required": ["repository", "tag"],
      "properties": {
        "repository": { "type": "string" },
        "tag":        { "type": "string" }
      }
    },
    "resources": {
      "type": "object",
      "required": ["requests", "limits"],
      "properties": {
        "requests": {
          "type": "object",
          "required": ["cpu", "memory"]
        },
        "limits": {
          "type": "object",
          "required": ["cpu", "memory"]
        }
      }
    }
  }
}
```

After adding this file, `helm lint infra/helm/register/` will fail if
`values.yaml` is missing any required field or has a value of the wrong type.

---

## Layer 3 — Kubernetes raw manifest validation

The manifests in `infra/k8s/` (Istio policies, network policies) are applied
directly by ArgoCD without Helm rendering. Validate them directly.

```bash
# validate all raw manifests against Kubernetes API schemas
kubeconform -strict -summary infra/k8s/

# security best practice check
kube-linter lint infra/k8s/

# deprecated API check
pluto detect-files -d infra/k8s/
```

### Common kubeconform failures and their meaning

```
ERR - istio/request-authentication.yaml - could not find schema for RequestAuthentication
```

This means kubeconform does not have a schema for this Istio CRD. This is
expected — CRD schemas are not part of the core Kubernetes schema bundle.
You can provide them explicitly or skip unknown resources:

```bash
# skip resources whose schema is not in the standard bundle
kubeconform -strict -summary \
  -ignore-missing-schemas \
  infra/k8s/
```

For CRD-heavy manifests, `kube-linter` is more useful than kubeconform because
kube-linter checks security properties rather than schema correctness.

---

## Layer 4 — Live cluster tests

These tests require a running cluster (your local VM or Hetzner node). They
verify the security invariants defined in the threat catalog
(`docs/THREAT-CATALOG.md` in the app repo).

### 4.1 ArgoCD sync health

Before testing the application, confirm ArgoCD has successfully deployed
everything.

```bash
# list all Applications and their sync + health status
argocd app list

# expected output for each app:
#   SYNC STATUS: Synced
#   HEALTH STATUS: Healthy

# if an app is OutOfSync, force a sync and watch it converge
argocd app sync register
argocd app wait register --health --timeout 120
```

### 4.2 Helm release health

```bash
# confirm the register Helm release is deployed at the expected revision
helm -n register ls

# NAME      NAMESPACE  REVISION  STATUS    CHART
# register  register   3         deployed  register-0.1.0

# check events for errors
kubectl -n register get events \
  --sort-by=.lastTimestamp \
  | tail -n 20
```

### 4.3 Mesh trust invariants (T1–T4)

These tests directly verify the security claims made in the threat catalog.
Run them after every Istio policy change.

> **Local k3d?** For a complete Layer 0/1/2 curl demo with real credentials,
> see [TESTING.md § Curl Demo](TESTING.md#curl-demo--defence-layers-02).

```bash
INGRESS="https://<your-ingress-host>"   # replace with actual host

# ── T2: JWT validation active ─────────────────────────────────────────────────
# An invalid bearer token must be rejected by the waypoint before reaching the app.
# Expected: HTTP 401
echo "--- T2: invalid JWT must be rejected ---"
curl -si \
  -H "Authorization: Bearer this.is.not.a.valid.jwt" \
  "${INGRESS}/health" \
  | head -1

# ── T3: identity header stripping active ──────────────────────────────────────
# A forged x-user-id header sent by an external client must be stripped by
# the EnvoyFilter before the request reaches the app. The app must not see
# the forged value.
# Expected: 401 (request has no valid JWT) — the header must not grant access.
echo "--- T3: forged x-user-id header must not bypass auth ---"
curl -si \
  -H "x-user-id: 00000000-0000-0000-0000-000000000001" \
  "${INGRESS}/health" \
  | head -1

# ── T1: direct pod access blocked (mesh bypass prevention) ────────────────────
# Traffic bypassing the waypoint (direct to pod IP) must be blocked by
# the default-deny NetworkPolicy enforced by Cilium.
# Expected: connection refused or timeout — NOT a successful response.
echo "--- T1: direct pod access must be blocked ---"
POD_IP=$(kubectl -n register get pods \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

if [ -n "$POD_IP" ]; then
  curl -si --connect-timeout 5 "http://${POD_IP}:8080/health" \
    && echo "FAIL: direct pod access succeeded — NetworkPolicy not enforced" \
    || echo "PASS: direct pod access blocked"
else
  echo "SKIP: no pod found in register namespace"
fi
```

### 4.4 Network policy validation with Cilium

Cilium provides a built-in tool to verify that NetworkPolicy rules are
enforced as intended.

```bash
# show all active policies in the register namespace
kubectl -n register get networkpolicy

# test connectivity between two pods directly using Cilium's policy tester
# (this runs inside the Cilium agent — no test pod needed)
kubectl -n kube-system exec -it \
  $(kubectl -n kube-system get pod -l k8s-app=cilium -o name | head -1) \
  -- cilium policy get

# run the full Cilium connectivity suite (comprehensive but slow — ~10 min)
# useful after CNI changes or Istio upgrades
cilium connectivity test --test-concurrency 1
```

### 4.5 ArgoCD drift detection (pre-merge check)

Before merging any change to the infra repo, check what ArgoCD would actually
change in the live cluster. This is the GitOps equivalent of a `terraform plan`.

```bash
# diff the local chart against what is currently deployed
# shows added/changed/removed resources without applying anything
argocd app diff register --local infra/helm/register/

# diff a raw manifest directory
argocd app diff mesh-policy --local infra/k8s/
```

If the diff shows unexpected changes, review before merging.

### 4.6 Static policy checks — conftest

[conftest](https://www.conftest.dev/) validates Kubernetes manifests against
OPA/Rego policies **without a cluster**.  This catches structural regressions
(missing headers, prohibited DENY policies, wrong mTLS mode) at PR time.

```bash
# install conftest (one-time)
CONFTEST_VERSION=$(curl -fsSL https://api.github.com/repos/open-policy-agent/conftest/releases/latest | jq -r .tag_name)
curl -fsSLO "https://github.com/open-policy-agent/conftest/releases/download/${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION#v}_Linux_x86_64.tar.gz"
tar xzf conftest_*.tar.gz conftest && sudo mv conftest /usr/local/bin/ && rm conftest_*.tar.gz

# run all static policies against the manifests
conftest test infra/k8s/istio/ -p tests/conftest/policy/
conftest test infra/k8s/network-policy/ -p tests/conftest/policy/
```

Policies live in `tests/conftest/policy/` (Rego files).  Each policy targets a
specific resource kind — see [ADR-INFRA-005](adr/ADR-INFRA-005.md) for the
rationale.

| Policy file | What it checks |
|---|---|
| `envoyfilter.rego` | `request_headers_to_remove` includes all identity headers; waypoint selector present |
| `authorizationpolicy.rego` | No DENY policy references identity headers (C1 regression guard); ALLOW requires `requestPrincipals` |
| `requestauthentication.rego` | `outputClaimToHeaders` maps `sub` → `x-user-id`; `audiences` set |
| `peerauthentication.rego` | Mode must be STRICT; no port-level overrides weaken it |
| `networkpolicy.rego` | `default-deny-all` covers Ingress + Egress; DNS egress allows UDP/53 + TCP/53 |

### 4.7 Regression suite: identity header security invariants (bats-core)

A [bats-core](https://github.com/bats-core/bats-core) test suite verifies the
five defence layers that protect `x-user-id` from forgery against a **live
cluster** (see [SECURITY-FLOW.md](SECURITY-FLOW.md),
[ADR-INFRA-005](adr/ADR-INFRA-005.md)).

**When to run**: after every Istio or Cilium upgrade, after any change to
`infra/k8s/istio/` or `infra/k8s/network-policy/`, and in CI against a live
cluster.

```bash
# install bats-core (one-time)
git clone https://github.com/bats-core/bats-core.git /tmp/bats && sudo /tmp/bats/install.sh /usr/local

# run with strict skip semantics (default — exit 2 on skips)
./tests/run-regression.sh

# allow skips on feature branches
./tests/run-regression.sh --allow-skip

# against a remote cluster
INGRESS=https://register.example.com ./tests/run-regression.sh

# pre-set a JWT (skip token fetch)
KEYCLOAK_TOKEN="eyJ..." ./tests/run-regression.sh
```

The suite runs five groups of checks:

| Group | What it verifies | Cluster required? |
|---|---|---|
| **1. Envoy config_dump** | Waypoint filter chain structure: `request_headers_to_remove` includes identity headers; `jwt_authn`, `rbac`, `ext_authz` filters present | Yes |
| **2. Unauthenticated requests** | Public routes return 200; authenticated routes reject without JWT; forged `x-user-id` without JWT does not grant access | Yes |
| **3. Authenticated requests** | Valid JWT accepted; valid JWT + forged header passes (strip works, no DENY regression); tampered JWT rejected; app receives `x-user-id` matching JWT `sub` | Yes (+ Keycloak) |
| **4. Network isolation** | Direct pod access blocked (NetworkPolicy); PeerAuthentication STRICT active | Yes |
| **5. Istio resource integrity** | RequestAuthentication, AuthorizationPolicy, EnvoyFilter resources exist with expected configuration; no DENY policy on identity headers (C1 regression guard) | Yes |

**C1 regression specifically**: test 3.2 sends a valid JWT plus a forged
`x-user-id` header. If the old DENY policy is accidentally re-introduced, this
test returns 403 and fails. Test 5.4 independently checks that no DENY
AuthorizationPolicy matching identity headers exists in the namespace.

**Exit code semantics** (see [ADR-INFRA-005](adr/ADR-INFRA-005.md)):
- **0** — all tests passed
- **1** — one or more tests failed (regression detected)
- **2** — tests skipped because prerequisites are missing (cluster down,
  Keycloak not deployed, etc.).  Blocks merge on `main`; allowed on feature
  branches with `--allow-skip`.

---

## CI pipeline — automated checks on every pull request

Add this workflow to the infra repo at `.github/workflows/ci.yaml`.
It runs layers 1–3 on every pull request with no cloud credentials required.

```yaml
name: Validate

on:
  pull_request:
    paths:
      - "infra/**"

jobs:
  validate:
    name: Static validation
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.10.0"

      - name: Install toolchain
        run: |
          # tflint
          curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
          # trivy
          curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
            | bash -s -- -b /usr/local/bin
          # kubeconform
          KVER=$(curl -fsSL https://api.github.com/repos/yannh/kubeconform/releases/latest | jq -r .tag_name)
          curl -fsSLO "https://github.com/yannh/kubeconform/releases/download/${KVER}/kubeconform-linux-amd64.tar.gz"
          tar xzvf kubeconform-linux-amd64.tar.gz kubeconform
          sudo mv kubeconform /usr/local/bin/
          # kube-linter
          curl -fsSLO "https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux.tar.gz"
          tar xzvf kube-linter-linux.tar.gz && sudo mv kube-linter /usr/local/bin/
          # helm
          curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
          # pluto
          curl -fsSL https://raw.githubusercontent.com/FairwindsOps/pluto/master/hack/install.sh | bash

      # ── Terraform ────────────────────────────────────────────────────────────
      - name: Terraform format check
        run: terraform -chdir=infra/terraform fmt -check -recursive

      - name: Terraform init (no backend)
        run: terraform -chdir=infra/terraform init -backend=false

      - name: Terraform validate
        run: terraform -chdir=infra/terraform validate

      - name: tflint
        run: tflint --chdir=infra/terraform

      - name: trivy — Terraform IaC scan
        run: trivy config infra/terraform/ --exit-code 1 --severity HIGH,CRITICAL

      # ── Helm ─────────────────────────────────────────────────────────────────
      - name: Helm lint — all charts
        run: |
          helm lint infra/helm/register/
          helm lint infra/helm/namespaces/
          helm lint infra/helm/opa/
          helm lint infra/helm/keycloak/
          helm lint infra/helm/frontend/
          helm lint infra/helm/irmin/

      - name: kubeconform — register chart
        run: |
          helm template register infra/helm/register/ \
            | kubeconform -strict -summary -ignore-missing-schemas

      - name: kubeconform — namespaces chart
        run: |
          helm template namespaces infra/helm/namespaces/ \
            | kubeconform -strict -summary

      - name: kube-linter — register chart
        run: helm template register infra/helm/register/ | kube-linter lint -

      - name: pluto — deprecated API check
        run: |
          helm template register infra/helm/register/ | pluto detect -
          helm template namespaces infra/helm/namespaces/ | pluto detect -
          helm template keycloak infra/helm/keycloak/ | pluto detect -
          helm template frontend infra/helm/frontend/ | pluto detect -
          helm template irmin infra/helm/irmin/ | pluto detect -

      # ── Raw manifests ────────────────────────────────────────────────────────
      - name: kubeconform — k8s manifests
        run: kubeconform -strict -summary -ignore-missing-schemas infra/k8s/

      - name: kube-linter — k8s manifests
        run: kube-linter lint infra/k8s/

      - name: pluto — k8s manifests
        run: pluto detect-files -d infra/k8s/
```

This pipeline catches the majority of problems in under 2 minutes with zero
cloud cost.

---

## Testing priority by project phase

You do not need all of this immediately. Add layers as the project matures.

| Phase | Add these tests | Rationale |
|---|---|---|
| Now (bootstrap) | `terraform fmt`, `terraform validate`, `helm lint`, `kubeconform` | Catch syntax errors immediately; zero setup cost |
| Wave 1 (Istio live) | T2 + T3 curl checks, `kube-linter`, **regression suite** | Verify the security invariants that Wave 2 depends on |
| Wave 2 (requirePresent) | T1 NetworkPolicy check, `cilium connectivity test` | T1 is a Wave 2 blocker per THREAT-CATALOG.md |
| Wave 3 (SpiceDB) | Full CI pipeline + kuttl e2e tests | System is complex enough that automated end-to-end tests pay off |
| Pre-k8s upgrade | `pluto detect` on all manifests | Catch deprecated API versions before they break on the new cluster version |

---

## Quick reference — run everything locally

```bash
# from the infra repo root

# Layer 1 — Terraform
terraform -chdir=infra/terraform fmt -check -recursive
terraform -chdir=infra/terraform init -backend=false && terraform -chdir=infra/terraform validate
tflint --chdir=infra/terraform
trivy config infra/terraform/

# Layer 2 — Helm
helm lint infra/helm/register/ && helm lint infra/helm/namespaces/
helm template register infra/helm/register/ | kubeconform -strict -summary -ignore-missing-schemas
helm template register infra/helm/register/ | kube-linter lint -

# Layer 3 — Raw manifests
kubeconform -strict -summary -ignore-missing-schemas infra/k8s/
kube-linter lint infra/k8s/
conftest test infra/k8s/istio/ infra/k8s/network-policy/ -p tests/conftest/policy/

# Layer 4 — Live cluster (requires KUBECONFIG set and cluster running)
argocd app list
argocd app diff register --local infra/helm/register/
./tests/run-regression.sh
```
