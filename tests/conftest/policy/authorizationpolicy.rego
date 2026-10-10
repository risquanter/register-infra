# ── Conftest policy: authorizationpolicy.rego ─────────────────────────────────
# Guards against C1 regression: no DENY AuthorizationPolicy may target identity
# headers.  The removed DENY policy matched legitimate x-user-id headers
# injected by jwt_authn, blocking all authenticated traffic.
#
# Run: conftest test infra/k8s/istio/authorization-policy.yaml -p tests/conftest/policy/
# ──────────────────────────────────────────────────────────────────────────────
package main

import rego.v1

# Identity header names that must never appear in DENY policies.
identity_headers := {"x-user-id", "x-user-email", "x-user-roles"}

# Block any DENY AuthorizationPolicy that references identity headers in its
# rules.  This catches the exact C1 bug pattern and any variant of it.
deny contains msg if {
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

# ALLOW policies must either have at least one rule with requestPrincipals (authenticated
# routes), OR be a public-path-only policy (every rule has `to` but no `from`).
# A policy with only `to.operation.paths` rules is intentionally public — no
# principal required because the path itself defines the access level
# (e.g. allow-capability-urls for /w/*, /health).
deny contains msg if {
	input.kind == "AuthorizationPolicy"
	input.spec.action == "ALLOW"
	not has_principal_rule
	not is_public_path_only_policy
	msg := sprintf("AuthorizationPolicy '%s' has ALLOW action but no rule with requestPrincipals — authenticated routes unprotected", [input.metadata.name])
}

has_principal_rule if {
	input.spec.rules[_].from[_].source.requestPrincipals
}

# All rules have `to` (path-based) and no `from` (no principal check).
# This is the canonical public-route pattern (ADR-INFRA-007 §3).
is_public_path_only_policy if {
	count(input.spec.rules) > 0
	every rule in input.spec.rules {
		not rule.from
		rule.to
	}
}

# A DENY AuthorizationPolicy must be attached to the waypoint Gateway. ztunnel
# evaluates L4 only, so an HTTP rule (path, method, header) attached to pods by
# selector is dropped: the policy reads as enforced and denies nothing
# (ADR-INFRA-004 §3).
deny contains msg if {
	input.kind == "AuthorizationPolicy"
	input.spec.action == "DENY"
	not waypoint_targeted

	msg := sprintf(
		"AuthorizationPolicy '%s' has action DENY but is not attached to the waypoint Gateway. ztunnel cannot evaluate HTTP rules, so its rules would be silently dropped — see ADR-INFRA-004 §3.",
		[input.metadata.name],
	)
}

waypoint_targeted if {
	input.spec.targetRef.kind == "Gateway"
	input.spec.targetRef.name == "waypoint"
}

# A DENY rule carrying none of `to`, `from` or `when` matches every request and
# takes the whole namespace offline. Istio accepts such a rule without
# complaint, so nothing but this check stands between a dropped clause and a
# total outage.
deny contains msg if {
	input.kind == "AuthorizationPolicy"
	input.spec.action == "DENY"
	rule := input.spec.rules[_]
	not rule.to
	not rule.from
	not rule.when

	msg := sprintf(
		"AuthorizationPolicy '%s' has a DENY rule with no 'to', 'from' or 'when' clause. Such a rule matches every request and denies all traffic to the waypoint.",
		[input.metadata.name],
	)
}
