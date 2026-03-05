#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Wrapper: run bats regression suite with strict skip semantics.
#
# Exit codes (ADR-INFRA-005):
#   0 — all tests passed (no skips, or --allow-skip set)
#   1 — one or more tests failed
#   2 — tests were skipped (prerequisites missing) and --strict is set
#
# Usage:
#   ./tests/run-regression.sh                    # default: --strict
#   ./tests/run-regression.sh --allow-skip       # skips are OK (feature branches)
#   INGRESS=https://... ./tests/run-regression.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STRICT=true
for arg in "$@"; do
  case "$arg" in
    --allow-skip) STRICT=false ;;
  esac
done

# Run bats and capture output + exit code.
BATS_EXIT=0
bats --tap "${SCRIPT_DIR}/bats/" | tee /tmp/bats-regression-output.tap || BATS_EXIT=$?

# If bats itself failed (test failures), propagate immediately.
if [ "$BATS_EXIT" -ne 0 ]; then
  echo ""
  echo "REGRESSION DETECTED — one or more tests failed."
  exit 1
fi

# Check for skipped tests in TAP output.
SKIP_COUNT=$(grep -c "^ok .* # skip" /tmp/bats-regression-output.tap 2>/dev/null || echo "0")

if [ "$SKIP_COUNT" -gt 0 ] && [ "$STRICT" = true ]; then
  echo ""
  echo "WARNING: ${SKIP_COUNT} test(s) skipped — prerequisites missing."
  echo "Run with --allow-skip to suppress this on feature branches."
  exit 2
fi

exit 0
