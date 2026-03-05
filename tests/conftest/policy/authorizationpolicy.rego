# ── Conftest policy: authorizationpolicy.rego ─────────────────────────────────
# Guards against C1 regression: no DENY AuthorizationPolicy may target identity
# headers.  The removed DENY policy matched legitimate x-user-id headers
# injected by jwt_authn, blocking all authenticated traffic.
#
# Run: conftest test infra/k8s/istio/authorization-policy.yaml -p tests/conftest/policy/
# ──────────────────────────────────────────────────────────────────────────────
package main

import future.keywords.in

# Identity header names that must never appear in DENY policies.
identity_headers := {"x-user-id", "x-user-email", "x-user-roles"}

# Block any DENY AuthorizationPolicy that references identity headers in its
# rules.  This catches the exact C1 bug pattern and any variant of it.
deny[msg] {
    input.kind == "AuthorizationPolicy"
    input.spec.action == "DENY"

    # Walk the entire rules tree to find any header key reference.
    rule := input.spec.rules[_]
    walk(rule, [path, value])
    is_string(value)
    lower(value) == identity_headers[_]

    msg := sprintf(
        "AuthorizationPolicy '%s' has action DENY and references identity header '%s'. This pattern causes C1 regression — see ADR-INFRA-005 and SECURITY-FLOW.md.",
        [input.metadata.name, value],
    )
}

# ALLOW policies must exist — at least one rule with requestPrincipals.
deny[msg] {
    input.kind == "AuthorizationPolicy"
    input.spec.action == "ALLOW"
    not has_principal_rule
    msg := sprintf("AuthorizationPolicy '%s' has ALLOW action but no rule with requestPrincipals — authenticated routes unprotected", [input.metadata.name])
}

has_principal_rule {
    input.spec.rules[_].from[_].source.requestPrincipals
}
