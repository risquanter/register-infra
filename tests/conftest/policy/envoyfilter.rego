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
    # Collect all headers listed in request_headers_to_remove across all configPatches.
    # If no configPatch declares this field, headers_to_remove is an empty set and
    # the count check below prevents a false positive — the filter simply isn't a
    # header-stripping filter. This is content-aware, not name-specific: any
    # EnvoyFilter that strips headers must strip all three identity headers.
    headers_to_remove := {h | h := input.spec.configPatches[_].patch.value.typed_config.request_headers_to_remove[_]}
    count(headers_to_remove) > 0
    missing := required_stripped_headers - headers_to_remove
    count(missing) > 0
    msg := sprintf("EnvoyFilter '%s' declares request_headers_to_remove but is missing identity headers: %v", [input.metadata.name, missing])
}

deny[msg] {
    input.kind == "EnvoyFilter"
    input.metadata.name == "strip-identity-headers"
    not input.spec.workloadSelector.labels["gateway.istio.io/managed"]
    msg := "EnvoyFilter strip-identity-headers must target the waypoint proxy (gateway.istio.io/managed label)"
}
