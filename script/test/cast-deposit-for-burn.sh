#!/usr/bin/env bash
# Deposit-for-burn via cast send, bypassing Forge's local EVM simulation.
#
# Arc Testnet (chain id 5042002) delegates USDC balance transfers and blocklist
# checks to native precompiles (0x18…00, 0x18…01) that have no standard EVM
# bytecode.  Forge's revm fetches empty code at those addresses and fails with
# StackUnderflow when it tries to simulate the transaction locally.  This script
# avoids the issue by submitting transactions directly to the RPC node via
# `cast send`.
#
# Usage:
#   set -o allexport && source configs/.env.dev && set +o allexport
#   export CALLER_PRIVATE_KEY=0x<hex>
#   export QUOTE_SIGNER=<uint256>
#   export BURN_TOKEN_ADDRESS=$USDC_ADDRESS
#   bash script/test/cast-deposit-for-burn.sh
#
# Fee amounts are hardcoded to match GenerateSignedTestQuote.s.sol:
#   FORWARD = 0.00001 ether, PRE_FINALITY = 0.000005 ether, burn amount = 500 000.
# To change them, update both the Solidity script constants and the
# FORWARD_FEE_WEI / PRE_FINALITY_FEE_WEI constants below.
#
# QUOTE_TYPES selects which fee items the generated quote contains and which
# fees are included in the attached msg.value. Comma-separated subset of
# {FORWARD, PRE_FINALITY}. Default: "FORWARD,PRE_FINALITY".

set -euo pipefail

: "${BLOCKCHAIN_RPC_URL:?Set BLOCKCHAIN_RPC_URL}"
: "${CALLER_PRIVATE_KEY:?Set CALLER_PRIVATE_KEY (0x-prefixed hex)}"
: "${QUOTE_SIGNER:?Set QUOTE_SIGNER (uint256, must be a trusted signer on FeeManager)}"
: "${TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS:?Set TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS}"
: "${BURN_TOKEN_ADDRESS:?Set BURN_TOKEN_ADDRESS}"
: "${FEE_MANAGER_PROXY_ADDRESS:?Set FEE_MANAGER_PROXY_ADDRESS}"

BURN_AMOUNT=500000
FORWARD_FEE_WEI=10000000000000   # 0.00001 ether
PRE_FINALITY_FEE_WEI=5000000000000  # 0.000005 ether
DESTINATION_DOMAIN="${DESTINATION_DOMAIN:-0}"
QUOTE_TYPES="${QUOTE_TYPES:-FORWARD,PRE_FINALITY}"
ZERO_BYTES32=0x0000000000000000000000000000000000000000000000000000000000000000
ZERO_ADDRESS=0x0000000000000000000000000000000000000000

# Parse QUOTE_TYPES → NATIVE_FEE. Keep this in sync with QuoteScriptUtils
# `_readSelectedQuoteTypes` so the bash side rejects the same set of bad
# inputs the Solidity side would. In particular, duplicates are rejected on
# both sides: this loop sums fees per entry, while the Solidity item builder
# collapses duplicates into a single `QuoteItem`, so `QUOTE_TYPES=FORWARD,FORWARD`
# would otherwise sign one FORWARD item but attach 2x the forward fee and
# revert on-chain with `IncorrectNativePayment`. Empty tokens (e.g. a trailing
# comma like `FORWARD,`) are also rejected to match the Solidity side.
INCLUDE_FORWARD=false
INCLUDE_PRE_FINALITY=false
NATIVE_FEE=0
# `read -ra` silently strips trailing empty fields, so `FORWARD,` would otherwise
# pass on the bash side while Solidity's `vm.envOr` splits it into ["FORWARD", ""]
# and reverts with `UnknownQuoteType("")`. Reject leading/trailing commas up front
# to keep both sides aligned.
if [[ "$QUOTE_TYPES" == ,* || "$QUOTE_TYPES" == *, ]]; then
  echo "ERROR: QUOTE_TYPES has a leading or trailing comma (got '$QUOTE_TYPES')" >&2
  exit 1
fi
IFS=',' read -ra _QUOTE_TYPE_TOKENS <<< "$QUOTE_TYPES"
for _token in "${_QUOTE_TYPE_TOKENS[@]}"; do
  # Trim surrounding whitespace so "FORWARD, PRE_FINALITY" works too.
  _token="${_token#"${_token%%[![:space:]]*}"}"
  _token="${_token%"${_token##*[![:space:]]}"}"
  case "$_token" in
    FORWARD)
      if $INCLUDE_FORWARD; then
        echo "ERROR: QUOTE_TYPES lists FORWARD more than once (got '$QUOTE_TYPES'); duplicates are rejected to keep NATIVE_FEE in sync with the Solidity quote" >&2
        exit 1
      fi
      INCLUDE_FORWARD=true
      NATIVE_FEE=$((NATIVE_FEE + FORWARD_FEE_WEI))
      ;;
    PRE_FINALITY)
      if $INCLUDE_PRE_FINALITY; then
        echo "ERROR: QUOTE_TYPES lists PRE_FINALITY more than once (got '$QUOTE_TYPES'); duplicates are rejected to keep NATIVE_FEE in sync with the Solidity quote" >&2
        exit 1
      fi
      INCLUDE_PRE_FINALITY=true
      NATIVE_FEE=$((NATIVE_FEE + PRE_FINALITY_FEE_WEI))
      ;;
    *)
      echo "ERROR: Unknown QUOTE_TYPES entry '$_token' (expected FORWARD or PRE_FINALITY)" >&2
      exit 1
      ;;
  esac
done
if ! $INCLUDE_FORWARD && ! $INCLUDE_PRE_FINALITY; then
  echo "ERROR: QUOTE_TYPES must include at least one of FORWARD, PRE_FINALITY (got '$QUOTE_TYPES')" >&2
  exit 1
fi

CALLER_ADDRESS=$(cast wallet address --private-key "$CALLER_PRIVATE_KEY")
MINT_RECIPIENT="${MINT_RECIPIENT:-0x000000000000000000000000${CALLER_ADDRESS#0x}}"
# QuoteClaim.refundAddress: address(0) means "no refund target" and bypasses
# the USDC blocklist screen (see FeeManager._screenRefundAddress). Override
# via REFUND_ADDRESS env var to test the non-zero path.
REFUND_ADDRESS="${REFUND_ADDRESS:-$ZERO_ADDRESS}"

# Mask everything after the hostname (path, query, fragment) and any user-info
# component (`user:pass@`) so secrets in either spot don't leak into shared
# terminals or CI logs.
redact_url_after_host() {
  local url="$1"
  local rest="${url#*://}"
  local host="${rest%%/*}"
  host="${host%%\?*}"
  host="${host%%#*}"
  host="${host##*@}"
  printf '%s\n' "${url%%"$rest"}${host}/<REDACTED>"
}

echo "--- Configuration ---"
echo "RPC:                $(redact_url_after_host "$BLOCKCHAIN_RPC_URL")"
echo "Caller:             $CALLER_ADDRESS"
echo "Wrapper (TMWF):     $TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS"
echo "FeeManager:         $FEE_MANAGER_PROXY_ADDRESS"
echo "Burn token:         $BURN_TOKEN_ADDRESS"
echo "Burn amount:        $BURN_AMOUNT"
echo "Quote types:        $QUOTE_TYPES (forward=$INCLUDE_FORWARD, pre_finality=$INCLUDE_PRE_FINALITY)"
echo "Native fee (wei):   $NATIVE_FEE"
echo "Destination domain: $DESTINATION_DOMAIN"
echo "Mint recipient:     $MINT_RECIPIENT"
echo "Refund address:     $REFUND_ADDRESS"
echo ""

# Step 1 — Generate a signed quote via the Forge test script.
# This is a view-only call (no --broadcast); Forge does not simulate on-chain
# state, so native precompiles are not hit.
echo "=== Step 1/3: Generating signed quote ==="

# The `if !` wrapper is required because forge's stderr is captured via 2>&1;
# without it, `set -e` aborts the script on a failed forge run before the
# captured output can be printed (silent exit). A frequent cause of failure
# here is stale build artifacts after pulling new contract changes — try
# `forge clean && forge build` if forge prints "No contract bytecode".
if ! QUOTE_OUTPUT=$(DESTINATION_DOMAIN="$DESTINATION_DOMAIN" QUOTE_BASE_TIMESTAMP=$(date +%s) QUOTE_TYPES="$QUOTE_TYPES" forge script \
    script/test/GenerateSignedTestQuote.s.sol:GenerateSignedTestQuote \
    --rpc-url "$BLOCKCHAIN_RPC_URL" 2>&1); then
  echo "ERROR: forge script failed:"
  echo "$QUOTE_OUTPUT"
  exit 1
fi

# console.logBytes prints the hex on a separate line after "signedQuote:"
SIGNED_QUOTE=$(echo "$QUOTE_OUTPUT" | grep -A1 'signedQuote:' | tail -1 | tr -d ' ')
if [[ -z "$SIGNED_QUOTE" || "$SIGNED_QUOTE" != 0x* ]]; then
  echo "ERROR: failed to extract signedQuote from forge output:"
  echo "$QUOTE_OUTPUT"
  exit 1
fi
echo "signedQuote: ${SIGNED_QUOTE:0:42}…${SIGNED_QUOTE: -8}"
echo ""

# Step 2 — Approve the burn token for the wrapper.
echo "=== Step 2/3: Approving burn token ==="
cast send "$BURN_TOKEN_ADDRESS" \
  "approve(address,uint256)" \
  "$TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS" "$BURN_AMOUNT" \
  --private-key "$CALLER_PRIVATE_KEY" \
  --rpc-url "$BLOCKCHAIN_RPC_URL"
echo ""

# Step 3 — Call depositForBurnWithFees on TokenMessengerWithFees.
# The last arg is `IFeeManager.QuoteClaim`, a tuple of
# (bytes signedQuote, address refundAddress); pass it to cast as
# "($SIGNED_QUOTE,$REFUND_ADDRESS)" with sig type `(bytes,address)`.
echo "=== Step 3/3: depositForBurnWithFees ==="
cast send "$TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS" \
  "depositForBurnWithFees(uint256,uint32,bytes32,address,bytes32,(bytes,address))" \
  "$BURN_AMOUNT" \
  "$DESTINATION_DOMAIN" \
  "$MINT_RECIPIENT" \
  "$BURN_TOKEN_ADDRESS" \
  "$ZERO_BYTES32" \
  "($SIGNED_QUOTE,$REFUND_ADDRESS)" \
  --value "$NATIVE_FEE" \
  --private-key "$CALLER_PRIVATE_KEY" \
  --rpc-url "$BLOCKCHAIN_RPC_URL"

echo ""
echo "=== Done ==="
