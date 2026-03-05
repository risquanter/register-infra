# ── Conftest policy: envoyfilter.rego ──────────────────────────────────────────
# Verifies EnvoyFilter strip-identity-headers removes all identity headers.
# Run: conftest test infra/k8s/istio/envoy-filter-strip-headers.yaml -p tests/conftest/policy/
# ──────────────────────────────────────────────────────────────────────────────
package main

import future.keywords.in

# The set of headers the mesh owns. External clients must never be able to
# set these — the EnvoyFilter must strip them before JWT validation.
required_stripped_headers := {"x-user-id", "x-user-email", "x-user-roles"}

deny[msg] {
    input.kind == "EnvoyFilter"
    headers_to_remove := {h | h := input.spec.configPatches[_].patch.value.typed_config.request_headers_to_remove[_]}
    missing := required_stripped_headers - headers_to_remove
    count(missing) > 0
    msg := sprintf("EnvoyFilter '%s' is missing identity headers in request_headers_to_remove: %v", [input.metadata.name, missing])
}

deny[msg] {
    input.kind == "EnvoyFilter"
    input.metadata.name == "strip-identity-headers"
    not input.spec.workloadSelector.labels["gateway.istio.io/managed"]
    msg := "EnvoyFilter strip-identity-headers must target the waypoint proxy (gateway.istio.io/managed label)"
}
