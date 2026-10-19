#!/usr/bin/env bash
# Defense-in-depth lint: assert foundry.toml settings that affect produced
# bytecode are exactly what the published predicted-address set assumes.
#
# This repo's CREATE3 deployment tree is rooted at Create3Factory, which is
# itself deployed via CREATE2. Create3Factory's CREATE2 address depends on its
# own creation bytecode, and every downstream CREATE3 address depends on
# Create3Factory's address. So changing any of these foundry.toml settings
# shifts Create3Factory's address and transitively shifts every CREATE3-
# derived address downstream, silently invalidating any predicted addresses
# already shared with downstream consumers.
#
# The Create3FactoryBytecodePin.t.sol test in test/ is the authoritative guard
# (it pins the actual Create3Factory bytecode hash). This lint runs earlier in
# CI and gives a clearer error message when a single foundry.toml line is
# changed.
#
# If the change is intentional, update the EXPECTED_* values in the
# Create3FactoryBytecodePin test AND the PINS array below AND coordinate an
# address republish with downstream consumers BEFORE merging.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FOUNDRY_TOML="$HERE/../../foundry.toml"

if [ ! -f "$FOUNDRY_TOML" ]; then
  echo "error: foundry.toml not found at $FOUNDRY_TOML" >&2
  exit 1
fi

# Pinned key=value pairs that, if changed, change Create3Factory's creation
# bytecode and therefore shift its CREATE2 address along with every
# CREATE3-derived address that uses it.
declare -a PINS=(
  'solc_version = "0.8.24"'
  'auto_detect_solc = false'
  "evm_version = 'cancun'"
  'optimizer = true'
  'optimizer_runs = 200'
  'via_ir = true'
)

fail=0
for pin in "${PINS[@]}"; do
  if ! grep -qxF "$pin" "$FOUNDRY_TOML"; then
    echo "  MISSING: $pin" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  cat >&2 <<EOF

ERROR: foundry.toml is missing one or more pinned settings (listed above).
These settings determine Create3Factory's creation bytecode, which determines
its CREATE2 deployment address. Every CREATE3-derived address downstream of
the factory is then a function of that address, so any change here shifts the
entire address tree and invalidates every predicted address downstream
consumers have already received.

If the change is intentional:
  1. Update the EXPECTED_CREATION_CODE_HASH in
     test/Create3FactoryBytecodePin.t.sol with the new keccak256 of the
     rebuilt creation bytecode.
  2. Update the PINS array in this script (script/lint/check-foundry-settings.sh).
  3. Coordinate an address republish with all downstream consumers BEFORE merging.
EOF
  exit 1
fi

echo "OK: all ${#PINS[@]} bytecode-affecting foundry.toml settings present and unchanged."
