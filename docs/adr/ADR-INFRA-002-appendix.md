# ADR-INFRA-002 Appendix: OPA Namespace Isolation Analysis

This appendix provides the full technical analysis behind Decision §4 in
[ADR-INFRA-002](ADR-INFRA-002.md) — the decision to plan OPA namespace isolation
as a future improvement while maintaining co-location in the `register` namespace
for now.

---

## 1. Why OPA Namespace Placement Matters

OPA is the authorization decision point. The Envoy waypoint proxy calls OPA via
ext_authz on every HTTP request. OPA evaluates Rego policies and returns
allow/deny. With `failure_mode_deny: true`, OPA unavailability means all requests
receive 403 — total service outage.

This makes OPA a high-value target. If an attacker compromises OPA, they can:

1. **Modify policy responses** — return `allow` for all requests, bypassing authorization entirely
2. **Exfiltrate request data** — OPA receives the full HTTP request context (headers, path, method) for every inbound request
3. **Cause denial of service** — crash OPA, triggering fail-closed 403 on all requests

The question is: does OPA's namespace placement affect the difficulty of these attacks?

---

## 2. Current State: OPA in the `register` Namespace

OPA runs as a Deployment in the `register` namespace alongside register, irmin,
and frontend. In Istio Ambient mode, this means:

- **HBONE tunnel**: all pods in `register` can reach OPA on port 8282 through the
  intra-namespace HBONE tunnel (port 15008). Cilium sees port 15008, not 8282.
- **ztunnel gating**: connections require a valid SPIFFE certificate. Only mesh-enrolled
  pods with a Service Account in the `register` namespace get certificates.
- **Waypoint L7**: once deployed (ADR-INFRA-004 §3), the waypoint can enforce which
  Service Accounts may reach OPA and on which paths.

### Attack path (current)

A compromised pod (e.g., frontend after RCE) can reach OPA directly through HBONE:

```
frontend (compromised) → HBONE :15008 → ztunnel → OPA :8282
```

ztunnel checks: is `spiffe://cluster.local/ns/register/sa/frontend` a valid mesh
identity? Yes. Connection allowed at L4.

Without waypoint: OPA receives the connection. The attacker can send crafted
requests to OPA's API.

With waypoint: the waypoint evaluates whether `sa/frontend` is authorized to
reach OPA on port 8282. If the AuthorizationPolicy restricts OPA access to
`sa/waypoint` only, the compromised frontend's request is denied at L7.

---

## 3. Target State: OPA in a Dedicated `opa-system` Namespace

Moving OPA to `opa-system` changes the network topology fundamentally:

```
waypoint (register ns) → cross-namespace TCP :8282 → OPA (opa-system ns)
```

This is no longer an intra-namespace HBONE flow. It is a cross-namespace connection
where Cilium operates on the actual application port:

- **Cilium enforces**: NetworkPolicy in `opa-system` can specify exactly which pods
  (by namespace + label) may reach OPA on port 8282
- **ztunnel enforces**: SPIFFE identity check across namespace boundaries
- **No HBONE ambiguity**: cross-namespace traffic in Ambient mode uses direct TCP
  between ztunnel instances, with Cilium seeing the real destination port

### Attack path (target)

A compromised frontend pod attempts to reach OPA:

```
frontend (compromised, register ns) → Cilium → DENIED
```

Cilium checks: does any NetworkPolicy in `opa-system` allow ingress from
`namespace: register, pod: frontend` on port 8282? No — only waypoint is allowed.
Connection dropped at L3/L4 before reaching ztunnel.

Even if the attacker could somehow bypass Cilium (e.g., by exploiting a Cilium
vulnerability), ztunnel would still verify the SPIFFE identity, and the
`opa-system` PeerAuthentication STRICT policy would require a valid certificate.

---

## 4. Why Not Move OPA Now?

### Latency

The Envoy ext_authz call happens on every HTTP request. OPA co-location in the same
namespace means the ext_authz call traverses the local HBONE tunnel — minimal
latency. Moving OPA cross-namespace adds:

- Cross-node network hop (if OPA lands on a different node)
- Additional ztunnel processing at both ends
- Cilium NetworkPolicy evaluation overhead

For a security-critical call on every request, latency matters.

### ArgoCD Project Scoping

The current ArgoCD project structure (ADR-INFRA-003) scopes the `platform` project
to specific namespaces. Adding `opa-system` requires extending the project scope
or creating a new project, adding configuration complexity.

### Cross-Namespace HBONE Complexity

Cross-namespace HBONE traffic requires careful NetworkPolicy configuration.
The `opa-system` namespace needs its own default-deny, HBONE allow (for
cross-namespace ztunnel), and targeted ingress rules. Misconfiguration could
cause OPA to become unreachable — triggering fail-closed 403 on all requests.

### Waypoint Mitigates the Current Risk

Once the waypoint is deployed (ADR-INFRA-004 §3), it provides L7 gating on all
traffic entering pods in the `register` namespace. An AuthorizationPolicy can
restrict which Service Accounts may reach OPA:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: opa-access
  namespace: register
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: waypoint
  action: ALLOW
  rules:
    - to:
        - operation:
            ports: ["8282"]
      from:
        - source:
            principals:
              - "cluster.local/ns/register/sa/waypoint"
```

This means only the waypoint's own Service Account can reach OPA — not frontend,
not register, not irmin. The waypoint calls OPA as part of processing incoming
requests, so `sa/waypoint` is the correct (and only necessary) caller.

---

## 5. Does OPA Compromise Matter Regardless of Namespace?

A critical nuance: OPA compromise is catastrophic regardless of where OPA runs.

If an attacker gains code execution inside the OPA pod:

- They control all authorization decisions for the entire application
- They can return `allow` for every request
- They can read every request's context (headers, path, user identity)

No amount of namespace isolation changes this. Namespace isolation affects the
**difficulty of reaching OPA**, not the **impact of OPA compromise**.

The defense-in-depth model is:

1. **Prevent OPA compromise** — distroless image, read-only filesystem, no shell,
   minimal attack surface, regular image updates
2. **Limit who can reach OPA** — waypoint L7 (now), cross-namespace Cilium (future)
3. **Detect OPA compromise** — audit logging, policy change detection (future)

Namespace isolation is step 2: making it harder for a compromised application pod
to reach OPA. It is a meaningful improvement but not a silver bullet.

---

## 6. Implementation Plan (When Ready)

When the decision is made to implement §4:

| Step | Action |
|------|--------|
| 1 | Create `opa-system` namespace with `istio.io/dataplane-mode: ambient` label |
| 2 | Add PeerAuthentication STRICT in `opa-system` |
| 3 | Add default-deny NetworkPolicy in `opa-system` |
| 4 | Add allow-ingress from `register` namespace waypoint pod on port 8282 |
| 5 | Add DNS egress and kube-apiserver egress (OPA bundles) |
| 6 | Update OPA Helm chart namespace to `opa-system` |
| 7 | Update ArgoCD Application `destination.namespace` |
| 8 | Update or create ArgoCD Project to include `opa-system` |
| 9 | Update ext_authz filter cluster address to `opa.opa-system.svc.cluster.local:8282` |
| 10 | Test: verify ext_authz calls succeed cross-namespace |
| 11 | Test: verify fail-closed behavior (delete OPA → 403) |
| 12 | Update ADR-INFRA-002 §4 status from "planned" to "implemented" |

---

## 7. Decision Summary

| Factor | Co-located (current) | Isolated (future) |
|--------|:---:|:---:|
| ext_authz latency | Lower (same-node likely) | Higher (cross-namespace) |
| Cilium enforcement | ❌ HBONE tunnel (port 15008) | ✅ Real port 8282 visible |
| ArgoCD complexity | Simpler (one namespace) | Additional project/scope |
| Waypoint L7 gating | ✅ Service Account restriction | ✅ + Cilium L3/L4 |
| Attack difficulty | Requires SPIFFE + waypoint bypass | Requires Cilium + SPIFFE + waypoint bypass |
| Impact of OPA compromise | Catastrophic | Catastrophic (unchanged) |
