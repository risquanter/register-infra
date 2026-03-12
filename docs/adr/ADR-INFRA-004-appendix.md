# ADR-INFRA-004 Appendix: Ambient Mesh Security Model Deep-Dive

This appendix provides the full technical analysis behind the decisions in
[ADR-INFRA-004](ADR-INFRA-004.md). It covers the Istio Ambient enforcement
architecture, attack scenarios at each layer, and the reasoning for requiring
waypoint deployment in all environments.

---

## 1. Key Concepts

### Service Account

A Kubernetes ServiceAccount is a namespace-scoped identity attached to every pod.
When a Deployment specifies `serviceAccountName: register`, every pod in that
Deployment runs as that identity. In Istio Ambient, ztunnel uses the Service
Account to request a SPIFFE certificate from the Istio CA. Pods with different
Service Accounts get different certificates — this is the basis for all
identity-based access control.

### SPIFFE Identity

SPIFFE (Secure Production Identity Framework for Everyone) assigns each workload
an identity encoded as a URI:

```
spiffe://cluster.local/ns/register/sa/register
```

The certificate is short-lived (24h default, auto-rotated), signed by the Istio
mesh CA, and tied to the Service Account. When pod A connects to pod B, both
present their SPIFFE certificates via mTLS. Each side verifies the other's
identity before allowing the connection. PeerAuthentication STRICT means "reject
any connection that does not present a valid SPIFFE certificate."

### HBONE (HTTP-Based Overlay Network Encapsulation)

HBONE is the transport mechanism in Istio Ambient mode. When register connects to
irmin on port 8080:

1. The register pod sends a plain TCP connection to irmin:8080
2. ztunnel on the source node intercepts the connection transparently
3. ztunnel wraps it inside an HTTP/2 CONNECT tunnel (HBONE) encrypted with mTLS
4. The HBONE tunnel connects to the destination node's ztunnel on **port 15008**
5. The destination ztunnel unwraps the tunnel and delivers plaintext TCP to irmin:8080

Cilium (the CNI) only sees the outer tunnel: TCP to port 15008 between node IPs (or
pod IPs in same-node scenarios). It cannot see that the original connection was to
irmin:8080. Per-service NetworkPolicy rules that specify application ports are
therefore non-functional for intra-namespace traffic in Ambient mode.

### Waypoint Proxy

A waypoint is a per-namespace Envoy proxy deployed as a Kubernetes Gateway resource.
It handles all L7 HTTP processing for pods in its namespace:

- JWT token validation (RequestAuthentication)
- HTTP header inspection and stripping (EnvoyFilter)
- OPA external authorization (ext_authz filter)
- Path-based authorization (AuthorizationPolicy)

Without a waypoint, only L4 (ztunnel) and L3 (Cilium) controls are active. L7
policies exist in the cluster as YAML resources but are not evaluated — they are
bound to the waypoint, which is the only component that processes them.

---

## 2. Enforcement Layer Architecture

```
                          ┌──────────────────────┐
    Internet ─────────────▶   Istio Gateway (L7)  │  TLS termination
                          │   (ingress-gateway)   │  + route to waypoint
                          └──────────┬───────────┘
                                     │
                          ┌──────────▼───────────┐
                          │   Waypoint Proxy (L7) │  JWT, header strip,
                          │   gateway/waypoint    │  OPA ext_authz,
                          │                       │  path-based AuthZ
                          └──────────┬───────────┘
                                     │  plaintext HTTP
                          ┌──────────▼───────────┐
    Source ztunnel ────────▶  Dest ztunnel (L4)   │  SPIFFE identity check
    (HBONE port 15008)    │                       │  PeerAuthentication STRICT
                          └──────────┬───────────┘
                                     │  plaintext TCP
                          ┌──────────▼───────────┐
                          │   Application Pod     │  register / irmin / frontend
                          └──────────────────────┘

    Cilium NetworkPolicy (L3/L4) operates at the bottom of the stack:
    - Cross-namespace: enforces label-based rules on direct TCP connections
    - Intra-namespace: sees HBONE tunnel on port 15008, not application ports
```

### What Each Layer Prevents

| Attack vector | Cilium (L3/L4) | ztunnel (L4) | Waypoint (L7) |
|---------------|:---:|:---:|:---:|
| Pod in `infra` ns → register:8090 | ✅ blocked by default-deny + no allow rule | — | — |
| Non-mesh process in `register` ns → irmin:8080 | ❌ sees HBONE port, not 8080 | ✅ rejects non-SPIFFE | — |
| Compromised frontend → register:8090 (forged headers) | ❌ HBONE tunnel, both are mesh-enrolled | ❌ valid SPIFFE cert | ✅ strips headers, validates JWT |
| Compromised frontend → irmin:8080 (direct) | ❌ HBONE tunnel | ❌ valid SPIFFE cert | ✅ waypoint AuthZ denies path |

---

## 3. Attack Scenarios

These scenarios illustrate why each layer matters. All assume the adversary has
achieved remote code execution (RCE) inside a pod in the `register` namespace.

### Scenario A: RCE in Frontend, No Waypoint Deployed

The attacker has shell access inside the frontend nginx pod.

1. Attacker runs `curl -H "x-user-id: admin" http://register:8090/api/entries`
2. DNS resolves. ztunnel intercepts and wraps in HBONE (mTLS)
3. Cilium sees port 15008 → allowed by `allow-hbone-intra-namespace`
4. Destination ztunnel checks SPIFFE identity: `spiffe://cluster.local/ns/register/sa/frontend` — valid mesh identity, connection allowed
5. No waypoint exists. No L7 processing. The forged `x-user-id: admin` header reaches register unmodified
6. Register trusts the header (capability-only auth mode) → **full admin access**

**Result**: total compromise. The attacker reads/writes all data.

### Scenario B: RCE in Frontend, Waypoint Deployed

Same starting point — shell access in frontend.

1. Attacker runs `curl -H "x-user-id: admin" http://register:8090/api/entries`
2. ztunnel intercepts. Traffic is routed through the waypoint before reaching register
3. Waypoint evaluates:
   - RequestAuthentication: no valid JWT → `x-user-id` header cannot be trusted
   - EnvoyFilter: strips `x-user-id` header from the request
   - OPA ext_authz: evaluates the (now headerless) request against policy
4. The request arrives at register without `x-user-id` → treated as anonymous

**Result**: attack neutralized at L7. The forged header is stripped.

### Scenario C: Legitimate User with Capability URL

A non-compromised user sends a read request using a capability URL.

1. Browser requests `https://register.example.com/w/abc123`
2. Istio Gateway terminates TLS, routes to waypoint
3. Waypoint: no JWT required for `/w/*` paths (AuthorizationPolicy exception)
4. Register validates the capability token `abc123` against its database
5. If valid: returns the entry. If invalid: 404

**Result**: the capability URL is the credential. No JWT, no `x-user-id`. This path works identically with or without waypoint because the AuthorizationPolicy explicitly allows it.

### Scenario D: Why Per-Service NetworkPolicy Cannot Substitute for Waypoint

Even with hypothetical perfect per-service Cilium rules (i.e., if Cilium could see inside HBONE):

1. Frontend **must** reach register:8090 — this is its primary function
2. A Cilium rule `frontend → register:8090 ALLOW` would be required
3. An attacker in frontend uses this same allowed path to forge headers
4. Cilium operates at L3/L4 — it cannot inspect HTTP headers or strip them
5. Only an L7 proxy (waypoint) can distinguish legitimate frontend traffic from forged requests

**Conclusion**: NetworkPolicy alone can never prevent header forgery. The waypoint is the only component capable of L7 inspection within the mesh. Even in a theoretical world where Cilium could filter per-service inside HBONE, it would still not prevent this attack class.

---

## 4. Threat T5: Intra-Namespace Lateral Movement

The HBONE allow-intra-namespace rule creates an accepted risk:

**T5 — Intra-namespace lateral movement via HBONE tunnel**

Any mesh-enrolled pod in the `register` namespace can initiate connections to any
other pod in the same namespace. This is inherent to the Ambient architecture: HBONE
port 15008 must be open for any intra-namespace communication to function.

### Mitigations

| Control | What it prevents |
|---------|-----------------|
| PeerAuthentication STRICT | Non-mesh processes cannot connect (no SPIFFE cert) |
| Waypoint L7 policy | Forged headers stripped, JWT validated, OPA evaluates |
| Minimal service accounts | Each component (register, irmin, frontend) has its own SA — AuthorizationPolicy can distinguish them |
| Read-only root filesystem | Limits post-exploitation persistence on irmin and register |
| Distroless images | No shell, no package manager — limits attacker capabilities |

### Residual Risk

Without waypoint: a compromised pod with a valid SPIFFE identity can reach any
same-namespace pod on any port through the HBONE tunnel. The only protection is
ztunnel's SPIFFE check (which passes for any mesh-enrolled pod in the namespace).

With waypoint: the compromised pod's traffic passes through L7 inspection. The
waypoint strips forged headers and validates JWT tokens. The attack surface is
reduced to paths and methods explicitly allowed by AuthorizationPolicy for that
Service Account's SPIFFE identity.

---

## 5. k3d vs Production Environment Comparison

The difference between local (k3d) and production (Hetzner) is not platform
capability — both run Cilium + Istio Ambient. The difference is what components
are deployed.

| Component | k3d (current) | k3d (target) | Hetzner |
|-----------|:---:|:---:|:---:|
| Cilium CNI | ✅ | ✅ | ✅ |
| Istio Ambient (ztunnel) | ✅ | ✅ | ✅ |
| PeerAuthentication STRICT | ✅ | ✅ | ✅ |
| NetworkPolicy default-deny | ✅ | ✅ | ✅ |
| HBONE intra-namespace | ✅ | ✅ | ✅ |
| Waypoint proxy | ❌ | ✅ | ✅ |
| cert-manager + ACME | ❌ | ❌ | ✅ |
| Istio Gateway (ingress) | ❌ | ❌ | ✅ |
| Keycloak (JWT issuer) | ❌ | ❌ | ✅ |

"k3d (target)" reflects the decision in ADR-INFRA-004 §3: waypoint deployed
locally as one of the final LOCAL-K3D-BOOTSTRAP steps.

---

## 6. HBONE Discovery Timeline

The HBONE port 15008 requirement was discovered empirically during cluster
synchronization work. The sequence:

1. Register pods entered CrashLoopBackOff with log: `"Irmin health check timed out after 5000 ms"`
2. irmin was confirmed listening (loopback curl returned HTTP 400)
3. NetworkPolicy labels verified correct
4. AuthorizationPolicy `selector: {}` found to cause ztunnel implicit deny — fixed with `targetRef: Gateway/waypoint`
5. Still timing out after AuthorizationPolicy fix
6. ztunnel access logs revealed: `"connection timed out, maybe a NetworkPolicy is blocking HBONE port 15008"`
7. Root cause confirmed: default-deny-all blocks port 15008. Cilium sees HBONE tunnel port, not application port
8. Fix: `allow-hbone-intra-namespace` NetworkPolicy allowing TCP 15008 within register namespace

This discovery validated that per-service application-port NetworkPolicy rules
(e.g., "register → irmin on 8080") are topology documentation, not enforceable
controls, in Ambient mode. The ADR was updated to reflect this architectural reality.
