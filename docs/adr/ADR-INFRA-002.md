# ADR-INFRA-002: Fail-Closed Components Require Availability Guarantees

**Status:** Accepted  
**Date:** 2026-03-05  
**Tags:** availability, opa, security, pdb, fail-closed

---

## Context

- OPA runs with `failure_mode_deny: true` — if OPA is unreachable, the Envoy ext_authz filter returns 403 for **every** request
- A single-replica Deployment causes total service outage during pod restarts (rolling update, OOM kill, node drain)
- The fail-closed posture is architecturally correct (ADR-012, THREAT-CATALOG) — changing it to fail-open is not acceptable
- The consequence: availability of fail-closed components directly equals service availability

---

## Decision

### 1. Minimum 2 Replicas for Fail-Closed Components

Any component configured with `failure_mode_deny: true` (or equivalent fail-closed semantics) must run at least 2 replicas in all environments, including dev.

```yaml
# values.yaml
replicaCount: 2
```

### 2. PodDisruptionBudget with minAvailable: 1

A PDB ensures voluntary disruptions (kubectl drain, rolling updates) never remove the last available pod.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: opa
```

### 3. Document Fail-Closed Dependencies in Comments

Every `failure_mode_deny: true` or equivalent setting must include a comment stating the availability consequence.

```yaml
# failure_mode_deny: true means OPA unavailability → 403, not allow.
# This is the fail-closed posture required by the threat model.
# Consequence: OPA must have ≥2 replicas + PDB (ADR-INFRA-002).
failure_mode_deny: true
```

---

## Code Smells

### ❌ Single Replica with Fail-Closed

```yaml
# BAD: one OPA pod + failure_mode_deny = outage during restarts
spec:
  replicas: 1
  # no PDB
```

```yaml
# GOOD: survives single-pod failure
spec:
  replicas: 2
# + PodDisruptionBudget with minAvailable: 1
```

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/helm/opa/values.yaml` | `replicaCount: 2` |
| `infra/helm/opa/templates/pdb.yaml` | PDB with `minAvailable: 1` |
| `infra/k8s/opa/ext-authz-filter.yaml` | `failure_mode_deny: true` with consequence comment |

---

## References

- THREAT-CATALOG T2 (JWT validation, fail-closed by design)
- ADR-012 §7 trust invariants
- Security review finding H5 (OPA single replica)
