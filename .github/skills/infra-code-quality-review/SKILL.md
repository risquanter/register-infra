---
name: infra-code-quality-review
description: "Functional-correctness and maintainability review for register-infra: Helm charts, ArgoCD apps, Istio manifests, Kyverno policies, NetworkPolicies, OPA Rego, conftest policies, Terraform. Checks that what should work, works. Load when performing a pre-commit review, reviewing a diff, or auditing completed implementation work. Trust-boundary and attack-surface checks are owned by infra-security-review."
user-invokable: true
argument-hint: "files or diff to review (attach changed files, or describe the scope)"
---

# Infrastructure Quality Review — Register Infra

Use this skill to review changed files or a diff before committing.
For each criterion report one of:

- **PASS** — no issues found
- **FINDING (severity)** — issue, location, concrete fix

Severities: **MUST-FIX** (blocks commit) · **SHOULD-FIX** (quality debt) · **NOTE**

Do not rubber-stamp. Report PASS when clean. Report FINDING when not. Do not propose
options without flagging which decision the user must make — **all decisions are the
user's to resolve**.

The criteria below are not exhaustive. Use general principles and industry best
practices to catch issues the checklist has not anticipated.

## Ownership Boundary with infra-security-review

This skill checks **functional correctness**: does the configuration do what it is
supposed to do (traffic that should flow, flows; charts render; references resolve).
`infra-security-review` owns **trust-boundary integrity**: what should not be
possible, isn't. Each rule lives in exactly one skill — do not re-check the other
skill's rules here.

**Mandatory escalation:** if the diff touches any of the following, running
`infra-security-review` on the same diff is REQUIRED, because the checks for these
live there, not here:

- New or changed external artifacts (images, charts, Actions, providers) → Pass S5
- Secrets, credentials, or `infra/secrets/` → Pass S4
- PeerAuthentication, AuthorizationPolicy, EnvoyFilter, RequestAuthentication → Passes S1–S3
- Default-deny policies, cross-namespace access rules → Pass S3
- OPA allow/deny logic, role names, header parsing → Pass S2
- AppProject whitelists/destinations, `Replace=true`, fail-closed settings → Passes S7–S8
- Pod security context, admission policies → Pass S6
- Security-relevant values duplicated across files, inline policy embedding → Pass S10

---

## Pass 1 — ADR Compliance

Check all ADRs in `docs/adr/` that are relevant to the diff. All are in force.

**Quality-owned checklist (MUST-FIX if violated):**

- [ ] Kyverno operator resources in `kyverno` project; ClusterPolicy instances in `platform` (ADR-INFRA-008)
- [ ] Every ArgoCD Application references a project that exists (ADR-INFRA-003; referential checks in Pass 5)
- [ ] New ambient-enrolled namespace has the HBONE port 15008 rule so intra-namespace traffic works (ADR-INFRA-004 §2; see Pass 3)

Security-critical ADR items (fail-closed HA, default-deny presence, wildcard
whitelists, SOPS-only secrets, `x-user-roles` vs `parsed_jwt`, `not denied`
integration, inline policy embedding, issuer-sync annotations) are checked by
`infra-security-review` — do not duplicate them here, but confirm that skill was
or will be run if any apply.

---

## Pass 2 — Helm Chart Correctness

For every new or changed Helm chart template:

- Does `helm lint infra/helm/<chart>` pass with zero errors? → **MUST-FIX** if not.
- Does `helm template <release> infra/helm/<chart> --namespace <ns>` render without
  errors? → **MUST-FIX** if not.
- Do the rendered resource `kind`s match exactly what is in the AppProject
  `namespaceResourceWhitelist`? (`helm template | grep "^kind:" | sort | uniq`)
  → **MUST-FIX** if a kind is rendered but not whitelisted — the sync will fail.
  (The reverse — whitelisted but never rendered — is least-privilege attack surface,
  owned by security review Pass S7.)
- Are all helper functions in `_helpers.tpl` named with the chart prefix
  (`spicedb.name`, not `name`)? Naming collisions between charts cause subtle bugs. → **MUST-FIX** if unprefixed.
- Are values used in templates present in `values.yaml` with sane defaults? A missing
  value key causes silent empty-string substitution or template errors. → **MUST-FIX.**
- Are resource limits AND requests set on every container? Limits without requests
  is valid but unusual; neither is a resource governance gap. → **SHOULD-FIX.**

Pod security context hardening (`automountServiceAccountToken`, `seccompProfile`)
is owned by security review Pass S6.

---

## Pass 3 — NetworkPolicy Functional Correctness

For every new or changed NetworkPolicy or CiliumNetworkPolicy, check that traffic
that MUST flow, can flow:

- Does a new service have a matching ingress AND egress policy? A one-sided policy
  (ingress only, no egress) silently breaks DNS and upstream connections. → **MUST-FIX.**
- For ambient-mode namespaces: is the HBONE port 15008 intra-namespace rule present?
  Without it, all cross-pod TCP connections fail silently. → **MUST-FIX** if missing.
- Does every default-deny namespace have a DNS egress rule (UDP+TCP port 53)?
  Without it, pods start successfully, then fail at the first service call with a
  connection timeout — not a "DNS denied" message. → **MUST-FIX** if missing.
- Does a CiliumNetworkPolicy for kubelet health probes use `fromCIDR: 169.254.7.127/32`
  (ztunnel SNAT address) and NOT `fromEntities: host`? With the wrong source, probes
  fail and pods never become ready. → **MUST-FIX** if wrong.
- Is the port in a cross-namespace NetworkPolicy the actual application port, or the
  HBONE tunnel port (15008)? Cross-namespace traffic in ambient mode uses the
  application port directly — only intra-namespace traffic uses 15008. → **MUST-FIX** if wrong.

Whether the policy is TIGHT enough (default-deny presence, namespace-only selectors,
management-port reachability) is owned by security review Pass S3.

---

## Pass 4 — OPA / Rego Mechanics

For new or changed `.rego` files:

- Does `opa test infra/helm/opa/policies/ tests/opa/ -v` pass? → **MUST-FIX** if not.
- Does `conftest test infra/k8s/ --policy tests/conftest/` pass? → **MUST-FIX** if not.
- New allow rule: is it covered by at least one OPA unit test in `tests/opa/`? → **MUST-FIX** if missing.

Semantic authorization correctness — standalone `deny` rules, `json.unmarshal` vs
string split, role-name consistency across the identity chain — is owned by
security review Pass S2.

---

## Pass 5 — ArgoCD Application Integrity

For new or changed ArgoCD Application or AppProject manifests:

- Does every Application reference a `project` that exists in `infra/argocd/projects/`? → **MUST-FIX** if referencing a non-existent project.
- Does the project's `destinations` include the Application's target namespace? → **MUST-FIX** if not.
- Does the project's `namespaceResourceWhitelist` cover every kind the chart creates? Render and diff with `helm template | grep "^kind:"`. → **MUST-FIX** if gap.
- For upstream charts: is `syncOptions: [ServerSideApply=true]` present when the chart creates CRDs > 256KB? → **MUST-FIX** if annotation limit will be exceeded (ADR-INFRA-008 §3).
- Does `CreateNamespace=false` appear for namespaces managed by the `namespaces` Helm chart? Allowing ArgoCD to create a namespace bypasses PSS labels and LimitRange. → **SHOULD-FIX.**

Whitelist minimization, default-project usage, destination blast radius, and
`Replace=true` are owned by security review Pass S7.

---

## Pass 6 — Secret Wiring

- Are secret key names consistent with what the consuming chart references via
  `secretKeyRef`? A name mismatch causes `CreateContainerConfigError` on pod start. → **MUST-FIX.**
- Are bootstrap instructions for manually applying the secret before ArgoCD sync
  documented (in TODO.md or the chart README)? → **SHOULD-FIX** if missing.

Plaintext detection, SOPS encryption, per-namespace credential scoping, and
rotation procedures are owned by security review Pass S4.

---

## Pass 7 — Test Coverage

- New NetworkPolicy rule: does at least one bats test in `tests/bats/` exercise the
  allow/deny boundary it creates? → **SHOULD-FIX** if not.
- New conftest policy rule: does it have a corresponding input fixture or test case? → **SHOULD-FIX** if not.
- New OPA policy branch: is it covered by `tests/opa/allow_test.rego`? → **MUST-FIX** if not.
- Modified conftest policy: does `conftest test infra/k8s/ --policy tests/conftest/`
  still pass with no regressions? → **MUST-FIX** if new violations appear.

Whether tests probe the DENY side of security boundaries (not just the allow path)
is owned by security review Pass S11.

---

## Pass 8 — Comments and Documentation

- Are stale comments updated? (e.g., port numbers in comments that no longer match
  the rule, namespace references that changed, TODO items that were completed) → **SHOULD-FIX** if stale.
- Are TODO.md step items marked complete (`- [x]`) for work actually completed? → **SHOULD-FIX** if stale.

Security-load-bearing comments (fail-closed consequence comments, supply chain
approval records, PeerAuthentication port-exception justifications) are owned by
security review Passes S3, S5, and S8.

---

## Pass 9 — Plan Fidelity

This is a **MUST-FIX** criterion by default.

- Was the TODO.md step followed faithfully? Check file paths, port numbers, secret key names, resource names against the plan.
- Were all Decision Triggers in `infra-working-protocol` honoured? No silent deviations.
- Were all Mandatory Review Halts observed?
- For every new external artifact: was the supply chain check (security review Pass S5) run before adoption?

---

## Pass 10 — Holistic Consistency

If a systemic issue is identified — e.g., a naming convention violated in multiple
files, a port number inconsistency across NP and PeerAuthentication, a label
mismatch between Deployment and Service selectors:

1. **Do not fix piecemeal.** Surface the full scope.
2. **Count occurrences. Name files and line numbers.**
3. **Present a holistic fix plan** using the Decision Required format.
4. **Await approval** before touching any instance.

Partial fixes of systemic issues are **SHOULD-FIX** findings in themselves — they
create partial states that are harder to complete later than the original.
