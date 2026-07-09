# ADR-INFRA-013: External Ingress Datapath

**Status:** Accepted
**Date:** 2026-07-08
**Tags:** ingress, gateway-api, servicelb, kube-proxy, cilium, loadbalancer, network-policy, tls

---

## Context

- External traffic must reach the cluster and terminate at the Istio Gateway that
  fronts the frontend/API. ADR-INFRA-007 covers what happens *behind* the Gateway
  (SPA serving, routing); this ADR covers how external traffic *physically reaches* it.
- The cluster uses **Cilium as the CNI** (ADR-INFRA-004) and **Istio ambient** (ztunnel
  + waypoint). Both have opinions about the L3/L4 datapath, and they interact.
- Namespaces are **default-deny** (NetworkPolicy). A pod is unreachable — including from
  outside the cluster — unless an explicit allow rule names it.
- Local (k3d) and Hetzner (bare k3s VM) differ only in *how a cluster is provisioned* and
  *how a public IP/port is presented*; the in-cluster ingress mechanism should be identical.

---

## Decision

### 1. LoadBalancer via k3s servicelb (klipper); kube-proxy retained

The Istio Gateway (`gatewayClassName: istio`) auto-provisions a `Service` of type
`LoadBalancer`. **k3s servicelb (klipper)** assigns its `EXTERNAL-IP` and binds the node
port. **k3s kube-proxy is kept** (not disabled). Cilium runs as **CNI + NetworkPolicy
only** — `kubeProxyReplacement` is **not** enabled (see Alternatives Rejected).

### 2. HTTPS-only Gateway on :443 (no plaintext :80)

The Gateway terminates TLS on 443; there is no plaintext :80 listener — JWTs and
capability URLs (which are themselves credentials) must not cross the wire in cleartext.
The certificate comes from cert-manager: a **self-signed `ClusterIssuer` locally**, an
**ACME (Let's Encrypt) issuer on Hetzner** (the only environment-specific piece; see
TODO Multi-Environment Values Overlay). Manifests: `infra/k8s/istio/ingress-gateway.yaml`,
`infra/k8s/cert-manager/`.

### 3. `world → gateway:443` NetworkPolicy admits external traffic

Under default-deny, external LoadBalancer traffic arrives at the Gateway pod with Cilium
identity `world` and is dropped unless allowed. A single CiliumNetworkPolicy
(`allow-ingress-gateway-from-world`, `network-policy/register.yaml`) admits `world` to the
Gateway pod **on 443 only**. It is the *only* pod in the namespace with a `world` ingress
allow — the intended public front door. Everything else stays default-deny; L7 authz (JWT,
capability URLs, OPA ext_authz) is enforced by the waypoint *behind* the Gateway. Network
reachability ≠ authorization.

> **Hetzner note:** verify the external source is still identity `world` there; if the cloud
> LB path presents it as `host`/`remote-node`, extend `fromEntities` accordingly.

---

## Alternatives Rejected

### Cilium kube-proxy-replacement (`kubeProxyReplacement=true`)

- **What**: disable k3s kube-proxy and let Cilium own the full service datapath
  (ClusterIP/NodePort/LoadBalancer/hostPort) in eBPF.
- **Why rejected**: it **breaks Istio ambient**. With kpr enabled, istiod fails to start
  (`FailedCreatePodSandBox: context deadline exceeded`; stuck API sync), and ztunnel then
  cannot mount the CA cert istiod never creates. The documented coexistence flag
  `socketLB.hostNamespaceOnly=true` got istio-cni healthy but istiod/ztunnel still failed
  (verified 2026-07-08). kpr was initially reached for on the belief that external ingress
  was a broken *datapath*; it is not — the plain stack (kube-proxy + klipper + Cilium as CNI)
  delivers external LoadBalancer/NodePort traffic fine (bare nginx LB → `curl :8080 → 200`).
  The real cause of the earlier `curl → 000` was Decision §3 missing (default-deny dropped
  `world` to the Gateway pod), not the datapath. **Keep kube-proxy; do not enable kpr.**

### Plaintext HTTP :80 ingress

- **What**: expose the Gateway on :80 (simpler, no cert locally).
- **Why rejected**: sends credentials/JWTs/capability URLs in cleartext — unacceptable for
  a CRA/KRITIS-relevant posture. HTTPS-only; an HTTP→HTTPS 301-redirect listener is an
  optional future browser-UX nicety, never a content listener.

### NodePort-only / kubectl port-forward (no ingress Gateway)

- **What**: skip the LoadBalancer Gateway; reach services via NodePort or port-forward.
- **Why rejected**: port-forward is not a usable product surface (see TODO L2 Step 5 —
  "usable exposure"); NodePort alone offers no TLS termination, no L7 policy, no single
  front door. The Gateway is required for a real, secure external entry point.

---

## References

- [ADR-INFRA-004](ADR-INFRA-004.md) — defense-in-depth layers (Cilium NP + PeerAuth + waypoint)
- [ADR-INFRA-007](ADR-INFRA-007.md) — SPA serving strategy (what sits behind this Gateway)
- [ADR-INFRA-010](ADR-INFRA-010.md) — in-cluster HTTP + mesh mTLS (SpiceDB)
- TODO.md § L2 Step 5 (Usable Exposure), § Multi-Environment Values Overlay
