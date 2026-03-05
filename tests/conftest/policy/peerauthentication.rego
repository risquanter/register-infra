# ── Conftest policy: peerauthentication.rego ──────────────────────────────────
# Verifies PeerAuthentication is always STRICT mode.
# PERMISSIVE or unset mode allows plaintext bypass of the mesh.
#
# Run: conftest test infra/k8s/istio/peer-authentication.yaml -p tests/conftest/policy/
# ──────────────────────────────────────────────────────────────────────────────
package main

deny[msg] {
    input.kind == "PeerAuthentication"
    not input.spec.mtls.mode == "STRICT"
    msg := sprintf("PeerAuthentication '%s/%s' must use STRICT mode, got '%s'", [
        input.metadata.namespace,
        input.metadata.name,
        object.get(object.get(input.spec, "mtls", {}), "mode", "<unset>"),
    ])
}

# Port-level overrides must not weaken to PERMISSIVE or DISABLE.
deny[msg] {
    input.kind == "PeerAuthentication"
    port_mtls := input.spec.portLevelMtls[port]
    port_mtls.mode != "STRICT"
    msg := sprintf("PeerAuthentication '%s/%s' port %v uses mode '%s' — must be STRICT", [
        input.metadata.namespace,
        input.metadata.name,
        port,
        port_mtls.mode,
    ])
}
