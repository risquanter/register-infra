# conftest policy: Keycloak realm security controls.
#
# Validates the PRODUCTION realm JSON (register-realm-prod.json) against
# security requirements. All rules are guarded by `input.realm` so they
# only fire when the input is a Keycloak realm export (not YAML manifests).
#
# Run against the prod realm only:
#   conftest test infra/helm/keycloak/realms/register-realm-prod.json \
#     --policy tests/conftest/policy/
#
# DEFENSE-IN-DEPTH LAYERS:
#   L1 (this policy) — static:     blocks ROPC in production realm JSON before commit
#   L2 (bats)        — behavioral: tests that live Keycloak rejects ROPC requests
#   L3 (Helm values) — structural: production values.yaml references prod realm JSON
package main

# GUARD: only evaluate realm rules when the input is a Keycloak realm JSON.
# Keycloak realm exports always contain a top-level "realm" string field.
is_realm_json {
  input.realm
  is_string(input.realm)
}

# deny if any client has ROPC (directAccessGrantsEnabled) enabled
deny[msg] {
  is_realm_json
  client := input.clients[_]
  client.directAccessGrantsEnabled == true
  msg := sprintf(
    "keycloak-realm: client '%s': directAccessGrantsEnabled must be false in the production realm (ROPC is deprecated in OAuth 2.1)",
    [client.clientId],
  )
}

# deny if any client uses implicit flow (also deprecated in OAuth 2.1)
deny[msg] {
  is_realm_json
  client := input.clients[_]
  client.implicitFlowEnabled == true
  msg := sprintf(
    "keycloak-realm: client '%s': implicitFlowEnabled must be false (implicit flow is deprecated in OAuth 2.1)",
    [client.clientId],
  )
}

# deny if the realm does not require SSL for external requests
deny[msg] {
  is_realm_json
  input.sslRequired != "external"
  input.sslRequired != "all"
  msg := sprintf(
    "keycloak-realm: sslRequired is '%v'; must be 'external' or 'all' in the production realm",
    [input.sslRequired],
  )
}

# warn if required roles are missing from the realm
warn[msg] {
  is_realm_json
  roles := {r.name | r := input.roles.realm[_]}
  required := {"editor", "analyst", "viewer", "team_admin"}
  missing := required - roles
  count(missing) > 0
  msg := sprintf("keycloak-realm: realm roles missing: %v", [missing])
}
