# ── Conftest policy: ciliumnetworkpolicy.rego ──────────────────────────────────
# Verifies CiliumNetworkPolicy resources enforce the health probe CIDR
# restriction pattern: only 169.254.7.127/32 (ztunnel SNAT address) may
# reach health probe ports.
#
# In Istio ambient mode, ztunnel rewrites kubelet probe source to this
# well-known link-local address. Any other source CIDR would allow
# non-probe traffic to reach PERMISSIVE health ports.
#
# Run: conftest test infra/k8s/network-policy/register.yaml -p tests/conftest/policy/
#      conftest test infra/k8s/network-policy/infra.yaml    -p tests/conftest/policy/
# ──────────────────────────────────────────────────────────────────────────────
package main

import future.keywords.in

# CiliumNetworkPolicy health check rules must restrict source to ztunnel SNAT.
deny[msg] {
    input.kind == "CiliumNetworkPolicy"
    contains(input.metadata.name, "healthcheck")
    ingress_rule := input.spec.ingress[_]
    cidrs := {c | c := ingress_rule.fromCIDR[_]}
    not "169.254.7.127/32" in cidrs
    msg := sprintf("CiliumNetworkPolicy '%s' healthcheck does not restrict source to 169.254.7.127/32 (ztunnel SNAT)", [input.metadata.name])
}

# CiliumNetworkPolicy healthcheck rules must restrict to a single port.
deny[msg] {
    input.kind == "CiliumNetworkPolicy"
    contains(input.metadata.name, "healthcheck")
    ingress_rule := input.spec.ingress[_]
    port_count := count(ingress_rule.toPorts[_].ports)
    port_count > 1
    msg := sprintf("CiliumNetworkPolicy '%s' allows multiple ports — each healthcheck should expose exactly one port", [input.metadata.name])
}

# No CiliumNetworkPolicy should use fromEntities: world (overly permissive).
deny[msg] {
    input.kind == "CiliumNetworkPolicy"
    entity := input.spec.ingress[_].fromEntities[_]
    entity == "world"
    msg := sprintf("CiliumNetworkPolicy '%s' uses fromEntities: world — too permissive for health probes", [input.metadata.name])
}
