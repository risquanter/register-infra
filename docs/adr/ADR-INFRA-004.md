# ADR-INFRA-004: Defense-in-Depth — Layered Network and Identity Controls

**Status:** Accepted  
**Date:** 2026-03-12  
**Tags:** network-policy, peer-authentication, mtls, defense-in-depth, ambient, hbone, waypoint

---

## Context

- Istio Ambient mode uses HBONE (HTTP-Based Overlay Network Encapsulation) on port 15008 for all intra-namespace pod-to-pod traffic — Cilium sees port 15008 (the tunnel), not the application port inside it
- Cilium NetworkPolicy and Istio PeerAuthentication operate at different layers with different scopes: NetworkPolicy is L3/L4 label-based; PeerAuthentication is SPIFFE identity-based (X.509 certificates issued per service account)
- A waypoint proxy is required for L7 enforcement (JWT validation, header stripping, OPA ext_authz) — without it, only L4 (mTLS identity) and L3 (Cilium) controls are active
- THREAT-CATALOG T1 (mesh bypass prevention) requires that no path to application pods exists that bypasses L7 policy enforcement
- Intra-namespace traffic between trusted application components (register, irmin, OPA, frontend) traverses HBONE — Cilium cannot inspect or filter individual flows inside the tunnel

---

## Decision

### 1. Three Enforcement Layers with Distinct Scopes

Each layer enforces a specific class of controls. No single layer is sufficient alone.

```
Layer   Enforcer              Scope                    What it controls
─────   ─────────────────     ──────────────────────   ───────────────────────────────
L3/L4   Cilium NetworkPolicy  Cross-namespace traffic  Which namespaces can reach which
                              Health probe paths       Kubelet probe SNAT (169.254.7.127)
                              HBONE transport allow    Port 15008 intra-namespace open

L4      ztunnel + PeerAuth    Intra-namespace traffic  SPIFFE identity verification (mTLS)
                              (HBONE tunnel)           Non-mesh processes cannot connect

L7      Waypoint proxy        HTTP-level enforcement   JWT validation, header stripping,
                              (all traffic to pods     OPA ext_authz, path-based AuthZ
                               in waypoint namespace)
```

### 2. HBONE Port 15008 Open Intra-Namespace, Identity-Gated by ztunnel

Cilium allows TCP port 15008 between all pods in the same namespace. Per-service application-port rules (e.g. "register → irmin on 8080") are retained as topology documentation but are not enforceable by Cilium in Ambient mode — the application port is inside the encrypted HBONE tunnel.

Intra-namespace access control is enforced by ztunnel (SPIFFE certificate verification) and the waypoint (L7 HTTP policy).

```yaml
# HBONE transport — required for any intra-namespace communication in Ambient
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-hbone-intra-namespace
spec:
  podSelector: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: register
      ports:
        - { protocol: TCP, port: 15008 }
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: register
      ports:
        - { protocol: TCP, port: 15008 }
```

### 3. Waypoint Proxy Required in All Environments (Including Local k3d)

A waypoint proxy must be deployed in the `register` namespace in every environment. Without a waypoint, L7 enforcement is completely absent — JWT validation, header stripping, and OPA ext_authz do not run. This applies equally to local development (k3d) and production (Hetzner).

The waypoint does not require TLS termination or external ingress — it processes intra-namespace traffic transparently once deployed as a Gateway resource.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: register
spec:
  gatewayClassName: istio-waypoint
```

> **Implementation status:** Not yet deployed. Scheduled as a final step in the
> LOCAL-K3D-BOOTSTRAP sequence. See [ADR-INFRA-004-appendix](ADR-INFRA-004-appendix.md)
> for the security analysis that motivated this decision.

### 4. PeerAuthentication STRICT Per Namespace

Every namespace containing application workloads must have PeerAuthentication STRICT. This ensures ztunnel rejects any connection from a process without a valid SPIFFE certificate.

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: register
spec:
  mtls:
    mode: STRICT
```

### 5. DNS Egress Always Allowed

Every default-deny namespace must include a DNS egress rule.

```yaml
egress:
  - to: []
    ports:
      - { protocol: UDP, port: 53 }
      - { protocol: TCP, port: 53 }
```

---

## Code Smells

### ❌ Per-Service NetworkPolicy Without HBONE Allow

```yaml
# BAD: allows register → irmin on port 8080, but Cilium sees port 15008
# (HBONE tunnel). This rule never matches. Traffic is silently dropped
# by default-deny-all. Debugging shows "connection timed out" with no
# Cilium or ztunnel errors — only ztunnel access logs reveal:
#   "maybe a NetworkPolicy is blocking HBONE port 15008"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-register-to-irmin
spec:
  egress:
    - to:
        - podSelector: { matchLabels: { app.kubernetes.io/name: irmin } }
      ports:
        - { protocol: TCP, port: 8080 }
# (no allow-hbone-intra-namespace rule exists)
```

```yaml
# GOOD: HBONE transport allowed; per-service rules retained as documentation
# allow-hbone-intra-namespace on port 15008 (see Decision §2)
# + per-service rules document intended topology
```

### ❌ AuthorizationPolicy with selector: {} in Ambient Mode

```yaml
# BAD: selector: {} targets all pods. ztunnel is L4-only and silently
# omits HTTP-attribute rules (requestPrincipals, paths). Result: ALLOW
# policy with zero effective rules → implicit deny on all L4 connections.
spec:
  selector: {}
  action: ALLOW
  rules:
    - from:
        - source: { requestPrincipals: ["*"] }
```

```yaml
# GOOD: targetRef scopes policy to the waypoint (L7). ztunnel ignores it.
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: waypoint
  action: ALLOW
  rules:
    - from:
        - source: { requestPrincipals: ["*"] }
```

### ❌ No Waypoint in Development Environment

```yaml
# BAD: local k3d has no waypoint. L7 enforcement is absent.
# A compromised pod can forge x-user-id headers and reach register
# directly through the HBONE tunnel — no stripping, no JWT check.
# Namespace has: ztunnel (L4) + Cilium (L3). Missing: waypoint (L7).
```

```yaml
# GOOD: waypoint deployed in all environments including local dev.
# L7 enforcement active: JWT validation, header stripping, OPA ext_authz.
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: register
spec:
  gatewayClassName: istio-waypoint
```

### ❌ NetworkPolicy Without PeerAuthentication

```yaml
# BAD: L3/L4 deny-all but no mTLS — a non-meshed process matching labels
# can connect via plaintext
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
# (no PeerAuthentication in namespace)
```

```yaml
# GOOD: both layers active
# NetworkPolicy: default-deny + HBONE allow + cross-namespace rules
# PeerAuthentication: STRICT
```

---

## Implementation

| Location | Pattern |
|----------|---------|
| `infra/k8s/network-policy/register.yaml` | Default-deny + HBONE allow + per-service rules (topology docs) + DNS egress |
| `infra/k8s/network-policy/infra.yaml` | Default-deny + allow rules + DNS egress for infra ns |
| `infra/k8s/istio/peer-authentication.yaml` | STRICT mTLS for register, argocd, and infra namespaces; port-level PERMISSIVE for health probe ports |
| `infra/k8s/istio/authorization-policy.yaml` | AuthorizationPolicy with `targetRef` → waypoint Gateway |
| `infra/k8s/istio/` (planned) | Waypoint Gateway resource for register namespace |

---

## Alternatives Rejected

### Cilium L7 Policy (CiliumNetworkPolicy with L7 rules)

- **What**: use CiliumNetworkPolicy L7 HTTP filtering to inspect inside the HBONE tunnel and enforce per-path rules at the CNI layer
- **Why rejected**: Cilium cannot inspect the encrypted HBONE tunnel contents. CiliumNetworkPolicy L7 rules apply to plaintext HTTP connections only. In Ambient mode, all intra-namespace traffic is HBONE-encapsulated. A future Tetragon/Cilium integration may provide L7 awareness of HBONE traffic, at which point per-service Cilium rules could become enforceable.

### Disable Ambient Mode (Use Sidecar Injection Instead)

- **What**: switch from Ambient mode to traditional sidecar mode. Each pod gets an Envoy sidecar that terminates mTLS and exposes the application port to Cilium in plaintext.
- **Why rejected**: sidecar mode increases memory footprint (~100 MB per pod), complicates init container ordering, and requires sidecar lifecycle management. Ambient mode is the strategic direction for Istio. The waypoint proxy provides equivalent L7 enforcement without per-pod sidecars.

### Open HBONE for All Namespaces

- **What**: allow port 15008 cluster-wide instead of per-namespace
- **Why rejected**: cross-namespace HBONE would allow any mesh-enrolled pod in any namespace to initiate connections to pods in the register namespace. Scoping to `namespaceSelector: register` limits HBONE-open traffic to the intra-namespace trust boundary. Cross-namespace traffic (register → infra) uses HBONE tunnels between ztunnel instances in each namespace, controlled by per-service Cilium rules and HBONE allow rules.

---

## References

- THREAT-CATALOG T1 (mesh bypass prevention)
- ADR-012 §7 trust invariants T1–T4
- [ADR-INFRA-009](ADR-INFRA-009.md) — BeyondCorp identity model: header stripping + mesh-injected identity
- CIS Kubernetes Benchmark 5.3 (Network Policies)
- [ADR-INFRA-004-appendix](ADR-INFRA-004-appendix.md) — deep-dive: HBONE security model, attack scenarios, and enforcement layer analysis
