# ADR-INFRA-001: Configuration Single-Source-of-Truth

**Status:** Accepted  
**Date:** 2026-03-05  
**Tags:** config, drift, opa, helm, gitops

---

## Context

- Configuration values appearing in multiple files **will** drift — the OPA Rego policy existed in `infra/opa/policies/allow.rego` (109 lines, canonical) and inline in a ConfigMap (47 lines, compacted). They diverged silently.
- ArgoCD syncs YAML files verbatim — it does not template raw manifests. Values shared between a Helm chart and a raw manifest require manual synchronization.
- ADR-012 trust invariants (T1–T4) depend on configuration correctness. A drifted policy or issuer URL can silently break security without visible errors.
- The Keycloak issuer URL appears in two independent files (`request-authentication.yaml` and `values.yaml`). A mismatch causes silent JWT rejection.

---

## Decision

### 1. Helm `Files.Get` for Policy Files

Any policy or configuration file consumed by a Kubernetes resource (ConfigMap, Secret) must be loaded via Helm's `.Files.Get` from a single canonical source file within the chart.

```yaml
# templates/configmap.yaml
data:
  allow.rego: |
{{ .Files.Get "policies/allow.rego" | indent 4 }}
```

The canonical file lives at `infra/helm/<chart>/policies/` — not in a separate directory tree.

### 2. Cross-File Value Annotation

When a value must appear in both a Helm chart and a raw manifest (e.g., issuer URL in `values.yaml` and `request-authentication.yaml`), annotate the raw manifest with a machine-readable sync marker:

```yaml
metadata:
  annotations:
    register-infra/issuer-sync: "http://keycloak.infra.svc.cluster.local/realms/register"
```

This makes the coupling explicit and greppable. A CI check can verify the annotation value matches the Helm value.

### 3. Prefer Helm Charts Over Raw Manifests

When a set of raw manifests grows to include Deployment + Service + ConfigMap (i.e., an application), convert to a Helm chart. Raw manifests are appropriate for singleton policy resources (EnvoyFilter, AuthorizationPolicy, NetworkPolicy) that don't need templating.

---

## Code Smells

### ❌ Inline Policy in ConfigMap

```yaml
# BAD: policy embedded inline — will drift from canonical source
data:
  allow.rego: |
    package register.authz
    default allow := false
    allow if { input.parsed_path == ["health"] }
    # ... compacted, comments stripped, missing rules
```

```yaml
# GOOD: loaded from single source file
data:
  allow.rego: |
{{ .Files.Get "policies/allow.rego" | indent 4 }}
```

### ❌ Same Value in Two Files Without Cross-Reference

```yaml
# BAD: issuer URL hardcoded in both files independently
# request-authentication.yaml
issuer: "http://keycloak.infra.svc.cluster.local/realms/register"

# values.yaml
KEYCLOAK_ISSUER: "https://keycloak.example.com/realms/register"  # oops, different
```

```yaml
# GOOD: explicit sync marker + identical value
metadata:
  annotations:
    register-infra/issuer-sync: "http://keycloak.infra.svc.cluster.local/realms/register"
```

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/helm/opa/templates/configmap.yaml` | `Files.Get` from `policies/allow.rego` |
| `infra/k8s/istio/request-authentication.yaml` | `issuer-sync` annotation cross-referencing `values.yaml` |
| `infra/helm/opa/policies/allow.rego` | Single canonical Rego source (was duplicated in `infra/opa/` + ConfigMap) |

---

## References

- OPA policy drift finding (security review, 2026-03-02)
- Helm Files.Get: https://helm.sh/docs/chart_template_guide/accessing_files/
