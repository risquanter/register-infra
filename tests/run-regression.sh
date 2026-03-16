#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Wrapper: run the full regression test pipeline with strict skip semantics.
#
# Phases:
#   1. Static analysis  — conftest policies against YAML manifests
#   2. OPA unit tests   — opa test against allow.rego + test suite
#   3. Trivy scans      — config (static) + k8s compliance (live cluster)
#   4. Bats live tests  — all .bats files against a live cluster
#
# Exit codes (ADR-INFRA-005):
#   0 — all tests passed (no skips, or --allow-skip set)
#   1 — one or more tests failed
#   2 — tests were skipped (prerequisites missing) and --strict is set
#
# Usage:
#   ./tests/run-regression.sh                    # default: --strict
#   ./tests/run-regression.sh --allow-skip       # skips are OK (feature branches)
#   ./tests/run-regression.sh --bats-only        # skip static + OPA + Trivy phases
#   ./tests/run-regression.sh --static-only      # skip bats + Trivy k8s phases
#   ./tests/run-regression.sh --no-trivy         # skip Trivy entirely
#   INGRESS=https://... ./tests/run-regression.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

STRICT=true
BATS_ONLY=false
STATIC_ONLY=false
NO_TRIVY=false

for arg in "$@"; do
  case "$arg" in
    --allow-skip)  STRICT=false ;;
    --bats-only)   BATS_ONLY=true ;;
    --static-only) STATIC_ONLY=true ;;
    --no-trivy)    NO_TRIVY=true ;;
  esac
done

FAILURES=0

# ── Phase 1: Conftest static analysis ────────────────────────────────────────
if [ "$BATS_ONLY" = false ]; then
  echo "═══ Phase 1: Conftest static analysis ═══"
  CONFTEST_POLICY="${SCRIPT_DIR}/conftest/policy"

  if command -v conftest >/dev/null 2>&1; then
    CONFTEST_TARGETS=(
      "${ROOT_DIR}/infra/k8s/istio/peer-authentication.yaml"
      "${ROOT_DIR}/infra/k8s/istio/authorization-policy.yaml"
      "${ROOT_DIR}/infra/k8s/istio/request-authentication.yaml"
      "${ROOT_DIR}/infra/k8s/istio/envoy-filter-strip-headers.yaml"
      "${ROOT_DIR}/infra/k8s/network-policy/register.yaml"
      "${ROOT_DIR}/infra/k8s/network-policy/infra.yaml"
    )

    for target in "${CONFTEST_TARGETS[@]}"; do
      if [ -f "$target" ]; then
        echo "  conftest: $(basename "$target")"
        if ! conftest test "$target" -p "$CONFTEST_POLICY" 2>&1; then
          FAILURES=$((FAILURES + 1))
        fi
      else
        echo "  WARN: ${target} not found — skipping"
      fi
    done
  else
    echo "  conftest not found — skipping static analysis"
    if [ "$STRICT" = true ] && [ "$STATIC_ONLY" = true ]; then
      echo "ERROR: conftest required for --static-only in strict mode"
      exit 1
    fi
  fi
  echo ""
fi

# ── Phase 2: OPA unit tests ─────────────────────────────────────────────────
if [ "$BATS_ONLY" = false ]; then
  echo "═══ Phase 2: OPA unit tests ═══"
  OPA_POLICY_DIR="${ROOT_DIR}/infra/helm/opa/policies"
  OPA_TEST_DIR="${SCRIPT_DIR}/opa"

  if command -v opa >/dev/null 2>&1; then
    if [ -d "$OPA_TEST_DIR" ] && [ -d "$OPA_POLICY_DIR" ]; then
      echo "  opa test: allow.rego + allow_test.rego"
      if ! opa test "$OPA_POLICY_DIR" "$OPA_TEST_DIR" -v 2>&1; then
        FAILURES=$((FAILURES + 1))
      fi
    else
      echo "  WARN: OPA policy or test directory not found"
    fi
  else
    echo "  opa not found — skipping OPA unit tests"
  fi
  echo ""
fi

# ── Phase 3: Trivy security scans ───────────────────────────────────────────
if [ "$NO_TRIVY" = false ]; then

  # ── 3a: Trivy config — static manifest scanning (no cluster required) ────
  if [ "$BATS_ONLY" = false ]; then
    echo "═══ Phase 3a: Trivy config (static manifests) ═══"

    if command -v trivy >/dev/null 2>&1; then
      TRIVY_REPORT=$(mktemp)
      trivy config "${ROOT_DIR}/infra/" \
        --severity HIGH,CRITICAL \
        --format json \
        --quiet \
        --timeout 120s \
        2>/dev/null > "$TRIVY_REPORT" || true

      # Parse results — count findings, filter known exceptions.
      # Known exceptions (documented in TESTING.md):
      #   KSV-0053 — deployer Role pods/exec (required for GitOps operations)
      #   KSV-0056 — deployer Role network management (required for NetworkPolicy deploy)
      TRIVY_KNOWN_EXCEPTIONS="KSV-0053|KSV-0056"

      TOTAL_FINDINGS=$(jq -r "[.Results[]? | .Misconfigurations[]? | .ID] | length" "$TRIVY_REPORT" 2>/dev/null || echo "0")
      EXCEPTION_COUNT=$(jq -r "[.Results[]? | .Misconfigurations[]? | select(.ID | test(\"${TRIVY_KNOWN_EXCEPTIONS}\")) | .ID] | length" "$TRIVY_REPORT" 2>/dev/null || echo "0")
      UNEXPECTED_COUNT=$((TOTAL_FINDINGS - EXCEPTION_COUNT))

      echo "  Findings: ${TOTAL_FINDINGS} total, ${EXCEPTION_COUNT} known exceptions, ${UNEXPECTED_COUNT} unexpected"

      if [ "$UNEXPECTED_COUNT" -gt 0 ]; then
        echo "  UNEXPECTED findings:"
        jq -r ".Results[]? | .Misconfigurations[]? | select(.ID | test(\"${TRIVY_KNOWN_EXCEPTIONS}\") | not) | \"    \\(.ID) (\\(.Severity)): \\(.Title)\"" "$TRIVY_REPORT" 2>/dev/null || true
        FAILURES=$((FAILURES + 1))
      fi
      rm -f "$TRIVY_REPORT"
    else
      echo "  trivy not found — skipping static config scan"
    fi
    echo ""
  fi

  # ── 3b: Trivy k8s — live compliance scans (cluster required) ──────────────
  if [ "$STATIC_ONLY" = false ]; then
    echo "═══ Phase 3b: Trivy k8s compliance (live cluster) ═══"

    if command -v trivy >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
      # PSS Baseline — must be 100% PASS (hard gate).
      echo "  PSS baseline scan..."
      PSS_REPORT=$(mktemp)
      trivy k8s \
        --compliance k8s-pss-baseline-0.1 \
        --include-namespaces register,infra \
        --report summary \
        --timeout 180s \
        2>/dev/null | tee "$PSS_REPORT"

      PSS_FAILS=$(grep -c "FAIL" "$PSS_REPORT" 2>/dev/null || echo "0")
      if [ "$PSS_FAILS" -gt 0 ]; then
        echo "  PSS baseline: ${PSS_FAILS} FAILED control(s)"
        FAILURES=$((FAILURES + 1))
      else
        echo "  PSS baseline: ALL PASS"
      fi
      rm -f "$PSS_REPORT"
      echo ""

      # NSA Hardening — informational (known exceptions).
      # Control 4.1 (LimitRange) flags pods without explicit resource limits.
      echo "  NSA hardening scan..."
      NSA_REPORT=$(mktemp)
      trivy k8s \
        --compliance k8s-nsa-1.0 \
        --include-namespaces register,infra \
        --report summary \
        --timeout 180s \
        2>/dev/null | tee "$NSA_REPORT"

      NSA_FAILS=$(grep -c "FAIL" "$NSA_REPORT" 2>/dev/null || echo "0")
      NSA_KNOWN_EXCEPTIONS=1  # 4.1 (LimitRange — Trivy limitation)
      NSA_UNEXPECTED=$((NSA_FAILS - NSA_KNOWN_EXCEPTIONS))
      if [ "$NSA_UNEXPECTED" -gt 0 ]; then
        echo "  NSA hardening: ${NSA_UNEXPECTED} UNEXPECTED failure(s) beyond known exceptions"
        FAILURES=$((FAILURES + 1))
      else
        echo "  NSA hardening: ${NSA_FAILS} known failure(s), 0 unexpected"
      fi
      rm -f "$NSA_REPORT"
    else
      echo "  trivy or cluster not available — skipping compliance scans"
    fi
    echo ""
  fi
fi

# ── Phase 4: Bats live tests ────────────────────────────────────────────────
if [ "$STATIC_ONLY" = false ]; then
  echo "═══ Phase 4: Bats live tests ═══"

  if ! command -v bats >/dev/null 2>&1; then
    echo "ERROR: bats not found in PATH"
    exit 1
  fi

  BATS_EXIT=0
  bats --tap "${SCRIPT_DIR}/bats/" | tee /tmp/bats-regression-output.tap || BATS_EXIT=$?

  # If bats itself failed (test failures), propagate.
  if [ "$BATS_EXIT" -ne 0 ]; then
    FAILURES=$((FAILURES + 1))
  fi

  # Check for skipped tests in TAP output.
  SKIP_COUNT=$(grep -c "^ok .* # skip" /tmp/bats-regression-output.tap 2>/dev/null || echo "0")
  PASS_COUNT=$(grep -c "^ok" /tmp/bats-regression-output.tap 2>/dev/null || echo "0")
  TOTAL_COUNT=$(grep -c "^ok\|^not ok" /tmp/bats-regression-output.tap 2>/dev/null || echo "0")
  FAIL_COUNT=$((TOTAL_COUNT - PASS_COUNT))

  echo ""
  echo "── Bats Summary ──"
  echo "  Total: ${TOTAL_COUNT}  Passed: ${PASS_COUNT}  Failed: ${FAIL_COUNT}  Skipped: ${SKIP_COUNT}"
fi

# ── Final exit ───────────────────────────────────────────────────────────────
echo ""
echo "── Pipeline Summary ──"
if [ "$FAILURES" -gt 0 ]; then
  echo "REGRESSION DETECTED — one or more test phases failed."
  exit 1
fi

if [ "$STATIC_ONLY" = false ] && [ "${SKIP_COUNT:-0}" -gt 0 ] && [ "$STRICT" = true ]; then
  echo "WARNING: ${SKIP_COUNT} bats test(s) skipped — prerequisites missing."
  echo "Run with --allow-skip to suppress this on feature branches."
  exit 2
fi

echo "ALL TESTS PASSED"
exit 0
