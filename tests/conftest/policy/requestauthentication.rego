# ── Conftest policy: requestauthentication.rego ───────────────────────────────
# Verifies RequestAuthentication maps JWT sub → x-user-id and sets audiences.
#
# Run: conftest test infra/k8s/istio/request-authentication.yaml -p tests/conftest/policy/
# ──────────────────────────────────────────────────────────────────────────────
package main

import future.keywords.in

deny[msg] {
    input.kind == "RequestAuthentication"
    jwt_rules := input.spec.jwtRules
    not has_x_user_id_mapping(jwt_rules)
    msg := sprintf("RequestAuthentication '%s' does not map JWT 'sub' claim to 'x-user-id' header via outputClaimToHeaders", [input.metadata.name])
}

has_x_user_id_mapping(rules) {
    mapping := rules[_].outputClaimToHeaders[_]
    mapping.header == "x-user-id"
    mapping.claim == "sub"
}

# Audience must be set to prevent token confusion attacks.
deny[msg] {
    input.kind == "RequestAuthentication"
    rule := input.spec.jwtRules[_]
    not rule.audiences
    msg := sprintf("RequestAuthentication '%s' jwtRule has no audiences — vulnerable to token confusion", [input.metadata.name])
}

deny[msg] {
    input.kind == "RequestAuthentication"
    rule := input.spec.jwtRules[_]
    rule.audiences
    count(rule.audiences) == 0
    msg := sprintf("RequestAuthentication '%s' jwtRule has empty audiences list", [input.metadata.name])
}
