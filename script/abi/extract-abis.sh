#!/usr/bin/env bash
# Export ABIs for the contracts users integrate with into abi/.
# The implementation ABIs are also the proxy ABIs (ERC1967 delegates everything).
#
# Usage: bash script/abi/extract-abis.sh   (or: yarn abi)

set -euo pipefail

mkdir -p abi
for c in FeeManager TokenMessengerWithFees Create3Factory; do
    forge inspect "$c" abi --json > "abi/$c.abi.json"
    echo "abi/$c.abi.json"
done
