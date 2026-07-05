---
name: infra-requesting-review
description: Use when completing infra tasks, implementing Helm charts, NetworkPolicies, ArgoCD apps, or security manifests before committing. Runs the infra-code-quality-review skill on the diff.
user-invokable: true
---

# Requesting Code Review — Register Infra

Run the `infra-code-quality-review` skill before committing to catch supply chain,
security, ADR compliance, and configuration issues before they reach the cluster.

**Core principle:** A broken NetworkPolicy or misconfigured AuthorizationPolicy is
silent in git. It only fails in the cluster — often at 2am. Review catches it in the diff.

---

## When to Request Review

**Mandatory:**
- After completing any TODO.md step or sub-step
- After adding or modifying: Helm chart templates, NetworkPolicies, Istio manifests,
  ArgoCD Applications or AppProjects, OPA/Rego files, conftest policies, SOPS secrets
- Before committing anything that touches security resources (PeerAuthentication,
  AuthorizationPolicy, EnvoyFilter, `failure_mode_deny`)
- Before merging any branch to `main`

**Optional but valuable:**
- When a `helm lint` or `conftest` error is unclear (fresh pass through the skill)
- After a refactor that touches multiple files

---

## How to Request

**Step 1 — Get the diff range:**
```bash
BASE_SHA=$(git rev-parse origin/main)   # or HEAD~N for uncommitted work
HEAD_SHA=$(git rev-parse HEAD)

# See what changed
git diff --stat "$BASE_SHA" "$HEAD_SHA"
```

**Step 2 — Run the quality review and security review skills:**

Invoke `infra-code-quality-review` with the changed files as argument. The skill
runs 10 functional-correctness passes (ADR compliance → Helm → NetworkPolicy →
OPA mechanics → ArgoCD → secret wiring → test coverage → docs → plan fidelity →
holistic consistency).

For changes touching authentication, authorization, NetworkPolicy, secrets,
admission policy, external artifacts, or supply chain: **also invoke
`infra-security-review`** on the same diff — this is mandatory, because the
checks for those areas live only there. The two skills split ownership with no
overlap: the quality review checks that what should work, works (rendering,
referential integrity, traffic that must flow); the security review checks that
what shouldn't be possible, isn't (trust boundaries, supply chain, secrets,
blast radius).

To dispatch as a subagent: provide the diff, the relevant TODO.md steps, and the
ADRs that apply to the change. The reviewer must not have access to this session's
history — only the files and the skill.

**Step 3 — Run verification commands before reporting complete:**
```bash
helm lint infra/helm/<chart>
conftest test infra/k8s/ --policy tests/conftest/
opa test infra/helm/opa/policies/ tests/opa/ -v
```

All three must pass. If any fail, fix before requesting review.

**Step 4 — Act on findings:**
- **MUST-FIX**: fix immediately, do not proceed
- **SHOULD-FIX**: fix before committing unless explicitly deferred with a TODO note
- **NOTE**: record in TODO.md housekeeping if systemic

---

## Infra-Specific Review Checklist

Run this quick pre-flight before invoking the full skill:

```
[ ] helm lint passes with zero errors
[ ] conftest test passes with zero failures
[ ] opa test passes (if OPA files changed)
[ ] No *.enc.yaml contains plaintext — sops --decrypt | grep "kind: Secret" to verify
[ ] No :latest or mutable image tag added
[ ] No new repoURL that isn't in ADR-INFRA-012 §7 approved list
[ ] TODO.md step items marked [x] for work actually completed
[ ] ADR compliance checklist in infra-code-quality-review Pass 1 cleared
```

---

## Mandatory Pre-Commit Gate

Before any `git push` to `main`, all of the following must be green:

```bash
# Static checks (no cluster required)
helm lint infra/helm/*/
conftest test infra/k8s/ --policy tests/conftest/
opa test infra/helm/opa/policies/ tests/opa/ -v

# Render check — catch template errors and whitelist gaps
for chart in infra/helm/*/; do
  helm template "$(basename $chart)" "$chart" --namespace infra \
    | grep "^kind:" | sort | uniq
done
```

If a step is not yet reachable (cluster tests require running cluster), document
the skip reason in the commit message.

---

## Red Flags — Never Do These

- Skip review because "it's just a comment fix" — security comments are often load-bearing
- Commit with a failing conftest — the policy exists because something bad happened before
- Add a new container image without completing the supply chain check (infra-security-review Pass S5)
- Mark a TODO step `[x]` without running the verification commands above
- Push code while a `⚠️ Decision Required` is unresolved
