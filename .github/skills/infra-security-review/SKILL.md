---
name: infra-security-review
description: "Security-focused code review for register-infra. Covers identity boundary integrity, authentication/authorization correctness, secret hygiene, network trust segmentation, supply chain integrity (OWASP SCVS, CICD-SEC-3/9), container hardening (Docker-Sec), admission hardening, GitOps blast-radius, CI pipeline integrity (CICD-SEC-1/4/5), fail-closed availability, cryptographic hygiene, IaC hygiene, and configuration drift. Load when reviewing security-sensitive changes or performing a dedicated security audit pass. Complements infra-code-quality-review — run both together for pre-commit review."
user-invokable: true
argument-hint: "files or diff to review (attach changed files, or describe the scope)"
---

# Infrastructure Security Review — Register Infra

This skill performs a security-focused pass over infrastructure changes. It owns
**trust-boundary integrity**: what should not be possible, isn't. The general
quality review (`infra-code-quality-review`) owns **functional correctness**:
what should work, works (rendering, referential integrity, traffic that must
flow, secret key-name wiring). Each rule lives in exactly one skill — this one
is the single owner of: supply chain integrity, secret hygiene, identity-header
and authorization semantics, network trust segmentation, admission hardening,
GitOps blast radius and pipeline integrity, fail-closed availability,
cryptographic hygiene, and security-value single-source-of-truth.

For each criterion report one of:

- **PASS** — no issues found
- **FINDING (severity)** — issue, location, concrete fix

Severities: **MUST-FIX** (blocks commit) · **SHOULD-FIX** (quality debt) · **NOTE** (document and accept)

Do not rubber-stamp. Report PASS when clean. Report FINDING when not. All
decisions on accepted risks are the user's to resolve.

**OWASP references** are cited throughout as `(OWASP <source> — <category>)`. Key
sources used:
- **OT10 2021** — OWASP Top 10 2021 (A01–A10)
- **K8sSec** — OWASP Kubernetes Security Cheat Sheet
- **CICD** — OWASP Top 10 CI/CD Security Risks (CICD-SEC-1 through CICD-SEC-10)
- **SCVS** — OWASP Software Component Verification Standard (V1–V6)
- **Docker-Sec** — OWASP Docker Security Cheat Sheet
- **IaC-Sec** — OWASP Infrastructure as Code Security Cheat Sheet
- **AuthN** — OWASP Authentication Cheat Sheet
- **AuthZ** — OWASP Authorization Cheat Sheet
- **Crypto** — OWASP Cryptographic Storage Cheat Sheet
- **Secrets** — OWASP Secrets Management Cheat Sheet

---

## Pass S1 — Identity Boundary Integrity

*The project's zero-trust model depends on a specific filter-chain ordering: strip
inbound identity headers → validate bearer token → inject trusted headers. Any
deviation silently breaks the entire identity model.*

*OWASP OT10 2021 A07 (Identification and Authentication Failures)*

- **Is the strip-before-inject ordering preserved?**
  The filter that removes inbound identity headers (`x-user-id`, `x-user-email`,
  `x-user-roles`) MUST execute at the `HttpConnectionManager` level, before the
  JWT validation filter. Stripping at the router level runs after JWT injection —
  an attacker can forge those headers and they will survive stripping.

  ```yaml
  # CORRECT: operates at HCM level (before jwt_authn)
  applyTo: HTTP_FILTER
  match:
    context: SIDECAR_INBOUND
    listener:
      filterChain:
        filter:
          name: envoy.filters.network.http_connection_manager
  ```

  → **MUST-FIX** if the filter applies at `VIRTUAL_HOST`, `HTTP_ROUTE`, or any
  point after `envoy.filters.http.jwt_authn` in the filter chain.

- **Are ALL inbound identity header names covered by the strip rule?**
  A partial strip (e.g. removing `x-user-id` but not `x-user-roles`) allows an
  external client to forge the uncovered header. Check that the removal list is
  complete and matches every header name referenced downstream in OPA policy and
  application code. → **MUST-FIX** if any identity header is missing.

- **Do downstream consumers (OPA, application) read only the infra-injected
  headers — never the raw token or decoded JWT payload?**
  Reading raw tokens or base64-decoded JWT claims without signature verification
  defeats the entire trust model: if JWT validation is accidentally removed, the
  consumer would still trust unverified claims. Any `input.parsed_jwt` reference
  in OPA policy (outside of test mocks), or JWT decoding in application code,
  is a trust boundary violation. → **MUST-FIX** in production code paths.

- **Does the bearer token validation step require both signature and expiry
  verification, with the JWKS endpoint pointing to the authoritative issuer?**
  A misconfigured issuer URL (e.g. localhost instead of the internal service
  address) causes validation to silently fail open if the library defaults to
  `allow_missing_or_failed`. Verify:
  - JWKS endpoint is the internal issuer URL (no external DNS in a mesh cluster)
  - `forwardOriginalToken: false` (do not forward raw bearer to upstream — it
    has no use there and leaks credentials to application logs)
  → **MUST-FIX** if issuer URL is wrong or `forwardOriginalToken: true`.

---

## Pass S2 — Authorization Correctness

*OWASP OT10 2021 A01 (Broken Access Control) · OWASP AuthZ*

- **Fail-closed posture: is the authorization decision path fail-closed?**
  The policy evaluator must be configured to deny by default when unreachable —
  not to permit. A `failure_mode` of `allow` or `pass` at the ext_authz filter
  means any network disruption to the policy engine grants every request.
  → **MUST-FIX** if `failure_mode` is permissive.

  ```yaml
  # CORRECT
  failure_mode_deny: true  # OPA unreachable → 403, not 200
  ```

- **Are deny conditions integrated into the allow decision, not standalone?**
  The ext_authz integration evaluates a single decision rule (`allow`). A
  standalone `deny` rule is silently ignored — it never participates in the
  decision. Deny conditions must be gated via `not denied` inside `allow`.

  ```rego
  # WRONG: standalone deny is never evaluated by ext_authz
  deny if { input.request.http.path == "/admin" }

  # CORRECT: deny integrated into allow path
  allow if {
      has_recognized_role
      not denied
  }
  denied if { input.request.http.path == "/admin" }
  ```
  → **MUST-FIX** if a standalone `deny` rule appears outside of test files.

- **Does every AuthorizationPolicy with HTTP rules target the waypoint —
  `targetRef: { kind: Gateway, name: waypoint }` — never `selector: {}`?**
  In ambient mode the ztunnel silently drops all HTTP rules on pod-selector
  policies, degrading the policy to L4 default-deny. The manifest looks valid;
  the L7 authorization intent is simply never enforced.
  → **MUST-FIX** if an AuthorizationPolicy with HTTP rules uses a pod selector
  instead of a waypoint `targetRef`.

- **Does any new DENY policy match the infra-injected identity headers
  (`x-user-id`, `x-user-email`, `x-user-roles`)?**
  These headers are legitimately present on authenticated requests — jwt_authn
  injects them after stripping. A DENY rule matching them blocks all
  authenticated traffic (C1 regression).
  → **MUST-FIX** if a DENY policy references an infra-injected header.

- **Are role name strings consistent across the identity chain?**
  Role names flow through: identity provider realm configuration → JWT `roles`
  claim → header injection → OPA policy string literals → application Role
  mapping. A mismatch at any step means OPA permits what the application
  rejects (phantom access) or OPA blocks what the application would allow
  (invisible denial). Verify the role strings are identical at each step.
  → **MUST-FIX** if any discrepancy is found.

- **Is claim extraction using a typed deserialisation — not string split?**
  The `roles` claim is a JSON array in the header value. Splitting on `,` or
  space produces tokens with embedded quote characters (`'"editor"'`) that
  never match unquoted role strings. Use JSON parsing.

  ```rego
  # WRONG: string-split produces '"editor"' with embedded quotes
  user_roles := split(input.request.http.headers["x-user-roles"], ",")

  # CORRECT: JSON-parse the header value
  user_roles := roles if {
      json.unmarshal(input.request.http.headers["x-user-roles"]) = parsed
      roles := {r | r := parsed[_]}
  }
  ```
  → **MUST-FIX** if string-based parsing is used for JSON-typed claim values.

- **Does every new ALLOW policy have an explicit principal or path constraint?**
  An ALLOW authorization policy with no `from` (requestPrincipal) and no `to`
  (path/method) is a no-op at the L7 proxy — the default-deny policy still
  applies, but the intent is invisible and confusing. More dangerously, a
  wildcard ALLOW at the wrong targeting level (pod selector instead of waypoint)
  may bypass L7 enforcement entirely.
  → **MUST-FIX** if an ALLOW policy has neither `from` nor `to` constraints.

- **For capability-URL (credential-in-URL) paths: is the JWT requirement
  explicitly exempted AND is the exemption the minimum scope necessary?**
  Routes where the URL itself is the credential must not require a JWT (the
  bearer has the URL, not an account). But the exemption scope must be the
  smallest prefix that matches only those routes — an over-broad exemption
  creates an unauthenticated surface.
  → **MUST-FIX** if the exemption path is broader than the capability-URL
  prefix; **SHOULD-FIX** if there is no test covering the boundary between
  the exempted and non-exempted paths.

---

## Pass S3 — Network Trust Segmentation

*OWASP OT10 2021 A05 (Security Misconfiguration) · OWASP K8sSec*

- **Is there a default-deny egress AND ingress policy in every namespace that
  hosts security-sensitive workloads?**
  A missing default-deny rule means any workload in the namespace can initiate
  arbitrary connections. The rule must exist as a catch-all before any allow
  rules.
  → **MUST-FIX** if a security-sensitive namespace lacks a default-deny-all
  NetworkPolicy (or equivalent eBPF policy) for either direction.

- **Are cross-namespace flows restricted to the minimum required pair
  (source namespace AND source pod, not source namespace alone)?**
  Matching only on namespace selector permits any pod in that namespace to
  reach the target — including compromised pods. The cross-namespace rule
  should combine `namespaceSelector` AND `podSelector`.

  ```yaml
  # WEAK: any pod in register namespace can reach infra service
  from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: register

  # CORRECT: only the specific service account's pods
  from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: register
      podSelector:
        matchLabels:
          app: register
  ```
  → **SHOULD-FIX** if namespace-only selector is used for cross-namespace flows.

- **Is mTLS (mutual authentication) enforced in STRICT mode on all namespaces
  that carry sensitive data?**
  A `PERMISSIVE` PeerAuthentication at the namespace level means any pod — even
  one without a mesh identity — can send traffic to mesh pods without mTLS.
  Port-level permissive exceptions must be documented with their justification
  (health probe workaround) and restricted to the minimum set of ports.
  → **MUST-FIX** if namespace-wide PERMISSIVE is present; **SHOULD-FIX** if a
  port exception lacks a justification comment and a corresponding network
  policy restricting access to the health-probe source address.

  Repo-specific: every `portLevelMtls: PERMISSIVE` port must be in the
  `allowed_permissive_ports` set in `tests/conftest/policy/peerauthentication.rego`
  (conftest fails otherwise), and must have a matching CiliumNetworkPolicy
  restricting that port to the ztunnel SNAT address `169.254.7.127/32`. The
  justification comment should state the three-layer defense (ztunnel SNAT /
  CiliumNP / no external Service). → **MUST-FIX** if the conftest entry or the
  CiliumNP is missing.

- **Is network reachability to management or diagnostic ports restricted to
  the cluster's internal network?**
  Management interfaces (identity provider admin console, policy engine
  diagnostics, database management port) must not be reachable from external
  ingress, other application namespaces, or the internet. Check that:
  - No external Service (LoadBalancer / NodePort) exposes a management port
  - Network policies allow management ports only from the ops/monitoring
    namespace, not from application namespaces
  → **MUST-FIX** if a management port is reachable from an application
  namespace or from the external network.

- **Does DNS egress exist for every namespace that uses service discovery?**
  A default-deny egress policy without a DNS allow rule causes all hostname
  resolutions to fail silently. Pods start successfully, then fail at the
  first service call — the error is a connection timeout, not a "DNS denied"
  message.
  → **MUST-FIX** if a default-deny namespace lacks DNS egress (UDP+TCP port 53).

---

## Pass S4 — Secret Hygiene

*OWASP OT10 2021 A02 (Cryptographic Failures) · OWASP Secrets Management*

- **Are there ANY plaintext credentials anywhere in the diff?**
  This includes: `kind: Secret` with `data`/`stringData` containing real values,
  environment variable values in Deployment manifests, Helm values files with
  real passwords, Terraform state fragments, `kubeconfig` entries, or comments
  containing credentials. → **MUST-FIX** unconditionally. Rotate the credential
  before merging.

- **Are all credentials delivered via encrypted secret files, never as
  inline values or environment literals?**
  Credentials in ConfigMaps (even base64-encoded), Helm value files committed
  to the repo, or environment variable literals in Deployment specs are all
  cleartext in Git history. The only acceptable delivery path is an
  encrypted-at-rest file that is decrypted at apply time.
  → **MUST-FIX** if credentials appear outside the designated encrypted-secrets
  mechanism.

- **Does each namespace's secret contain only the credentials that namespace's
  workloads need — never a superuser or cross-service credential?**
  Sharing a privileged credential across namespaces (e.g. the database superuser
  password used by an application pod) violates least-privilege: a compromised
  pod gains full access to all databases, not just its own schema.
  → **MUST-FIX** if an application workload references a superuser or shared
  credential; **SHOULD-FIX** if a credential scope is broader than the single
  service that needs it.

  Repo-specific: the only acceptable form is a SOPS-encrypted `*.enc.yaml` file
  in `infra/secrets/`, scoped per-namespace (ADR-INFRA-006). A secret living in
  the `infra` namespace but consumed by a pod in `register` is a boundary
  violation. Secret key-name wiring against `secretKeyRef` consumers is a
  functional check owned by `infra-code-quality-review` Pass 6.

- **If a new secret is introduced: does it have a documented rotation
  procedure and off-boarding checklist?**
  Credentials without rotation procedures accumulate indefinitely. Every new
  secret must have, at minimum, a one-line rotation note (where to rotate,
  what to redeploy) in the chart README or TODO.md.
  → **SHOULD-FIX** if rotation procedure is undocumented.

---

## Pass S5 — Supply Chain Integrity

*OWASP OT10 2021 A06 (Vulnerable and Outdated Components) · OWASP CICD CICD-SEC-3, CICD-SEC-8, CICD-SEC-9 · OWASP SCVS V1, V4, V6 · OWASP IaC-Sec*

- **Is every new external artifact sourced from the primary vendor
  organisation — never a community fork, mirror, or aggregator?**
  Popularity, age, and GitHub stars are not proxies for security. The question
  to answer is: "If this publisher account were compromised, who would I call?"
  If the answer is not the original software vendor, the source is wrong.
  → **MUST-FIX** if any artifact is sourced from a third-party distribution.

- **Are all external references pinned to an immutable identifier?**
  Mutable references (`latest`, version ranges, branch names) resolve to
  different content over time — an attacker who compromises the upstream
  publisher can push a malicious update that is automatically pulled on the
  next deployment. Every external artifact must be pinned:
  - Container image: content digest (`sha256:...`)
  - Helm chart: exact version string
  - CI action: full commit SHA
  - Infrastructure provider: exact version constraint
  → **MUST-FIX** if any mutable reference is present.

- **Has the cooldown period elapsed for any newly introduced or upgraded
  artifact at a cluster-privileged or cluster-scoped tier?**
  Recently released artifacts have not yet had community scrutiny. Compromised
  or accidentally broken releases are typically discovered within days to weeks.
  Verify the release date versus the adoption date. The minimum waiting period
  scales with blast radius — a chart that installs cluster-level webhooks
  requires a longer cooldown than a single-namespace application image.
  Exception: a confirmed CVE in the currently deployed version. Document the
  CVE identifier in the commit.
  → **MUST-FIX** if the cooldown period has not elapsed (except CVE exception).

  Repo-specific (ADR-INFRA-012): T1 artifacts require 90 days from public
  release for new adoptions; T2 require 30 days. T1/T2 artifacts sourced from
  a community fork, mirror, or third-party distribution are rejected
  unconditionally — write local infrastructure instead.

- **Is the approval record comment present for every new or upgraded
  cluster-privileged or cluster-scoped artifact?**
  The approval record makes supply chain decisions explicit and reviewable:
  who published it, how to report vulnerabilities, what version is pinned,
  and when the cooldown elapsed. Its absence means a future reviewer cannot
  verify the decision was made deliberately.
  → **MUST-FIX** if the approval record comment is absent. Required format:

  ```yaml
  # Vendor: <org> — <URL>
  # Security disclosure: <URL>
  # Pinned: <exact version or digest>
  # Cooldown elapsed: <release date> → adopted <date> (<N days>)
  # Approved: ADR-INFRA-012. Reviewed: <date>
  ```

- **Is any new upstream Helm chart `repoURL` outside the ADR-INFRA-012 §7
  approved list?**
  The approved-repository list is the control point for chart provenance;
  additions require an ADR amendment, not a review-time judgment call.
  → **MUST-FIX** — requires ADR amendment before merge.

- **Does each T1/T2 vendor have a documented security disclosure path?**
  An artifact from a vendor with no security disclosure mechanism cannot be
  monitored for CVEs. Before adopting, verify `SECURITY.md`, a CVE programme,
  or a named security contact exists.
  → **MUST-FIX** if no disclosure path exists for a newly adopted T1/T2
  artifact.

- **Is the provenance of each external artifact traceable back to its
  canonical source? (OWASP SCVS V6)**
  Pinning to a digest proves immutability but not origin — two different
  images can share a digest if one overwrites the other before you pull.
  Traceability requires that the artifact can be independently re-fetched
  from the vendor's canonical registry and produces the same digest.
  For container images: is the registry the vendor's own (e.g.
  `ghcr.io/authzed/spicedb`, not a mirror or proxy cache)?
  For Helm charts: is `repoURL` the vendor's own chart repository, not an
  aggregator?
  → **MUST-FIX** if an artifact is pulled from a registry that is not the
  vendor's canonical source.

- **Can all externally sourced components currently deployed be enumerated
  from the repo alone, without cluster inspection? (OWASP SCVS V1)**
  If the set of deployed images/charts is not fully derivable from Git, drift
  is undetectable. Every external component must appear in a manifest, chart,
  or lockfile committed to the repo — not only discovered via `kubectl get
  pods -o yaml`.
  → **SHOULD-FIX** if any deployed external artifact has no corresponding
  pinned reference in the repository.

- **For new artifacts: is integrity verification performed beyond digest
  pinning? (OWASP CICD-SEC-9 · OWASP IaC-Sec)**
  Digest pinning prevents silent mutable-tag substitution but does not
  protect against a compromise of the upstream registry before the digest is
  recorded. Where the vendor publishes signed artifacts (Sigstore/cosign
  signatures, Helm chart provenance files), verification should be performed
  at adoption time and documented in the approval record. For Helm charts,
  `helm verify` checks the `.prov` file if published.
  → **NOTE** if a vendor publishes signatures and they are not verified at
  adoption; **SHOULD-FIX** if this is feasible to automate in the CI pipeline.

---

## Pass S6 — Admission Gate Correctness

*OWASP OT10 2021 A05 (Security Misconfiguration) · OWASP K8sSec · OWASP Docker-Sec Rules #2, #3, #4, #6, #8*

- **Are pods that handle or can reach sensitive data prevented from
  escalating privilege? (Docker-Sec Rule #4)**
  Check for: `allowPrivilegeEscalation: true`, `privileged: true`,
  `runAsRoot: true` or `runAsUser: 0`. Each is a potential path from a
  container escape to a node compromise.
  → **MUST-FIX** for any privilege escalation enablement on a workload that
  can reach secrets, databases, or the policy engine.

- **Are Linux capabilities dropped to the minimum required set? (Docker-Sec
  Rule #3)**
  The default capability set includes capabilities that a typical service
  workload never needs (`NET_RAW`, `SYS_CHROOT`, `AUDIT_WRITE`, etc.).
  The secure baseline is `drop: [ALL]` and then add only what is explicitly
  required. A container with excess capabilities can abuse them to escape
  or pivot.

  ```yaml
  securityContext:
    capabilities:
      drop: ["ALL"]
      add: []  # add only if a specific capability is required and documented
  ```
  → **MUST-FIX** if `capabilities.drop` is absent on a workload with network
  access to sensitive services; **SHOULD-FIX** on all other workloads.

- **Is `runAsNonRoot: true` and `runAsUser` set to a non-zero UID on all
  workloads? (Docker-Sec Rule #2)**
  A container running as root inside the container is root on the host if it
  escapes the container boundary. Non-root user enforcement is a first-line
  containment measure.

  ```yaml
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534  # nobody, or a specific non-zero UID
  ```
  → **MUST-FIX** if a workload that can reach secrets or the policy engine
  runs as root; **SHOULD-FIX** on all other workloads.

- **Is `readOnlyRootFilesystem: true` set on workloads that do not need
  to write to their own filesystem? (Docker-Sec Rule #8)**
  A writable root filesystem allows an attacker who achieves code execution
  to install tools, modify binaries, or persist across restarts. Stateless
  workloads (reverse proxies, policy engines, JWT validators) should run
  with a read-only filesystem.

  ```yaml
  securityContext:
    readOnlyRootFilesystem: true
  # If ephemeral writes are needed (e.g. nginx tmp files):
  # use an emptyDir volume for the specific paths, not a writable root.
  ```
  → **SHOULD-FIX** if absent on a stateless workload.

- **Is the service account token explicitly not auto-mounted on pods that do
  not need Kubernetes API access?**
  An auto-mounted token is accessible to any process in the container. If the
  container is compromised, the attacker inherits the pod's API permissions.
  Most application pods never call the Kubernetes API — they have no legitimate
  need for the token.

  ```yaml
  # Every Deployment and ServiceAccount that doesn't call the K8s API:
  automountServiceAccountToken: false
  ```
  → **SHOULD-FIX** if missing on a workload that does not use the API.

- **Is the seccomp profile set to RuntimeDefault or stricter?**
  The default seccomp policy is `Unconfined` — the container can make any
  syscall. RuntimeDefault applies the container runtime's built-in policy,
  blocking >100 dangerous syscalls (including `ptrace`, `mount`, direct disk
  writes). Admission controllers may inject this automatically for some
  namespaces but not others.
  Repo-specific: Kyverno injects `RuntimeDefault` for the `register` namespace;
  the `infra` namespace (baseline PSS) needs it explicit in the chart.
  → **SHOULD-FIX** if `seccompProfile` is absent in the pod security context
  on a namespace not covered by automatic injection.

- **Do admission policies that block non-compliant pods use `Enforce` mode
  (not `Warn` or `Audit` alone)?**
  A policy in warn-only mode provides no actual security boundary — pods are
  created regardless. Warn mode is appropriate for rollout; it must not remain
  the permanent setting for security-critical policies.
  → **MUST-FIX** if a security-critical admission policy is permanently in
  warn or audit mode.

- **For admission controllers that are fail-closed (webhook `failurePolicy:
  Fail`): are they highly available?**
  A fail-closed webhook with a single replica causes all pod creation to block
  during that pod's restart. For short disruptions this is an availability
  issue; for extended outages it can trigger emergency fallback procedures that
  weaken the security posture.
  → **MUST-FIX** if a fail-closed webhook has fewer than 2 replicas or lacks a
  PodDisruptionBudget.

---

## Pass S7 — GitOps Blast Radius

*OWASP OT10 2021 A04 (Insecure Design) · OWASP CICD CICD-SEC-5*

- **Does every GitOps Application reference a scoped project with explicit
  resource-kind whitelists — not the default project?**
  The default GitOps project typically allows any resource kind in any
  namespace. A misconfigured source path or namespace targeting in an
  Application can overwrite resources in unintended namespaces, including
  system namespaces.
  → **MUST-FIX** if any Application references the default project.

- **Are project resource-kind whitelists the minimum set actually rendered
  by the chart?**
  Wildcards in the whitelist grant the GitOps agent permission to deploy any
  resource kind — equivalent to `cluster-admin` within the allowed namespaces.
  A kind in the whitelist that is never rendered is unnecessary attack surface.
  Verify by rendering the chart and diffing against the whitelist:
  `helm template | grep "^kind:" | sort -u`
  → **MUST-FIX** if wildcards are present; **SHOULD-FIX** if kinds are
  whitelisted but never rendered.

- **Are project destination namespaces the minimum required set?**
  A project destination that includes `kube-system` or `*` allows the
  corresponding Applications to deploy resources into system namespaces,
  potentially overwriting cluster-critical components.
  → **MUST-FIX** if `kube-system`, `istio-system`, or a wildcard namespace is
  in the destination list of a project that does not have explicit justification.

- **Is `syncOptions: [Replace=true]` present anywhere?**
  Replace mode destroys and recreates resources rather than patching them.
  This can cause unintended downtime for PersistentVolumeClaims, Secrets, and
  other stateful resources. It should never appear without explicit, reviewed
  justification.
  → **MUST-FIX** — raise a Decision Required; do not merge without user sign-off.

- **Is automated self-heal enabled on Applications that manage security
  policy resources?**
  Without `selfHeal: true`, a manually applied `kubectl edit` to a security
  policy (NetworkPolicy, AuthorizationPolicy, PeerAuthentication) persists
  indefinitely until the next manual sync. Self-heal is the GitOps enforcement
  mechanism that prevents configuration drift from weakening the security
  posture.
  → **SHOULD-FIX** if `automated.selfHeal` is false for Applications managing
  network or authorization policies.

---

## Pass S8 — Fail-Closed Availability

*OWASP OT10 2021 A05 (Security Misconfiguration)*

- **Does every security-enforcement component (policy engine, JWT validator,
  admission webhook) run at least 2 replicas?**
  A single-replica fail-closed component causes full service outage during
  its restart. Switching to fail-open to avoid outages is not acceptable —
  the correct fix is high availability.
  → **MUST-FIX** if `replicaCount: 1` on any fail-closed security component.

- **Does every fail-closed component have a PodDisruptionBudget that prevents
  voluntary disruptions from removing the last replica?**
  Without a PDB, `kubectl drain` during node maintenance removes all pods on
  the node, including the last replica of a fail-closed component, causing an
  outage.
  → **MUST-FIX** if a fail-closed component lacks a PDB with `minAvailable: 1`
  (or equivalent).

- **Is the fail-closed consequence documented in the resource that sets the
  fail-closed mode?**
  A future operator seeing `failure_mode_deny: true` or `failurePolicy: Fail`
  must immediately understand what breaks if the component is unavailable.
  The comment prevents well-intentioned "fixes" (switching to fail-open) during
  an incident.

  ```yaml
  # failure_mode_deny: true — OPA unreachable → 403 on ALL requests.
  # Consequence: OPA must have ≥2 replicas + PDB (ADR-INFRA-002).
  # Do NOT change to false — it converts a security control into a bypass.
  failure_mode_deny: true
  ```
  → **MUST-FIX** if the consequence comment is absent.

---

## Pass S9 — Cryptographic Hygiene

*OWASP OT10 2021 A02 (Cryptographic Failures) · OWASP Crypto*

- **Are TLS connections to sensitive services (databases, identity providers,
  authorization stores) using TLS with certificate verification — or
  explicitly documented as relying on transport-layer encryption from the
  mesh?**
  Application-level TLS with `sslmode=disable` or `verify=false` creates an
  implicit dependency: if the mesh is misconfigured or removed, traffic
  transits in plaintext. Every such setting must have an explicit comment
  stating the mesh dependency and the consequence of mesh removal.
  → **MUST-FIX** if plaintext connection settings exist without a comment
  documenting the mesh-layer substitute; **NOTE** with documented mesh
  dependency is acceptable but should be tracked for hardening.

- **Are JWT algorithms explicitly configured to reject `none` and weak
  algorithms (HS256 with a shared secret)?**
  Some JWT libraries accept the `none` algorithm (no signature) by default.
  A policy that accepts `none` tokens can be bypassed by removing the
  signature from any valid token.
  → **MUST-FIX** if the JWT validation configuration does not enumerate
  accepted algorithms (RS256, RS512, ES256, or equivalent asymmetric).

- **Are cryptographic keys (signing keys, pre-shared keys, database
  passwords) stored as secrets, never as configuration values?**
  Keys in ConfigMaps, environment variables in Deployment specs, or Helm
  values files are visible in Git and in the Kubernetes API to anyone with
  `get configmap` access in that namespace.
  → **MUST-FIX** if any cryptographic key material appears outside the
  encrypted-secrets mechanism.

- **For pre-shared keys used between internal services (e.g. gRPC
  authorization service keys): are they per-environment, not shared across
  production and development?**
  A single pre-shared key used in both environments means a development
  environment breach gives production access.
  → **SHOULD-FIX** if the same secret value appears in both environment
  configurations.

---

## Pass S10 — Configuration Single-Source-of-Truth and IaC Hygiene

*OWASP OT10 2021 A05 (Security Misconfiguration) · OWASP IaC-Sec (Develop/Deploy/Runtime)*

- **Is every security-relevant configuration value (issuer URL, role name,
  header name, allowed path prefix) defined in exactly one place?**
  Values that appear in multiple files — policy source, chart values,
  raw manifest, test fixture — will drift. A drifted issuer URL silently
  breaks JWT validation. A drifted role name silently grants or denies access.

  ```yaml
  # BAD: same issuer URL hardcoded in two files independently
  # values.yaml: issuer: http://keycloak.infra.svc.cluster.local/realms/register
  # request-authentication.yaml: issuer: http://keycloak.example.com/realms/register

  # GOOD: cross-file coupling made explicit
  metadata:
    annotations:
      register-infra/issuer-sync: "http://keycloak.infra.svc.cluster.local/realms/register"
  ```
  → **MUST-FIX** if a security-relevant value appears independently in
  multiple files without a machine-readable sync marker.

- **Is every policy file loaded from its canonical source, not embedded
  inline?**
  An inline policy copy will drift from the canonical version. The drift is
  typically silent — no error is raised when a policy file and its copy
  diverge. The canonical source must be the single file that is both tested
  and loaded at runtime.

  ```yaml
  # BAD: policy logic embedded inline — will drift from tested canonical
  data:
    allow.rego: |
      package register.authz
      default allow := false
      # ... partial copy, comments stripped

  # GOOD: loaded from canonical source
  data:
    allow.rego: |
  {{ .Files.Get "policies/allow.rego" | indent 4 }}
  ```
  → **MUST-FIX** if a policy file is embedded inline rather than loaded from
  its single canonical source.

- **Are test fixtures used for policy testing consistent with what the
  production filter chain injects?**
  A test that mocks `input.parsed_jwt.roles` instead of `input.request.http.
  headers["x-user-roles"]` tests a code path that does not exist in production.
  The test passes; the production policy silently fails.
  → **MUST-FIX** if test input structures diverge from the production filter
  chain output format.

- **For Infrastructure-as-Code (Terraform/OpenTofu): is the state file
  stored with access controls and encryption at rest? (OWASP IaC-Sec Deploy
  § · OWASP Secrets)**
  Local state files contain the full resource graph including any secret
  outputs (API tokens, kubeconfig content). A local state file on a developer
  laptop is unencrypted, unshared, and lost on disk failure. Remote state
  backends should enforce encryption-at-rest and access-controlled reads.
  State locking prevents concurrent writes that corrupt state.
  → **MUST-FIX** if state is local and the project is past the initial
  bootstrapping phase; **SHOULD-FIX** if remote backend exists but locking
  or encryption-at-rest is not confirmed.

- **Are IaC provider/API credentials scoped to the minimum permissions
  required for the operations the code performs? (OWASP IaC-Sec § Principle
  of Least Privilege)**
  A cloud provider API key that can create VMs, modify DNS, and delete
  storage is a full-compromise token. The token used by Terraform should
  be scoped to exactly the resource types the code manages, with no wildcard
  permissions.
  → **SHOULD-FIX** if the IaC credential scope is broader than the
  resource types declared in the code.

---

## Pass S11 — Observability and Incident Detectability

*OWASP OT10 2021 A09 (Security Logging and Monitoring Failures)*

- **For new security enforcement decisions (deny paths, authentication
  failures): is the outcome observable?**
  A silent 403 with no log entry makes security incidents invisible. Policy
  denials, authentication failures, and authorization blocks should produce
  an observable signal (structured log entry, metric counter, or trace span)
  that distinguishes "denied by policy" from "service error".
  → **SHOULD-FIX** if a new deny path produces no observable signal.

- **Is the security posture of new components verifiable by the existing
  test suite?**
  A new NetworkPolicy rule, AuthorizationPolicy, or OPA branch that has no
  test covering the allow/deny boundary is operationally invisible — it may
  silently fail for months before anyone notices.
  Base test-existence checks are owned by `infra-code-quality-review` Pass 7;
  this pass owns the deny side specifically.
  → **SHOULD-FIX** if a test exists but does not probe the deny side of the
  boundary (only tests the allow path).

- **For components with fail-closed semantics: is there a health check or
  readiness probe that would detect a silent policy failure (e.g. OPA
  returning 200 without running any rule)?**
  A policy engine that starts up but serves incorrect decisions is worse than
  one that fails to start — the latter is visible; the former silently grants
  or denies everything.
  → **SHOULD-FIX** if a fail-closed policy engine lacks a readiness probe that
  validates policy evaluation (e.g. a known-deny request returns 403).

---

## Pass S12 — GitOps Pipeline Integrity

*OWASP CICD CICD-SEC-1 (Flow Control) · CICD-SEC-2 (IAM) · CICD-SEC-4 (Poisoned
Pipeline Execution) · CICD-SEC-5 (PBAC) · CICD-SEC-6 (Credential Hygiene)*

- **Is the absence of enforced peer review on the default branch a
  documented, accepted risk? (CICD-SEC-1)**
  The ideal control is branch protection requiring at least one approved
  review before merge. For a **sole-developer project**, requiring a second
  reviewer is operationally impossible — enforcing it would block all merges.
  This is an accepted structural exception for this project.
  The compensating controls that must be present instead:
  - Pre-commit review via `infra-code-quality-review` + `infra-security-review`
    (self-review before every push — skip semantics are a protocol violation)
  - `automated.selfHeal: true` on all security-policy Applications (drift
    detection substitutes for a second set of eyes post-merge)
  - The infra-working-protocol Decision Protocol (no silent unilateral
    decisions)
  → **NOTE** — sole-developer exception is accepted. **MUST-FIX** if a second
  developer is onboarded and branch protection is not re-evaluated at that
  point. **SHOULD-FIX** if any of the three compensating controls above are
  missing.

- **If the CI pipeline runs in response to untrusted contributions (e.g.
  pull requests from forks): does it have access to cluster credentials,
  secrets, or deployment tokens? (CICD-SEC-4: Poisoned Pipeline Execution)**
  A CI workflow triggered by a fork PR that has access to production secrets
  allows any contributor to exfiltrate credentials by adding a step to the
  workflow. The correct pattern is to separate the trusted (post-merge) CI
  environment from the untrusted (pre-merge PR) environment.
  Checks:
  - Are cluster credentials (`KUBECONFIG`, deploy tokens) accessible only
    in post-merge workflows, not in PR-triggered workflows?
  - Are encrypted repository secrets scoped to `protected` branches only?
  - Does the in-cluster runner only pick up jobs dispatched from the
    trusted CI environment (post-merge), not directly from PR events?
  → **MUST-FIX** if cluster credentials are accessible in a workflow that
  executes untrusted code (PR from fork or external contributor).

- **Is the CI runner's access to the cluster and to secrets the minimum
  required for its job? (CICD-SEC-5: PBAC)**
  A runner that deploys to the `register` namespace should not have
  `cluster-admin` or write access to `kube-system`. The runner's service
  account or kubeconfig should be scoped to the namespaces and resource kinds
  it actually manages. Treat the runner as a separate principal with its own
  least-privilege policy.
  → **SHOULD-FIX** if the runner credential grants more namespace or resource
  access than the jobs it performs require.

- **Are CI secrets (cluster tokens, SOPS keys, registry credentials) rotated
  and never logged? (CICD-SEC-6)**
  CI log outputs are typically retained and may be world-readable on public
  repositories. A workflow step that echoes a secret or uses it in a command
  that is logged leaks it permanently.
  Checks:
  - Are secrets masked in CI logs (no `echo $SECRET`, no `set -x` with
    secrets in scope)?
  - Is there a rotation schedule or last-rotated date documented for CI
    credentials?
  → **MUST-FIX** if a secret value could appear in CI log output;
  **SHOULD-FIX** if rotation is undocumented.

- **Does the in-cluster CI runner (if present) have a NetworkPolicy that
  restricts its egress to only what is needed for schema application and
  health reporting?**
  A compromised runner with unrestricted egress can exfiltrate secrets to
  external endpoints. The runner's network policy should mirror the
  least-privilege principle: only allow egress to the specific internal
  services it calls (SpiceDB gRPC port, CI coordination endpoint) and block
  all other outbound.
  → **SHOULD-FIX** if the runner pod has no NetworkPolicy or has unrestricted
  egress.

---

## Pass S13 — Holistic Security Posture

If a systemic security weakness is identified — a pattern of missing controls,
a repeated boundary violation across multiple files, or a defence-in-depth
layer that is entirely absent:

1. **Do not patch individual instances.** Surface the full scope.
2. **Identify the control that is missing or ineffective.** Name the threat it
   was meant to address (referencing the OWASP category and project threat model).
3. **Count instances. Name files and exact locations.**
4. **Present a remediation plan** using the Decision Required format.
5. **Await approval** before touching any instance.

A partial fix of a systemic weakness is a **FINDING (SHOULD-FIX)** in its own
right — partial states are harder to complete than the original gap.
