---
name: infra-receiving-review
description: Use when receiving code review feedback on infra manifests, Helm charts, NetworkPolicies, or security resources — before implementing suggestions, especially if feedback seems unclear or contradicts established ADR decisions.
user-invokable: true
---

# Receiving Code Review — Register Infra

## Core Principle

Review feedback requires technical evaluation, not performative agreement.
A reviewer suggesting a change to a NetworkPolicy or PeerAuthentication may not
understand Istio ambient mode, HBONE port semantics, or the ADR rationale behind
the current design. Verify before implementing.

---

## The Response Pattern

```
WHEN receiving review feedback on infra changes:

1. READ   — complete feedback without reacting
2. RESTATE — restate the technical requirement in one sentence (or ask)
3. VERIFY  — check: does this contradict an ADR? Does the reviewer
             understand ambient mode / HBONE / SOPS context?
4. EVALUATE — technically correct for THIS cluster topology?
5. RESPOND  — technical acknowledgment or reasoned pushback
6. IMPLEMENT — one item at a time, run conftest/helm-lint after each
```

---

## Forbidden Responses

**NEVER:**
- "You're absolutely right!" — performative, not technical
- "Great suggestion!" — see above
- "Let me implement that now" — before checking the ADR and running lint

**INSTEAD:**
- Restate what the change does concretely
- State which ADR it aligns with or contradicts
- Push back with the ADR reference if the suggestion violates a decision

---

## Handling Unclear Feedback

If any item is unclear: **stop, ask, do not implement anything**.

Items in an infra diff are often coupled. A reviewer saying "fix the NetworkPolicy"
without specifying which rule, in which direction, for which port, can mean
opposite things depending on context (tightening vs. loosening access).

```
Reviewer: "Fix the NetworkPolicy for SpiceDB"

❌ WRONG: Guess and implement
✅ RIGHT: "Which rule — ingress from register, egress to PostgreSQL,
          or the kubelet probe CiliumNP? Tighten or loosen?"
```

---

## Infra-Specific Skepticism Checks

Before implementing any suggestion, run these checks:

### 1. Does the reviewer understand Istio ambient mode?

Suggestions that assume sidecar-mode semantics are wrong for this cluster.

| Red flag suggestion | Correct understanding |
|---|---|
| "Use `selector: {}` on AuthorizationPolicy for namespace-wide enforcement" | ❌ In ambient mode, ztunnel drops all HTTP rules on selector policies → L4 default deny |
| "Allow traffic on the application port (8080) for intra-namespace rules" | ❌ Intra-namespace in ambient uses HBONE port 15008; per-service rules are documentation only |
| "The PeerAuthentication should be PERMISSIVE for easier debugging" | ❌ Violates ADR-INFRA-004; raises a Decision Required before any change |

### 2. Does the suggestion weaken a security invariant?

Any suggestion to:
- Remove a NetworkPolicy rule
- Add a path to `allow-capability-urls`
- Change `failure_mode_deny` to false
- Relax PeerAuthentication from STRICT to PERMISSIVE at namespace level
- Remove a conftest `deny` rule

...requires a `⚠️ Decision Required` with explicit user sign-off. Do not implement
without it, regardless of the reviewer's confidence.

### 3. Does it violate an ADR?

Before implementing: `grep -r "ADR-INFRA-0" docs/adr/` to find the relevant ADR.
If the suggestion contradicts an accepted ADR, the response is:

```
"This contradicts ADR-INFRA-00X §Y. The ADR was accepted because [rationale].
If you think the ADR should be revisited, raise that separately."
```

### 4. YAGNI check for infra resources

If a reviewer suggests adding a NetworkPolicy rule, PeerAuthentication entry,
or AppProject whitelist kind for a service or resource that does not exist:

```bash
# Does the suggested service actually exist?
kubectl get deployment <name> -A 2>/dev/null || echo "does not exist"
grep -r "<name>" infra/helm/ infra/argocd/ | grep -v "test\|comment"
```

If it doesn't exist, reject the suggestion: "No workload named X is deployed.
Adding rules for non-existent services creates false trust in the NP coverage."

---

## Source-Specific Handling

### From the user (human partner)
- **Trusted** — implement after understanding
- Still ask if scope or intent is unclear
- No performative agreement — just restate and act

### From an external reviewer or subagent
```
BEFORE implementing:
  1. Does it contradict an ADR? → cite the ADR, push back
  2. Does it assume sidecar Istio semantics? → correct the assumption
  3. Does it weaken a security boundary? → raise ⚠️ Decision Required
  4. Is the suggested service/resource real? → YAGNI check
  5. Does reviewer have full context (HBONE, SOPS, ambient mode)? → provide it
```

---

## Implementation Order for Multi-Item Feedback

```
FOR multi-item review feedback:
  1. Clarify unclear items FIRST — do not implement any until all are clear
  2. Then implement in this order:
     a. Security issues (fail-closed gaps, plaintext secrets, widened access)
     b. Correctness issues (wrong port, wrong label selector, broken NP rule)
     c. Quality debt (comments, documentation, SHOULD-FIX items)
  3. After each item: run conftest + helm lint
  4. Verify no regressions before moving to the next item
```

---

## When to Push Back

Push back — with the relevant ADR section cited — when a suggestion:

- Assumes Istio sidecar semantics in an ambient-mode cluster
- Weakens a security boundary without acknowledging the trade-off
- Contradicts an accepted ADR (ADR-INFRA-001 through ADR-INFRA-012)
- Would cause a conftest policy violation (i.e., the policy exists for a reason)
- Adds infrastructure for a service or resource that does not exist (YAGNI)
- Ignores the HBONE port semantics for intra-namespace ambient traffic
