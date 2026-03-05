# ── Conftest policy: networkpolicy.rego ────────────────────────────────────────
# Verifies default-deny-all NetworkPolicy exists and DNS egress is allowed.
# Evaluated per-document (conftest --combine not required).
#
# Run: conftest test infra/k8s/network-policy/register.yaml -p tests/conftest/policy/
# ──────────────────────────────────────────────────────────────────────────────
package main

import future.keywords.in

# default-deny-all must cover both Ingress and Egress.
deny[msg] {
    input.kind == "NetworkPolicy"
    input.metadata.name == "default-deny-all"
    policy_types := {t | t := input.spec.policyTypes[_]}
    missing := {"Ingress", "Egress"} - policy_types
    count(missing) > 0
    msg := sprintf("NetworkPolicy default-deny-all is missing policyTypes: %v", [missing])
}

# DNS egress policy must allow both UDP/53 and TCP/53.
deny[msg] {
    input.kind == "NetworkPolicy"
    input.metadata.name == "allow-egress-dns"
    allowed_ports := {sprintf("%s/%d", [p.protocol, p.port]) |
        p := input.spec.egress[_].ports[_]
    }
    required := {"UDP/53", "TCP/53"}
    missing := required - allowed_ports
    count(missing) > 0
    msg := sprintf("NetworkPolicy allow-egress-dns is missing DNS ports: %v", [missing])
}
