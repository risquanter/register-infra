# ── Conftest policy: kyvernopolicy.rego ────────────────────────────────────────
# Guards against ADR-INFRA-008 regressions:
#   1. failurePolicy must be Ignore (not Fail) — Kyverno outage must not block
#      all pod creation; PSS admission is the enforcement backstop.
#   2. Mutation must inject seccompProfile.type: RuntimeDefault — the entire
#      purpose of the policy.
#   3. Policy must be scoped to the register namespace — overly broad mutation
#      affects namespaces that may intentionally omit seccompProfile.
#
# Run: conftest test infra/k8s/kyverno/inject-seccomp-profile.yaml -p tests/conftest/policy/
# ──────────────────────────────────────────────────────────────────────────────
package main

import future.keywords.in

# failurePolicy must be Ignore for mutation-only policies.
# Fail blocks ALL pod creation in matched namespaces when Kyverno is down.
deny[msg] {
    input.kind == "ClusterPolicy"
    input.spec.failurePolicy != "Ignore"
    msg := sprintf(
        "ClusterPolicy '%s' has failurePolicy '%s' — mutation-only policies must use Ignore so Kyverno outage does not block pod creation (ADR-INFRA-008)",
        [input.metadata.name, input.spec.failurePolicy],
    )
}

# The inject-seccomp-profile policy must actually inject RuntimeDefault.
deny[msg] {
    input.kind == "ClusterPolicy"
    input.metadata.name == "inject-seccomp-profile"
    rule := input.spec.rules[_]
    rule.mutate.patchStrategicMerge.spec.securityContext.seccompProfile.type != "RuntimeDefault"
    msg := sprintf(
        "ClusterPolicy '%s' rule '%s' mutates seccompProfile to '%s' instead of RuntimeDefault",
        [input.metadata.name, rule.name, rule.mutate.patchStrategicMerge.spec.securityContext.seccompProfile.type],
    )
}

# inject-seccomp-profile must be scoped to the register namespace.
deny[msg] {
    input.kind == "ClusterPolicy"
    input.metadata.name == "inject-seccomp-profile"
    rule := input.spec.rules[_]
    match_entry := rule.match.any[_]
    namespaces := {ns | ns := match_entry.resources.namespaces[_]}
    not namespaces["register"]
    msg := sprintf(
        "ClusterPolicy '%s' rule '%s' does not target the register namespace — policy must be scoped to register (ADR-INFRA-008)",
        [input.metadata.name, rule.name],
    )
}
