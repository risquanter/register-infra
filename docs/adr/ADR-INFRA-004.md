# ADR-INFRA-004: Defense-in-Depth — Layered Network and Identity Controls

**Status:** Accepted  
**Date:** 2026-03-05  
**Tags:** network-policy, peer-authentication, mtls, defense-in-depth

---

## Context

- Istio mTLS (PeerAuthentication) and Kubernetes NetworkPolicy operate at different layers — mTLS is identity-based (SPIFFE), NetworkPolicy is L3/L4 label-based
- Neither alone is sufficient: mTLS without NetworkPolicy allows any meshed pod to reach any other; NetworkPolicy without mTLS allows plaintext connections from non-meshed pods
- THREAT-CATALOG T1 (mesh bypass prevention) requires **both** layers simultaneously
- The `register` namespace has default-deny NetworkPolicy but no PeerAuthentication; the `infra` namespace has neither

---

## Decision

### 1. Both Layers Required for Critical Namespaces

Every namespace containing application or infrastructure workloads must have:
- **NetworkPolicy**: default-deny-all + targeted allow rules (L3/L4)
- **PeerAuthentication**: STRICT mode (mTLS identity enforcement)

### 2. Per-Namespace PeerAuthentication Before Mesh-Wide

Apply PeerAuthentication STRICT to individual namespaces first (`register`, `argocd`). Promote to mesh-wide (istio-system) only when all namespaces are enrolled and tested — specifically after verifying the `infra` namespace (PostgreSQL + Keycloak) survived ztunnel + STRICT without probe failures.

### 3. DNS Egress Always Allowed

Every default-deny namespace must include a DNS egress rule. Without it, pods cannot resolve service names, causing opaque connection failures.

```yaml
# Required in every namespace with default-deny egress
egress:
  - to: []
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
```

---

## Code Smells

### ❌ NetworkPolicy Without PeerAuthentication

```yaml
# BAD: L3/L4 deny-all but no mTLS — a non-meshed pod matching labels can
# still connect via plaintext
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: register
# (no PeerAuthentication in namespace)
```

```yaml
# GOOD: both layers
# NetworkPolicy: default-deny + allow rules
# PeerAuthentication: mode: STRICT
```

### ❌ Default-Deny Without DNS Egress

```yaml
# BAD: all egress denied including DNS — pods can't resolve service names
policyTypes:
  - Egress
# (no DNS egress rule)
```

```yaml
# GOOD: DNS egress explicitly allowed
egress:
  - to: []
    ports:
      - { protocol: UDP, port: 53 }
      - { protocol: TCP, port: 53 }
```

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/k8s/network-policy/register.yaml` | Default-deny + allow rules + DNS egress for register ns |
| `infra/k8s/network-policy/infra.yaml` | Default-deny + allow rules + DNS egress for infra ns |
| `infra/k8s/istio/peer-authentication.yaml` | STRICT mTLS for register + argocd namespaces |

---

## References

- THREAT-CATALOG T1 (mesh bypass prevention, status: open)
- ADR-012 §7 trust invariant T1
- CIS Kubernetes Benchmark 5.3 (Network Policies)
