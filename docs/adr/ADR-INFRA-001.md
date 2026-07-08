# ADR-INFRA-001: Configuration Single-Source-of-Truth

**Status:** Accepted  
**Date:** 2026-03-05  
**Tags:** config, drift, opa, helm, gitops

---

## Context

- Configuration duplicated between a canonical source and a rendered or hand-authored copy **will** drift — nothing in Kubernetes or Helm detects the mismatch until something fails at runtime.
- ArgoCD syncs YAML files verbatim — it does not template raw manifests. A value shared between a Helm chart and a raw manifest requires manual synchronization.
- ADR-012 trust invariants (T1–T4) depend on configuration correctness. A drifted policy or identity-provider setting can silently break security without a visible error.
- A value consumed by two independently-templated resources has no compiler or schema to catch divergence — only convention and, where adopted, an explicit cross-reference.

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

When a value must appear in both a Helm chart and a raw manifest (e.g., the Keycloak issuer URL — templated from `infra/helm/keycloak/values.yaml`'s `hostname` into `KC_HOSTNAME`, which becomes the JWT `iss` claim, and hardcoded in `request-authentication.yaml`'s `jwtRules[].issuer`), annotate the raw manifest with a machine-readable sync marker:

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

# infra/helm/keycloak/values.yaml
hostname: "keycloak.example.com"  # oops, different — iss claim no longer matches
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
| `infra/k8s/istio/request-authentication.yaml` | `issuer-sync` annotation cross-referencing `infra/helm/keycloak/values.yaml` (`hostname`) |
| `infra/helm/opa/policies/allow.rego` | Single canonical Rego source — no ConfigMap duplication |

---

## References

- OPA policy drift finding (security review, 2026-03-02)
- Helm Files.Get: https://helm.sh/docs/chart_template_guide/accessing_files/
