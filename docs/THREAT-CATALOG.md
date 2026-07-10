# Threat Catalog — register-infra Security Audit

> **Status**: Proposal — findings and recommended mitigations listed here are
> under review. Nothing in this document represents an agreed way forward until
> explicitly accepted and moved to an ADR or implementation ticket.
>
> **Date**: 2026-03-14
>
> **Scope**: GitOps configuration, Infrastructure-as-Code (Terraform), Helm
> charts, Istio mesh policy, network policy, RBAC, and secrets management in
> `register-infra`. The strategic security architecture (layered authorization
> model, ambient mesh, OPA ext_authz) is considered sound — this audit focuses
> on **implementation correctness and operational gaps**.

---

## Reading Guide

Each finding has:
- **ID / Severity** — H (high), M (medium), L (low/informational)
- **Finding** — what was observed
- **Risk** — what could go wrong
- **Options** — numbered solution proposals with trade-offs
- **Proposed** — the option the auditor recommends (proposal only)

---

## HIGH

### H1 · Frontend health probe — RESOLVED (no PERMISSIVE on the app port)

| | |
|---|---|
| **Status** | Resolved. No PeerAuthentication PERMISSIVE exception exists for the frontend (or OPA/register/keycloak). |
| **Design** | Frontend port 8080 (both app and probe port) is fully **STRICT** for pod-to-pod traffic. The kubelet health probe is plaintext but passes because, in ambient mode, ztunnel forwards kubelet probes to the app even under STRICT; the probe's source is scoped to the node-local SNAT address by CiliumNetworkPolicy `allow-ingress-frontend-healthcheck` (`fromCIDR: 169.254.7.127/32`). |
| **Why this closes the threat** | The earlier concern was a port-level PERMISSIVE making 8080 accept *unauthenticated* traffic from any workload. That exception has been removed: nothing accepts plaintext on 8080 except the unspoofable node-local kubelet probe (enforced at the Cilium eBPF layer). This is strictly stronger than PERMISSIVE and needs no dedicated health port or Dockerfile change. |

> Same design applies to every mesh-enrolled service with a network probe port — the authoritative list is the `allow-ingress-*-healthcheck` CiliumNetworkPolicies in `infra/k8s/network-policy/`; full mechanism: ADR-INFRA-004 §4 (canonical). PostgreSQL uses exec probes (127.0.0.1). The only remaining port-level PERMISSIVE is SpiceDB's gRPC probe (50051), pending the same treatment once SpiceDB is deployed (see `peer-authentication.yaml`).

---

### H2 · Keycloak `start-dev` Mode Has No Production Override

| | |
|---|---|
| **File** | `infra/helm/keycloak/templates/deployment.yaml` line 38 (`args: start-dev`) |
| **Finding** | Keycloak is started with `start-dev`, which disables the HTTPS requirement, enables dev-mode caching, and may expose dev-only endpoints. The same chart + values are referenced by the ArgoCD Application for the Hetzner production cluster — there is no `values-production.yaml` overlay. |
| **Risk** | On the production Hetzner cluster, Keycloak would run in development mode. While Istio ambient provides transport encryption, `start-dev` also affects token caching, theme caching, and may expose the Keycloak admin console without hostname checks (see also L4 below). |

**Options**:

| # | Option | Pros | Cons |
|---|--------|------|------|
| 1 | **Create `values-production.yaml`** with `start` (not `start-dev`), `KC_HOSTNAME` set to the real domain, `KC_HOSTNAME_STRICT=true`, `pullPolicy: IfNotPresent`. Wire the ArgoCD Application to use it via `valueFiles`. | Clean separation; follows Helm conventions; production-hardened. | Requires building an optimized Keycloak image (`kc.sh build` step) or accepting slower startup. Must resolve HTTPS certificate situation (Keycloak `start` requires HTTPS unless `KC_HTTP_ENABLED=true` + `KC_PROXY_HEADERS`). |
| 2 | **Use ArgoCD `helm.parameters` overrides** in `keycloak.yaml` to set `start` and hostname values for the production app. | No new files; change is isolated to ArgoCD manifest. | Overrides are harder to review in Git; values scattered across two files. |
| 3 | **Accept `start-dev` with mesh TLS** — document that `start-dev` is intentional because ambient mTLS replaces Keycloak's native HTTPS, and configure `KC_HOSTNAME` + `KC_HOSTNAME_STRICT` separately. | Minimal change; acknowledges that "production mode" is largely about HTTPS which the mesh provides. | `start-dev` still disables Quarkus optimizations (slower cold start, more memory). |

**Proposed**: Option 1. A production values file is the standard Helm pattern and makes the security-relevant delta visible in code review.

---

### H3 · JDBC `sslmode=disable` — No Fallback if Mesh Removed

| | |
|---|---|
| **File** | `infra/helm/keycloak/templates/deployment.yaml` — `KC_DB_URL` |
| **Finding** | The PostgreSQL JDBC URL uses `sslmode=disable`. This is explicitly documented as intentional (ztunnel provides mTLS), but creates a silent security regression if the mesh is ever removed or misconfigured. Database credentials would transit in plaintext. |
| **Risk** | Mesh removal/misconfiguration → plaintext DB credentials on the wire within the private network. Requires attacker access to the node network. |

**Options**:

| # | Option | Pros | Cons |
|---|--------|------|------|
| 1 | **Switch to `sslmode=prefer`** — the JDBC driver negotiates TLS if the server supports it, falls back to plaintext if not. With ambient mesh active, the ztunnel HBONE tunnel is used and sslmode is irrelevant. If the mesh is removed and PostgreSQL has a cert, TLS is negotiated. | Defense-in-depth; no behavior change when mesh is active. | PostgreSQL Bitnami chart doesn't enable TLS by default — `prefer` would still fall back to plaintext without additional PostgreSQL config. Misleading if it gives a false sense of security. |
| 2 | **Accept `sslmode=disable` with an explicit ADR** — document that database encryption is an ambient mesh responsibility, and that removing the mesh requires re-evaluating all inter-service encryption. | Honest; low effort; aligns with ADR-003 model. | No defense-in-depth for the DB connection. |
| 3 | **Enable PostgreSQL native TLS** (cert-manager cert + Bitnami chart `tls.enabled`) AND set `sslmode=verify-ca`. | Full redundancy — encrypted even without mesh. | Significant additional complexity (cert provisioning, trust store mounting, Bitnami TLS config). Overkill for a single-node dev cluster. |

**Proposed**: Option 2 for now (explicit risk acceptance ADR). Move to Option 3 when the production cluster is hardened. The key is making the dependency on ambient mTLS visible.

---

## MEDIUM

### M1 · No Terraform Remote State Backend

| | |
|---|---|
| **File** | `infra/terraform/main.tf` lines 26-30 (commented-out S3 backend) |
| **Finding** | Terraform state is local. It contains the Hetzner API token, kubeconfig content, and full resource graph. A disk failure loses state; a laptop compromise exposes all infrastructure secrets. |
| **Risk** | State loss → manual import of all Hetzner resources. State exposure → full cluster compromise. |

**Options**:

| # | Option | Pros | Cons |
|---|--------|------|------|
| 1 | **Hetzner Object Storage** (S3-compatible) with encryption-at-rest and state locking. | Same provider; EU data residency; low cost. | Hetzner S3 is newer, verify state locking support. |
| 2 | **Backblaze B2** with S3-compatible API. | Mature; cheap; supports `terraform state lock`. | Third-party vendor; data may leave EU. |
| 3 | **Encrypted local state + daily backup** to an encrypted USB or cloud drive. | No new service dependency. | Manual; no locking; easy to forget. |

**Proposed**: Option 1 (Hetzner Object Storage). Enable before the production cluster goes live.

---

### M2 · `allow-ingress-from-argocd` NetworkPolicy Is Overly Broad

| | |
|---|---|
| **File** | `infra/k8s/network-policy/infra.yaml` — `allow-ingress-from-argocd` |
| **Finding** | Allows the entire `argocd` namespace to reach every pod in the `infra` namespace on every port. ArgoCD typically interacts via the Kubernetes API server, not direct pod access. |
| **Risk** | If ArgoCD or Image Updater is compromised, the attacker has unrestricted L4 access to PostgreSQL and Keycloak pods. |

**Options**:

| # | Option | Pros | Cons |
|---|--------|------|------|
| 1 | **Remove the rule** if ArgoCD doesn't need direct pod access (only API server). | Tightest posture. | Need to verify ArgoCD health checks work without it (they query the API server for resource status, not the pods). |
| 2 | **Scope to specific pods + ports** — e.g., allow ArgoCD app-controller to reach Keycloak on port 8080 only (if health checks are done via pod port). | Least-privilege. | Investigation needed to confirm what ArgoCD actually accesses. |

**Proposed**: Option 1 — test by removing the rule and verifying ArgoCD sync + health check still work. ArgoCD uses the Kubernetes API, not direct pod connections.

---

### M3 · DNS Egress Allows Any Destination on Port 53

| | |
|---|---|
| **File** | `infra/k8s/network-policy/register.yaml` and `infra.yaml` — `allow-egress-dns` |
| **Finding** | `to: []` (any destination) with port 53. A compromised pod could use DNS tunneling to exfiltrate data to an external resolver. |
| **Risk** | Data exfiltration via DNS. Requires a compromised pod. |

**Options**:

| # | Option | Pros | Cons |
|---|--------|------|------|
| 1 | **Scope to kube-dns** — `podSelector: { k8s-app: kube-dns }` in `kube-system`, or the ClusterIP `10.43.0.10`. | Closes DNS tunnel to external resolvers. | The `namespaceSelector` cross-namespace reference can be brittle. ClusterIP approach is simpler but hardcodes the IP. |
| 2 | **Cilium DNS-aware policy** — use `CiliumNetworkPolicy` with `toFQDNs` to allow only specific DNS resolution targets. | Most precise. | Adds Cilium-specific config; may interfere with ambient mesh DNS. |
| 3 | **Accept** — DNS tunneling requires a compromised pod AND an external DNS server under attacker control. Low priority relative to other findings. | No change. | Leaves an exfiltration path open. |

**Proposed**: Option 1 (scope to kube-dns). Low effort, meaningful improvement.

---

### M4 · Single SOPS Age Key — No Recovery Path

| | |
|---|---|
| **File** | `infra/secrets/keycloak.enc.yaml`, `postgres.enc.yaml` |
| **Finding** | Both encrypted secrets have a single `age` recipient. If the key is lost (YubiKey failure, disk corruption), secrets are irrecoverable. No documented rotation procedure. |
| **Risk** | Permanent data loss of encrypted secrets. Must re-create credentials from scratch (PostgreSQL re-init, Keycloak re-provision). |

**Options**:

| # | Option | Pros | Cons |
|---|--------|------|------|
| 1 | **Add a second recipient** — a backup age key stored on an encrypted USB drive, kept offline. Re-encrypt both files with two recipients. | Recovery path exists; follows SOPS best practice. | Must manage the backup key securely. |
| 2 | **Document re-creation procedure** — accept single-key risk but document exactly how to re-provision everything from scratch if the key is lost. | Low effort; honest about the single-operator model. | Recovery involves PostgreSQL data loss (unless DB backups exist). |

**Proposed**: Option 1. Adding a second recipient is a few minutes of work (`sops updatekeys`) and eliminates an irrecoverable failure mode.

---

### M5 · ArgoCD `server.insecure=true` Depends on Mesh Presence

| | |
|---|---|
| **File** | `infra/terraform/main.tf` lines 271, 289 |
| **Finding** | ArgoCD API server and Image Updater run with `insecure=true`, relying on ambient mesh ztunnel for TLS. If the `argocd` namespace is removed from the mesh, the API is exposed over plaintext. |
| **Risk** | Silent TLS downgrade if mesh enrollment label is removed. ArgoCD API exposed without encryption on the node. |

**Options**:

| # | Option | Pros | Cons |
|---|--------|------|------|
| 1 | **Accept with explicit documentation** — the mesh dependency is already the security model; add a comment in `main.tf` and a note in SECURITY-FLOW.md. | Zero change; honest. | Pattern of "remove the mesh and things break" appears in multiple places (H3, M5, L4). |
| 2 | **Enable ArgoCD native TLS** with a cert-manager cert. | Defense-in-depth; works without mesh. | Double encryption overhead (ArgoCD TLS inside ztunnel mTLS). Additional cert management. |

**Proposed**: Option 1 for now. The pattern is consistent — ambient mTLS IS the transport security layer. Document the invariant clearly: "the mesh must be active for all namespaces marked with `istio.io/dataplane-mode: ambient`."

---

## LOW / INFORMATIONAL

### L1 · OPA `deny` Rules — Verify Evaluation Order

| | |
|---|---|
| **File** | `infra/helm/opa/policies/allow.rego` |
| **Finding** | The policy defines `allow` rules (any recognized role → allow) and `deny` rules (viewer writes, non-admin cache access). These are independent — the ext_authz integration must check `allow == true AND deny != true` for the deny rules to have effect. |
| **Risk** | If the ext_authz evaluation only checks `allow`, the deny rules are silently ignored. |

**Resolved (2026-03-18):** ADR-INFRA-009 formalised the `not denied` integration pattern.
The allow rule explicitly contains `not denied`, and `tests/opa/allow_test.rego` Group 8
("THREAT-CATALOG L1 — deny integration into allow") has 5 dedicated tests proving that
viewer-write and non-admin-cache deny conditions flow through the allow decision.

---

### L2 · `StrictHostKeyChecking=no` in Kubeconfig Retrieval

| | |
|---|---|
| **File** | `infra/terraform/main.tf` line 136 |
| **Finding** | SSH to the newly created Hetzner server disables host key verification. One-time bootstrap operation, mitigated by operator_cidr firewall rule. |
| **Risk** | MITM during the ~90-second window after server creation. Attacker would need to be on the operator's network path to Hetzner. |

**Proposed**: Accept. Alternatively, add a `ssh-keyscan` step that verifies against the Hetzner console output.

---

### L3 · RBAC Roles Defined But Unbound — `system:masters` in Use

| | |
|---|---|
| **File** | `infra/k8s/rbac/roles.yaml` |
| **Finding** | `viewer`, `deployer`, and `ci-authz` roles are defined but no RoleBindings exist. Current access is `system:masters` via kubeconfig. The `deployer` role includes `pods/exec`. |
| **Risk** | No audit trail for API server operations. When a second operator is added, the binding process is undocumented. |

**Proposed**: Document the RoleBinding creation procedure in GITOPS-OPERATIONS.md. Create bindings when a second operator is added.

---

### L4 · Keycloak `KC_HOSTNAME_STRICT=false`

| | |
|---|---|
| **File** | `infra/helm/keycloak/templates/deployment.yaml` line 98 |
| **Finding** | Disables hostname verification. Keycloak accepts tokens and UI access for any hostname. In production with a real domain, this should be tightened. |
| **Risk** | Token confusion if multiple hostnames resolve to the Keycloak instance. Low risk in a single-domain setup. |

**Partially resolved (2026-03-18):** `KC_HOSTNAME` is now set to
`keycloak.infra.svc.cluster.local` in `values.yaml`, pinning the issuer URL for
JWT validation. `KC_HOSTNAME_STRICT` remains `false` — tightening to `true`
is deferred to the production values file (H2).

---

### L5 · Keycloak NetworkPolicy Allows Ports 80 and 8080

| | |
|---|---|
| **File** | `infra/k8s/network-policy/infra.yaml` — `allow-ingress-keycloak-from-register` |
| **Finding** | Both port 80 (Service) and port 8080 (container/HBONE) are allowed. |
| **Risk** | None — both are legitimate paths in ambient mode. Port 80 is the ClusterIP Service port; port 8080 is the direct container port used by HBONE. |

**Proposed**: Add a clarifying comment in the YAML explaining why both ports are needed.

---

### L6 · ArgoCD Namespace at `baseline` Pod Security Standard

| | |
|---|---|
| **File** | `infra/helm/namespaces/values.yaml` — argocd entry |
| **Finding** | ArgoCD is at `baseline` PSS while application namespaces (`register`) are at `restricted`. |
| **Risk** | ArgoCD components may require baseline (Dex, Redis, etc.), but this should be verified as intentional rather than a default. |

**Proposed**: Verify and document. If ArgoCD components work under `restricted`, tighten.

---

## Cross-Cutting Observation: Mesh Dependency

Findings H3, M5, and L4 share a common pattern: they rely on ambient mesh mTLS for transport security, with no fallback. This is architecturally intentional (ADR-003, ADR-005), but the dependency is implicit. A single documentation artifact should make it explicit:

> **Invariant**: All namespaces with `istio.io/dataplane-mode: ambient` MUST have the Istio ambient mesh active. Removing or disabling the mesh degrades transport security for: database connections (H3), ArgoCD API (M5), inter-service communication, and makes `KC_HOSTNAME_STRICT=false` (L4) more consequential.

This could live in SECURITY-FLOW.md or a dedicated ADR.

---

## Summary

| ID | Severity | Finding | Proposed Action |
|---|---|---|---|
| H1 | HIGH | Frontend PeerAuth PERMISSIVE on app port | Option 1 (dedicated health port) or Option 2 (accept with doc) |
| H2 | HIGH | Keycloak `start-dev` — no prod override | Option 1 (`values-production.yaml`) |
| H3 | HIGH | JDBC `sslmode=disable` — no mesh fallback | Option 2 (risk acceptance ADR) |
| M1 | MEDIUM | No Terraform remote state | Option 1 (Hetzner Object Storage) |
| M2 | MEDIUM | ArgoCD→infra NetworkPolicy too broad | Option 1 (remove rule, test) |
| M3 | MEDIUM | DNS egress unscoped | Option 1 (scope to kube-dns) |
| M4 | MEDIUM | Single SOPS age key | Option 1 (add backup recipient) |
| M5 | MEDIUM | ArgoCD insecure depends on mesh | Option 1 (document dependency) |
| L1 | LOW | OPA deny rules — verify evaluation | **Resolved** — ADR-INFRA-009 + Group 8 tests |
| L2 | LOW | SSH StrictHostKeyChecking=no | Accept |
| L3 | LOW | RBAC unbound, system:masters | Document binding procedure |
| L4 | LOW | KC_HOSTNAME_STRICT=false | **Partially resolved** — KC_HOSTNAME pinned; STRICT deferred to H2 |
| L5 | INFO | Keycloak NP allows 80+8080 | Add clarifying comment |
| L6 | INFO | ArgoCD baseline PSS | Verify intentional |
