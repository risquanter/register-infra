# ADR-INFRA-005: Infrastructure Testing Strategy — Tool Selection and Skip Semantics

**Status:** Accepted  
**Date:** 2026-03-05  
**Tags:** testing, conftest, chainsaw, bats, ci, regression

---

## Context

- Infrastructure misconfigurations are silent — a missing EnvoyFilter or a broken AuthorizationPolicy returns a generic HTTP error with no stack trace pointing to the root cause
- Static YAML analysis (no cluster) catches structural regressions cheapest; live-cluster tests catch behavioural regressions that static analysis cannot (filter ordering, mTLS handshake, network policy enforcement)
- Raw bash test scripts lack structured output (TAP/JUnit), skip semantics, and test isolation — CI cannot distinguish "all passed" from "nothing was tested"
- Kubernetes-native test frameworks (chainsaw) excel at declarative resource assertions but are unsuitable for HTTP-level behavioural tests that require curl, Envoy admin API inspection, or token negotiation
- Test **skip** semantics must be explicit: a green CI pipeline where all tests were silently skipped is a false-confidence vulnerability

---

## Decision

### 1. Three Tools at Three Layers

Match the tool to the assertion type:

| Layer | Tool | What it checks | Cluster required? |
|-------|------|----------------|-------------------|
| Static policy | **conftest** (OPA/Rego) | YAML structure: required fields, prohibited patterns, label invariants | No |
| Resource state | **chainsaw** (Kyverno) | Live K8s resources match expected spec after ArgoCD sync | Yes |
| Behavioural | **bats-core** | HTTP responses, Envoy config_dump inspection, network isolation probes | Yes |

```bash
# Static — runs in CI on every PR, no cluster
conftest test infra/k8s/ --policy tests/conftest/

# Resource state — runs post-deploy
chainsaw test --test-dir tests/chainsaw/

# Behavioural — runs post-deploy
bats tests/bats/
```

### 2. Conftest for Static YAML Policy Checks

Write Rego rules that assert structural invariants on raw manifests. These run in CI without a cluster and catch regressions before merge.

```rego
# tests/conftest/policy/envoyfilter.rego
package main

deny[msg] {
    input.kind == "EnvoyFilter"
    input.metadata.name == "strip-identity-headers"
    headers := input.spec.configPatches[_].patch.value.typed_config.request_headers_to_remove
    required := {"x-user-id", "x-user-email", "x-user-roles"}
    missing := required - {h | h := headers[_]}
    count(missing) > 0
    msg := sprintf("EnvoyFilter missing identity headers in request_headers_to_remove: %v", [missing])
}
```

### 3. Bats-Core for Behavioural Tests

Use bats for tests that require live HTTP interaction, Envoy admin API queries, or token negotiation. Bats provides TAP output, `setup`/`teardown` hooks, and first-class `skip` support.

```bash
@test "valid JWT + forged x-user-id passes (header stripped, not denied)" {
    run curl -so /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
        -H "x-user-id: forged-value" \
        "${INGRESS}/api/test"
    [[ "$output" =~ ^(200|404)$ ]]
}
```

### 4. Chainsaw for Resource State Assertions

Use chainsaw for declarative verification that K8s resources have the expected configuration after ArgoCD sync. Suitable for pre/post upgrade checks and drift detection.

```yaml
# tests/chainsaw/security-resources/chainsaw-test.yaml
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Test
metadata:
  name: security-resources-exist
spec:
  steps:
    - assert:
        resource:
          apiVersion: security.istio.io/v1
          kind: RequestAuthentication
          metadata:
            name: keycloak-jwt
            namespace: register
```

### 5. Skip = Exit 2 (Distinct From Pass and Fail)

Tests that cannot run due to missing prerequisites (no cluster, no token, no waypoint pod) exit with code **2**. CI pipelines must treat exit 2 as a blocking condition on protected branches.

| Exit code | Meaning | CI action |
|-----------|---------|-----------|
| 0 | All tests passed | Allow merge |
| 1 | One or more tests **failed** | Block merge |
| 2 | Tests **skipped** — prerequisites missing | Block on `main`; allow on feature branches |

---

## Code Smells

### ❌ Raw Bash Test Script Without Framework

```bash
# BAD: no structured output, silent skips, no test isolation
PASS=0; FAIL=0
STATUS=$(curl -o /dev/null -w '%{http_code}' ...)
if [ "$STATUS" = "200" ]; then ((PASS++)); fi
echo "Passed: $PASS Failed: $FAIL"  # not machine-parseable
```

```bash
# GOOD: bats — TAP output, skip support, test isolation
@test "public route returns 200" {
    run curl -so /dev/null -w '%{http_code}' "${INGRESS}/health"
    [ "$output" = "200" ]
}
```

### ❌ Behavioural Tests in Chainsaw Script Steps

```yaml
# BAD: bash wrapped in YAML for no benefit — use bats directly
spec:
  steps:
    - script:
        content: |
          STATUS=$(curl -so /dev/null -w '%{http_code}' ...)
          [ "$STATUS" = "200" ]
```

```yaml
# GOOD: chainsaw for what it does best — declarative resource assertions
spec:
  steps:
    - assert:
        resource:
          apiVersion: security.istio.io/v1
          kind: PeerAuthentication
          spec:
            mtls:
              mode: STRICT
```

### ❌ Skip That Passes Silently

```bash
# BAD: skip counts as pass — green pipeline with nothing tested
if [ -z "$TOKEN" ]; then echo "SKIP"; fi
exit 0  # always green
```

```bash
# GOOD: skip has distinct exit code — CI decides the policy
@test "JWT accepted" {
    [ -n "$KEYCLOAK_TOKEN" ] || skip "no token available"
    ...
}
# bats exits 0 only if all non-skipped tests pass
# wrapper script exits 2 if skip count > 0 and --strict flag set
```

---

## Implementation

| Location | Tool | What it covers |
|----------|------|----------------|
| `tests/conftest/` | conftest (Rego) | Static policy: EnvoyFilter headers, no DENY on identity, PeerAuth STRICT, PSS labels |
| `tests/chainsaw/` | chainsaw | Resource state: security CRDs exist with correct spec post-sync |
| `tests/bats/` | bats-core | Behavioural: HTTP auth flow, Envoy config_dump, C1 regression, network isolation |
| `.github/workflows/ci.yaml` | conftest | Run on every PR (no cluster) |
| `.github/workflows/regression.yaml` | bats + chainsaw | Run post-deploy against live cluster |

---

## References

- [conftest documentation](https://www.conftest.dev/)
- [chainsaw (Kyverno) documentation](https://kyverno.github.io/chainsaw/)
- [bats-core documentation](https://bats-core.readthedocs.io/)
- ADR-INFRA-004 (defence-in-depth layers that these tests verify)
- [ADR-INFRA-011](ADR-INFRA-011.md) — dual CI topology: cloud-hosted for static checks (conftest), in-cluster runner for schema lifecycle + integration tests
