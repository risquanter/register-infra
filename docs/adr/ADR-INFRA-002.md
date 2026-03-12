# ADR-INFRA-002: Fail-Closed Components Require Availability Guarantees

**Status:** Accepted  
**Date:** 2026-03-05  
**Tags:** availability, opa, security, pdb, fail-closed, namespace-isolation

---

## Context

- OPA runs with `failure_mode_deny: true` — if OPA is unreachable, the Envoy ext_authz filter returns 403 for **every** request
- A single-replica Deployment causes total service outage during pod restarts (rolling update, OOM kill, node drain)
- The fail-closed posture is architecturally correct (ADR-012, THREAT-CATALOG) — changing it to fail-open is not acceptable
- The consequence: availability of fail-closed components directly equals service availability
- OPA currently runs in the `register` namespace alongside application pods — a compromised application pod shares the same namespace, HBONE trust boundary, and Ambient intra-namespace connectivity as OPA

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

### 4. OPA Namespace Isolation — Future Improvement (Not Yet Implemented)

OPA should be moved to a dedicated `opa-system` namespace in a future iteration. This is recorded as a decision point to prevent drift, not as a currently implemented pattern.

**Rationale**: OPA is the authorization decision point. A compromised pod in the `register` namespace can currently reach OPA through the HBONE tunnel (port 15008 intra-namespace). Moving OPA to a separate namespace converts this from an intra-namespace flow (HBONE, ztunnel-only gating) to a cross-namespace flow (Cilium NetworkPolicy enforceable at L3/L4).

**What changes when implemented**:

```yaml
# OPA moves to its own namespace with STRICT PeerAuthentication
apiVersion: v1
kind: Namespace
metadata:
  name: opa-system
  labels:
    istio.io/dataplane-mode: ambient
---
# Cross-namespace NetworkPolicy: only waypoint in register ns can reach OPA
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-waypoint-to-opa
  namespace: opa-system
spec:
  podSelector:
    matchLabels:
      app: opa
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: register
          podSelector:
            matchLabels:
              gateway.networking.k8s.io/gateway-name: waypoint
      ports:
        - { protocol: TCP, port: 8282 }
```

**Why not implemented now**: OPA co-location in `register` namespace reduces latency (ext_authz on every request), simplifies ArgoCD project scoping, and avoids cross-namespace HBONE complexity. The current waypoint (once deployed, see ADR-INFRA-004 §3) provides L7 gating on all traffic entering application pods — OPA compromise via HBONE is mitigated at L7 before reaching OPA. See [ADR-INFRA-002-appendix](ADR-INFRA-002-appendix.md) for the full analysis.

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

### ❌ Fail-Closed Component Without Namespace Isolation Plan

```yaml
# BAD: OPA in same namespace as application pods, no documented
# rationale or planned migration path. If asked "why is OPA
# co-located?", the answer should be traceable to a decision.
metadata:
  name: opa
  namespace: register   # same as application pods
# (no ADR documenting this choice)
```

```yaml
# GOOD: co-location documented with explicit future migration plan
metadata:
  name: opa
  namespace: register   # ADR-INFRA-002 §4: co-located for latency;
                        # migration to opa-system planned
```

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/helm/opa/values.yaml` | `replicaCount: 2` |
| `infra/helm/opa/templates/pdb.yaml` | PDB with `minAvailable: 1` |
| `infra/k8s/opa/ext-authz-filter.yaml` | `failure_mode_deny: true` with consequence comment |
| `infra/helm/opa/values.yaml` (planned) | `namespace: opa-system` when §4 is implemented |

---

## References

- THREAT-CATALOG T2 (JWT validation, fail-closed by design)
- ADR-012 §7 trust invariants
- Security review finding H5 (OPA single replica)
- ADR-INFRA-004 §2, §3 (HBONE intra-namespace scope, waypoint requirement)
- [ADR-INFRA-002-appendix](ADR-INFRA-002-appendix.md) — OPA namespace isolation analysis
