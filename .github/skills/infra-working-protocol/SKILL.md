---
name: infra-working-protocol
description: "Governance protocol for the register-infra project. Load for: Decision Protocol questions, Mandatory Review Halt reminders, Blocked/Failing State handling, ADR compliance process, phase completion criteria. Use when: unsure whether to stop and ask, executing a plan, reviewing a diff before commit, or handling any ArgoCD sync failure, bats failure, or design tension."
user-invokable: false
---

# Working Protocol — Register Infra

## Decision Protocol

**The user owns every decision. The agent owns none.**

When any decision, ambiguity, or trade-off arises — planned or unplanned:

1. **Stop.** Do not resolve the ambiguity unilaterally. Do not pick the "obvious" option.
2. **State the decision point.** One sentence: what needs to be decided and why the agent cannot proceed without input.
3. **Present every viable option.** For each:
   - What it does concretely
   - Pros and cons
   - Which ADR, constraint, or principle it satisfies or compromises
4. **State which trade-off only the user can weigh.** Name the value judgement that separates the options.
5. **Ask a single, specific, closed question.** Not "what do you think?" — "Which option: A, B, or C?"
6. **Wait.** Do not guess. Do not default. Do not implement while waiting.

"Obvious" decisions made silently are protocol violations.

### Format

```
⚠️ Decision Required
Context: [what was being implemented]
Issue: [what problem arose]
Options:
  A) [concrete description — pros — cons — ADR alignment]
  B) [concrete description — pros — cons — ADR alignment]
Trade-off: [the value judgement only the user can weigh]
Decision needed: [single specific closed question]
```

### What is NOT a decision (noise filter — apply before raising anything)

A "decision" is only real if there are **two or more viable options with genuine trade-offs** that only the user can weigh.

**Do not raise a ⚠️ Decision Required if:**

- Only one option is technically viable — that is asking for permission to proceed. Just ask "Proceed with X?" or proceed if it follows from an approved plan.
- A plan already explicitly specifies the approach (e.g. the TODO.md names the file path, port, or resource kind). A plan passage is the decision. Do not re-decide what the plan already decided.
- The "decision" amounts to "do the work" vs "don't do the work" with no real trade-off between approaches.
- A trigger fires but the change is fully covered and scoped by the approved plan being executed.

Pseudo-decisions are noise. Noise erodes trust in the protocol. Raise only real decisions.

---

### Decision Triggers (mandatory halt)

Stop immediately on any of these **that are NOT already covered by the approved plan**:

1. Any change to `namespaceResourceWhitelist` or `clusterResourceWhitelist` in an AppProject (blast-radius change)
2. **Any new external artifact (any tier)** — before proposing adoption, classify the tier (T1–T4 per ADR-INFRA-012 §1), verify vendor identity (primary vendor org only), confirm the cooldown period has elapsed from the public release date, verify pinning is possible, and confirm a security disclosure URL exists for T1/T2. If any condition fails: use a local alternative or write local infrastructure. Community forks and third-party distributions are rejected unconditionally at all tiers — do not present them as options.
3. Any new ArgoCD Application that installs CRDs or cluster-scoped RBAC (new cluster-scope footprint)
4. Changing a SOPS-encrypted secret key name (breaks all consumers simultaneously — requires coordinated deploy)
5. Changing `failure_mode_deny`, `mtls.mode: STRICT/PERMISSIVE`, or `action: DENY/ALLOW` on any security resource
6. Adding `syncOptions: [Replace=true]` or `ServerSideApply=true` without documented rationale (destructive sync behaviour)
7. Any change that widens access: removing a NetworkPolicy rule, relaxing a PeerAuthentication, adding a `requestPrincipals: ["*"]` path exception
8. Removing, weakening, or reframing any conftest `deny` rule, bats assertion, or OPA unit test
9. Any solution with trade-offs or caveats — including "it works but..."

---

## Mandatory Review Halt (Hard Gate)

After presenting any plan, diff, manifest change, or list of options:

1. Agent presents material for review.
2. **Agent stops immediately.**
3. Agent does not edit files, run commands, or proceed.
4. Agent waits for an explicit continuation signal.

Accepted signals: "proceed" · "approved" · "continue" · "implement option X"

Anything else is not a signal. Default action when unclear: **stop and ask.**

Presenting a plan and implementing it in the same response is a protocol violation,
even if the plan appears unambiguous. Presentation and implementation are always
separate turns.

---

## Blocked / Failing State Protocol

When a helm error, ArgoCD sync failure, bats failure, conftest failure, or unexpected
constraint blocks progress:

1. **Stop the current approach.** Do not iterate on the same fix more than twice.
2. **State the blocker clearly.** What was attempted, what failed, the exact error output.
3. **Surface the design tension.** Is the failure revealing a missing resource kind in the
   AppProject whitelist? A wrong port? A namespace mismatch? An ADR conflict?
4. **Present options.** At least two concrete alternatives.
5. **Wait for decision.** Do not proceed without an accepted signal.

### No "pre-existing" excuse (hard rule)

A bats failure or conftest violation encountered during work is **yours to fix**, full stop.

- **Never** dismiss, defer, or narrate around a test failure on the grounds that it is
  "pre-existing", "unrelated", or "not caused by my change".
- **Never** report work as done while `bats tests/bats/` or `conftest test infra/k8s/`
  is red for any suite you touched.
- The only exception: a fix that carries a genuine trade-off (weakening an assertion,
  changing a NetworkPolicy rule) — raise a `⚠️ Decision Required` and let the user choose.

---

## ADR Compliance — Mandatory Review Process

### Planning phase (before any manifest changes)

1. Review all ADRs in `docs/adr/` — all files present are in force.
2. Identify potential conflicts with proposed changes.
3. Document alignment or deviations in the planning proposal.
4. Notify user immediately on any deviation.
5. Wait for decision before proceeding.

### Review phase (after implementation)

1. Re-validate all changes against accepted ADRs.
2. Security checklist:
   - [ ] No policy file duplicated inline (ADR-INFRA-001 §1 — use `Files.Get`)
   - [ ] Cross-file values annotated with `register-infra/issuer-sync` or equivalent (ADR-INFRA-001 §2)
   - [ ] Fail-closed components have ≥2 replicas + PDB + consequence comment (ADR-INFRA-002)
   - [ ] Each ArgoCD app references a scoped project, not `default` (ADR-INFRA-003)
   - [ ] HBONE NetworkPolicy present for any new ambient-enrolled namespace (ADR-INFRA-004 §2)
   - [ ] `targetRef: waypoint` used on AuthorizationPolicy, not `selector: {}` (ADR-INFRA-004)
   - [ ] New secrets are SOPS-encrypted per-namespace (ADR-INFRA-006)
   - [ ] Kyverno operator resources stay in `kyverno` project; ClusterPolicy in `platform` (ADR-INFRA-008)
   - [ ] OPA reads mesh-injected headers, not `input.parsed_jwt` (ADR-INFRA-009)
   - [ ] `deny` conditions integrated into `allow` rule, not as independent rules (ADR-INFRA-009)
3. Notify user on any compliance issue found. Wait for decision before marking phase complete.

---

## Phase Completion Criteria

A step or phase is **not complete** without:

- [ ] `helm lint infra/helm/<chart>` passes with zero errors
- [ ] `conftest test infra/k8s/ --policy tests/conftest/` passes — no violations
- [ ] `bats tests/bats/` passes for all suites relevant to the change (or skip with documented reason)
- [ ] ArgoCD Application shows `Synced` + `Healthy` in `kubectl get applications -n argocd`
- [ ] `kubectl diff` returns empty diff (no out-of-sync resources)
- [ ] OPA unit tests pass: `opa test infra/helm/opa/policies/ tests/opa/ -v`
- [ ] ADR compliance review cleared
- [ ] No security resource weakened without explicit user approval

> **Before committing:** run `infra-code-quality-review` on the diff. All MUST-FIX findings
> block the commit. For changes touching authentication, authorization, NetworkPolicy,
> secrets, or supply chain: also run `infra-security-review` on the same diff.
> The global `requesting-code-review` skill (or `infra-requesting-review`) can be used
> to structure the presentation.
