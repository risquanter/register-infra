# Request Security Flow — Single Node k3s

> Interview reference: how a client request is authenticated, authorized, and
> how identity headers are propagated. Single-node layout.

---

## ASCII architecture

```
 CLIENT
   │
   │  HTTPS (TLS 1.3)
   │  Bearer: <JWT>
   │
   ▼
╔══════════════════════════════════════════════════════════════════════╗
║  NODE (Debian VM — single k3s instance)                              ║
║                                                                      ║
║  ┌─────────────────────────────────────────────────────────────────┐ ║
║  │  register namespace  (PSS: restricted, mesh-enrolled)           │ ║
║  │                                                                  │ ║
║  │  ┌──────────────────────────────────────────────────────────┐   │ ║
║  │  │  WAYPOINT PROXY  (Envoy, L7)                             │   │ ║
║  │  │                                                          │   │ ║
║  │  │  1. Strip x-user-id / x-user-email / x-user-roles       │   │ ║
║  │  │     from ALL inbound requests           [EnvoyFilter]    │   │ ║
║  │  │                                                          │   │ ║
║  │  │  2. Validate JWT signature + expiry                      │   │ ║
║  │  │     against Keycloak JWKS endpoint   [RequestAuthn]      │   │ ║
║  │  │     → cached public keys, no per-request Keycloak call   │   │ ║
║  │  │                                                          │   │ ║
║  │  │  3. Enforce: request must have a validated JWT principal  │   │ ║
║  │  │     ("*" requestPrincipal = any valid JWT)  [AuthzPolicy] │   │ ║
║  │  │     No valid JWT → 401, request dropped here             │   │ ║
║  │  │                                                          │   │ ║
║  │  │  4. Deny if x-user-id still present after strip step     │   │ ║
║  │  │     (defence in depth — catch bypass paths) [AuthzPolicy] │   │ ║
║  │  │                                                          │   │ ║
║  │  │  5. Inject x-user-id  ← JWT.sub                         │   │ ║
║  │  │         x-user-email  ← JWT.email                       │   │ ║
║  │  │         x-user-roles  ← JWT.roles claim                  │   │ ║
║  │  └──────────────────────┬───────────────────────────────────┘   │ ║
║  │                          │  mTLS  (ztunnel, L4)                  │ ║
║  │                          │  + NetworkPolicy: only waypoint        │ ║
║  │                          │  may reach app pods   [Cilium]         │ ║
║  │                          ▼                                        │ ║
║  │  ┌───────────────────────────────────────┐                       │ ║
║  │  │  register-app  (Scala / ZIO)          │                       │ ║
║  │  │                                       │                       │ ║
║  │  │  Trusts x-user-id header — set by     │                       │ ║
║  │  │  waypoint only; unreachable externally │                       │ ║
║  │  │                                       │                       │ ║
║  │  │  Layer 0: workspace key in URL        │                       │ ║
║  │  │  Layer 1: + valid x-user-id (JWT)     │                       │ ║
║  │  │  Layer 2: + SpiceDB relationship      │ (future)              │ ║
║  │  └──────────┬────────────────────────────┘                       │ ║
║  │             │ only egress allowed by NetworkPolicy [Cilium]       │ ║
║  └─────────────┼────────────────────────────────────────────────────┘ ║
║                │                                                      ║
║                │   plain TCP (cluster-internal, no mesh enrollment)   ║
║                ▼                                                      ║
║  ┌──────────────────────────────────────┐                            ║
║  │  infra namespace  (PSS: baseline)    │                            ║
║  │                                      │                            ║
║  │  ┌──────────────┐  ┌──────────────┐  │                            ║
║  │  │  PostgreSQL  │  │  Keycloak    │  │                            ║
║  │  │  :5432       │  │  :80         │  │                            ║
║  │  │              │  │              │  │                            ║
║  │  │  app data +  │  │  issues JWTs │  │                            ║
║  │  │  Keycloak DB │  │  owns JWKS   │  │                            ║
║  │  └──────────────┘  └──────────────┘  │                            ║
║  └──────────────────────────────────────┘                            ║
╚══════════════════════════════════════════════════════════════════════╝
```

---

## What is encrypted, and where

| Segment | Encrypted? | Mechanism |
|---|---|---|
| Client → node | **Yes** | TLS 1.3 (cert-manager CA or external cert) |
| Waypoint → app pod (intra-namespace) | **Yes** | Istio ztunnel mTLS (SPIFFE/X.509, HBONE tunnel) |
| App → PostgreSQL | **Yes** | Istio ztunnel mTLS — infra namespace enrolled in ambient |
| App → Keycloak | **Yes** | Istio ztunnel mTLS — infra namespace enrolled in ambient |
| etcd secrets at rest | **Yes** | k3s secrets-encryption provider (AES-CBC) |

> **Single-node footnote**: ztunnel mTLS encrypts at the Linux network namespace
> boundary, not at the physical wire. On a single node this protects against
> inter-pod traffic sniffing (e.g. a compromised CNI plugin reading a capture),
> not against a fully compromised kernel. The threat model documents this
> explicitly (T-NodeCompromise).
>
> **Rollback**: if enrolling the infra namespace causes PostgreSQL or Keycloak
> probe failures, remove the label (`kubectl label namespace infra
> istio.io/dataplane-mode-`) and the segment reverts to plain TCP. See the
> install guide §1.4 for the full rollback procedure.

---

## Credential validation — where each check lives

```
① JWT SIGNATURE  →  Waypoint (Envoy) — RequestAuthentication
                     Istio pulls Keycloak JWKS on startup + refreshes periodically.
                     No Keycloak call happens on the hot path.
                     Checks: signature, issuer URL, expiry (exp), not-before (nbf).

② JWT PRINCIPAL  →  Waypoint (Envoy) — AuthorizationPolicy (require-jwt)
                     "requestPrincipal must be set" → fails if ① found no valid JWT.
                     Default deny: if no ALLOW rule matches, request is rejected.

③ HEADER STRIP   →  Waypoint (Envoy) — EnvoyFilter (runs before ①②)
                     x-user-id / x-user-email / x-user-roles removed unconditionally.
                     Prevents client forgery of identity headers.

④ HEADER DENY    →  Waypoint (Envoy) — AuthorizationPolicy (deny-forwarded-identity-headers)
                     If x-user-id is still present after ③ (bypass path), request is denied.
                     Defence in depth.

⑤ ROLE GATE      →  OPA (standalone pod) — ext_authz gRPC filter on waypoint
                     Evaluates: JWT role claims + HTTP method + path (Rego policy).
                     Questions answered:
                       - Does the JWT carry a recognised role (analyst/editor/team_admin)?
                       - Is a write method called by a viewer-only caller?
                       - Is a cache admin endpoint called without team_admin claim?
                     fail-closed: OPA pod unavailable → 403 (not allow).
                     sub-millisecond: purely CPU-bound Rego evaluation, no DB call.
                     Security team override layer: Rego policy changes push without
                     an application deployment (emergency write blocks, audit mandates).

⑥ WORKSPACE KEY  →  Application (Scala/ZIO)
                     Layer 0: workspace key in URL = sole credential (free tier).
                     Layer 1: key is an invitation token; x-user-id (from ①–③) also required.

⑦ INSTANCE AUTHZ →  SpiceDB (app layer — future Layer 2)
                     Application calls SpiceDB.check(userId, permission, resourceRef).
                     Questions answered:
                       - Is this specific user a member of this specific workspace?
                       - Does the user have design_write on this specific risk_tree?
                     OPA AND SpiceDB: both must allow. OPA deny = 403 (SpiceDB never called).
                     OPA allow + SpiceDB deny = 403. Neither unilaterally grants access.

⑧ NETWORK LAYER  →  Cilium (eBPF) — NetworkPolicy
                     Default deny-all on register namespace.
                     Explicit allow: waypoint → app pod (ingress).
                     Explicit allow: app pod → postgres:5432 (egress).
                     Explicit allow: app pod → keycloak:80 (egress).
                     Everything else dropped at the kernel level.
```

---

## The identity header trust chain (interview talking point)

The key design decision: **the application trusts `x-user-id` but cannot be reached by any process that can forge it.**

```
External client              Waypoint                    App
     │                          │                          │
     │── x-user-id: forged ──▶  │                          │
     │                          │  ③ strip                 │
     │                          │  ① validate JWT          │
     │                          │  ② check principal       │
     │                          │  inject x-user-id←JWT.sub│
     │                          │── x-user-id: <real> ──▶  │
     │                          │                          │
     │                                                     │
     │                                   ⑥ Cilium blocks   │
     │────────────────────────── direct ──────────────────✗│
                           (no path to app pod
                            except via waypoint)
```

The app pod's `x-user-id` header cannot be forged because:
1. The Cilium NetworkPolicy allows ingress to app pods only from the waypoint pod.
2. The EnvoyFilter strips any externally provided `x-user-id` before JWT checks run.
3. The waypoint only injects `x-user-id` after a valid JWT passes checks ①–②.

---

## Security properties in one sentence each (interview-ready)

- **Authentication**: Istio waypoint validates JWT cryptographic signature against cached Keycloak public keys — no session state, no per-request Keycloak round-trip.
- **Coarse authorization (OPA)**: OPA evaluates JWT role claims + HTTP method/path via Rego at the waypoint as an ext_authz filter — purely claim-based, sub-millisecond, deployable by the security team independently of the application.
- **Instance-level authorization (SpiceDB)**: The application calls SpiceDB with only the user ID and permission name; the relationship graph is the authoritative source, not JWT claims. OPA AND SpiceDB must both allow — neither can unilaterally grant access.
- **Infrastructure authorization (Cilium)**: Cilium enforces default-deny NetworkPolicy at the eBPF kernel layer; Istio enforces JWT principal existence at the L7 proxy layer — defence in depth at two independent layers.
- **Identity propagation**: The mesh writes the validated identity into request headers; the application reads headers only, never touches JWT parsing — clean separation of concerns.
- **Header forgery prevention**: EnvoyFilter strips identity headers unconditionally on ingress to the waypoint; Cilium ensures no other path to the app pod exists.
- **Secrets at rest**: k3s secrets-encryption encrypts all Kubernetes Secret objects in etcd using AES-CBC; SOPS/age encrypts all secret values before they are committed to git.
