#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Structural check: every infra/secrets/*.enc.yaml is encrypted to EXACTLY the
# recipient set declared in .sops.yaml, and every secret value is ENC[-prefixed.
#
# Derives the expected recipients from .sops.yaml (no hard-coded key), so it
# keeps working across key rotations. Requires no cluster and no private key.
#
# Exit codes:
#   0 — consistent (or nothing to check: no .enc.yaml files, or placeholder
#       recipients still in .sops.yaml before the cluster bring-up)
#   1 — a mismatch: wrong recipient set, a plaintext value, or a missing sops block
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOPS_CONFIG="${ROOT_DIR}/.sops.yaml"
SECRETS_DIR="${ROOT_DIR}/infra/secrets"

fail=0

if [ ! -f "$SOPS_CONFIG" ]; then
  echo "  ERROR: .sops.yaml not found at ${SOPS_CONFIG}"
  exit 1
fi

# Expected recipients: every age1... token in .sops.yaml, sorted+unique.
expected="$(grep -oE 'age1[0-9a-z]+' "$SOPS_CONFIG" | sort -u || true)"

if [ -z "$expected" ]; then
  echo "  ERROR: no age recipients found in .sops.yaml"
  exit 1
fi

# Placeholder recipients mean the real keys have not been generated yet
# (pre-bring-up). Nothing to enforce; do not fail CI.
if grep -qE 'REPLACE_ME' "$SOPS_CONFIG"; then
  echo "  NOTE: .sops.yaml holds placeholder recipients — skipping enforcement"
  echo "        (real recipients are written during SECRETS-BOOTSTRAP §2–§4)"
  exit 0
fi

shopt -s nullglob
enc_files=("${SECRETS_DIR}"/*.enc.yaml)
shopt -u nullglob

if [ "${#enc_files[@]}" -eq 0 ]; then
  echo "  NOTE: no infra/secrets/*.enc.yaml to check (clean slate)"
  exit 0
fi

for f in "${enc_files[@]}"; do
  base="$(basename "$f")"

  # 1) Must have a sops metadata block.
  if ! grep -qE '^sops:' "$f"; then
    echo "  FAIL: ${base} has no sops: block (is it encrypted?)"
    fail=1
    continue
  fi

  # 2) Recipients in this file must equal the expected set exactly.
  actual="$(awk '/^sops:/{s=1} s' "$f" | grep -oE 'age1[0-9a-z]+' | sort -u || true)"
  if [ "$actual" != "$expected" ]; then
    echo "  FAIL: ${base} recipient set does not match .sops.yaml"
    echo "        expected: $(echo "$expected" | tr '\n' ' ')"
    echo "        actual:   $(echo "$actual"   | tr '\n' ' ')"
    fail=1
  fi

  # 3) Every value in the data/stringData block must be ENC[-prefixed.
  #    Inspect the block between (string)data: and sops:.
  leaked="$(awk '
    /^(stringData|data):[[:space:]]*$/ {inblk=1; next}
    /^sops:/ {inblk=0}
    inblk && /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*/ {
      # line has a value after the colon?
      if ($0 ~ /:[[:space:]]*[^[:space:]]/ && $0 !~ /ENC\[/) print
    }
  ' "$f" || true)"
  if [ -n "$leaked" ]; then
    echo "  FAIL: ${base} has non-encrypted value(s):"
    echo "$leaked" | sed 's/^/        /'
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "  OK: ${#enc_files[@]} encrypted file(s) match .sops.yaml, all values ENC[-prefixed"
fi
exit "$fail"
