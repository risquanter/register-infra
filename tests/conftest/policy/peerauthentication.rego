# ── Conftest policy: peerauthentication.rego ──────────────────────────────────
# Verifies PeerAuthentication is always STRICT mode at namespace level.
# Port-level PERMISSIVE is allowed ONLY on explicitly known health probe ports
# where kubelet needs plaintext access (ztunnel SNAT to 169.254.7.127).
# DISABLE mode is never acceptable.
#
# Known health probe ports (PERMISSIVE allowed):
#   8282 — OPA diagnostic port (/health, /metrics)
#   8091 — register health probe port (HealthProbeServer)
#   8080 — frontend nginx health port (also serves app — THREAT-CATALOG H1)
#   9000 — Keycloak management port (/health/live, /health/ready)
#
# Run: conftest test infra/k8s/istio/peer-authentication.yaml -p tests/conftest/policy/
# ──────────────────────────────────────────────────────────────────────────────
package main

import future.keywords.in

# Namespace-level PeerAuthentication must be STRICT.
# Resources with a selector (workload-scoped) are port-level overrides
# and are checked by the port-level rule below.
deny[msg] {
    input.kind == "PeerAuthentication"
    not input.spec.selector          # namespace-level (no workload selector)
    not input.spec.mtls.mode == "STRICT"
    msg := sprintf("PeerAuthentication '%s/%s' must use STRICT mode, got '%s'", [
        input.metadata.namespace,
        input.metadata.name,
        object.get(object.get(input.spec, "mtls", {}), "mode", "<unset>"),
    ])
}

# Known health probe ports where PERMISSIVE is architecturally required.
# Each port has defense-in-depth: CiliumNetworkPolicy restricts source to
# 169.254.7.127/32 (ztunnel SNAT), and no Service exposes these ports externally.
allowed_permissive_ports := {"8282", "8091", "8080", "9000"}

# Port-level overrides must not use DISABLE (ever) or PERMISSIVE on
# unexpected ports. PERMISSIVE is tolerated only on allowed_permissive_ports.
deny[msg] {
    input.kind == "PeerAuthentication"
    port_mtls := input.spec.portLevelMtls[port]
    port_mtls.mode == "DISABLE"
    msg := sprintf("PeerAuthentication '%s/%s' port %v uses DISABLE — plaintext without mesh protection", [
        input.metadata.namespace,
        input.metadata.name,
        port,
    ])
}

deny[msg] {
    input.kind == "PeerAuthentication"
    port_mtls := input.spec.portLevelMtls[port]
    port_mtls.mode == "PERMISSIVE"
    not port in allowed_permissive_ports
    msg := sprintf("PeerAuthentication '%s/%s' port %v uses PERMISSIVE but is not a known health probe port (allowed: %v)", [
        input.metadata.namespace,
        input.metadata.name,
        port,
        allowed_permissive_ports,
    ])
}
