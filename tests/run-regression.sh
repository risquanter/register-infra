#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Wrapper: run the full regression test pipeline with strict skip semantics.
#
# Phases:
#   1. Static analysis  — conftest policies against YAML manifests
#   2. OPA unit tests   — opa test against allow.rego + test suite
#   3. Bats live tests  — all .bats files against a live cluster
#
# Exit codes (ADR-INFRA-005):
#   0 — all tests passed (no skips, or --allow-skip set)
#   1 — one or more tests failed
#   2 — tests were skipped (prerequisites missing) and --strict is set
#
# Usage:
#   ./tests/run-regression.sh                    # default: --strict
#   ./tests/run-regression.sh --allow-skip       # skips are OK (feature branches)
#   ./tests/run-regression.sh --bats-only        # skip static + OPA phases
#   ./tests/run-regression.sh --static-only      # skip bats phase
#   INGRESS=https://... ./tests/run-regression.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

STRICT=true
BATS_ONLY=false
STATIC_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --allow-skip)  STRICT=false ;;
    --bats-only)   BATS_ONLY=true ;;
    --static-only) STATIC_ONLY=true ;;
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

# ── Phase 3: Bats live tests ────────────────────────────────────────────────
if [ "$STATIC_ONLY" = false ]; then
  echo "═══ Phase 3: Bats live tests ═══"

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
  echo "── Summary ──"
  echo "  Total: ${TOTAL_COUNT}  Passed: ${PASS_COUNT}  Failed: ${FAIL_COUNT}  Skipped: ${SKIP_COUNT}"
fi

# ── Final exit ───────────────────────────────────────────────────────────────
if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "REGRESSION DETECTED — one or more test phases failed."
  exit 1
fi

if [ "$STATIC_ONLY" = false ]; then
  if [ "$SKIP_COUNT" -gt 0 ] && [ "$STRICT" = true ]; then
    echo ""
    echo "WARNING: ${SKIP_COUNT} test(s) skipped — prerequisites missing."
    echo "Run with --allow-skip to suppress this on feature branches."
    exit 2
  fi
fi

echo ""
echo "ALL TESTS PASSED"
exit 0
