#!/usr/bin/env bash
# Deposit-for-burn via cast send using a *pre-signed* quote supplied by the caller.
#
# Companion to cast-deposit-for-burn.sh: that script signs its own quote with
# QUOTE_SIGNER and is meant for local round-trip testing; this one assumes the
# caller already has a signed quote (e.g. from a backend signer) and just wants
# to relay it on-chain. The native fee value (msg.value) is derived from the
# wrapper's getFee(bytes) view, so the caller does not need to know the exact
# amount in advance.
#
# Same Arc Testnet caveat as the generated-quote script: USDC precompiles
# (0x18…00, 0x18…01) break Forge's local revm simulation, so we use `cast send`
# directly.
#
# Usage:
#   set -o allexport && source configs/.env.dev && set +o allexport
#   export CALLER_PRIVATE_KEY=0x<hex>
#   export BURN_TOKEN_ADDRESS=$USDC_ADDRESS
#   export SIGNED_QUOTE=0x01...   # version-prefixed, signed by a trusted FeeManager signer
#   bash script/test/cast-deposit-for-burn-with-quote.sh
#
# Optional env vars:
#   BURN_AMOUNT          token units to burn (default: 500000)
#   DESTINATION_DOMAIN   CCTP destination domain (default: 0 — Ethereum)
#   MINT_RECIPIENT       bytes32 mint recipient (default: caller, left-padded)
#   DESTINATION_CALLER   bytes32 authorized destination caller (default: zero)
#   REFUND_ADDRESS       refund attribution address (default: zero — bypasses USDC blocklist screen)
#   HOOK_DATA            0x-prefixed hookData; non-empty switches to depositForBurnWithHookAndFees
#   NATIVE_FEE           wei to attach as msg.value (default: queried via wrapper.getFee).
#                        getFee(bytes) is always called regardless, and the script aborts when
#                        the quoted feeToken is not address(0); the override only changes the
#                        value attached to the deposit call (e.g. for IncorrectNativePayment
#                        smoke tests). A mismatch against the quoted fee is logged.

set -euo pipefail

: "${BLOCKCHAIN_RPC_URL:?Set BLOCKCHAIN_RPC_URL}"
: "${CALLER_PRIVATE_KEY:?Set CALLER_PRIVATE_KEY (0x-prefixed hex)}"
: "${TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS:?Set TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS}"
: "${BURN_TOKEN_ADDRESS:?Set BURN_TOKEN_ADDRESS}"
: "${SIGNED_QUOTE:?Set SIGNED_QUOTE (0x-prefixed version-prefixed bytes)}"

BURN_AMOUNT="${BURN_AMOUNT:-500000}"
DESTINATION_DOMAIN="${DESTINATION_DOMAIN:-0}"
HOOK_DATA="${HOOK_DATA:-0x}"
ZERO_BYTES32=0x0000000000000000000000000000000000000000000000000000000000000000
ZERO_ADDRESS=0x0000000000000000000000000000000000000000
DESTINATION_CALLER="${DESTINATION_CALLER:-$ZERO_BYTES32}"

if [[ "$SIGNED_QUOTE" != 0x* ]]; then
  echo "ERROR: SIGNED_QUOTE must be 0x-prefixed hex (got: ${SIGNED_QUOTE:0:16}…)" >&2
  exit 1
fi
if [[ "$HOOK_DATA" != 0x* ]]; then
  echo "ERROR: HOOK_DATA must be 0x-prefixed hex (got: ${HOOK_DATA:0:16}…)" >&2
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
echo "Burn token:         $BURN_TOKEN_ADDRESS"
echo "Burn amount:        $BURN_AMOUNT"
echo "Destination domain: $DESTINATION_DOMAIN"
echo "Mint recipient:     $MINT_RECIPIENT"
echo "Destination caller: $DESTINATION_CALLER"
echo "Refund address:     $REFUND_ADDRESS"
echo "Hook data length:   $(( (${#HOOK_DATA} - 2) / 2 )) bytes"
echo "Signed quote:       ${SIGNED_QUOTE:0:42}…${SIGNED_QUOTE: -8} ($(( (${#SIGNED_QUOTE} - 2) / 2 )) bytes)"
echo ""

# Step 1 — Resolve the native fee value via the wrapper's getFee(bytes) view.
# Always query getFee so we can enforce the native-only invariant
# (feeToken == address(0)) even when the caller pre-set NATIVE_FEE. Otherwise
# an ERC-20-fee quote could slip through and waste gas on a doomed
# approve + deposit. The NATIVE_FEE override is preserved for cases like
# deliberately triggering IncorrectNativePayment in smoke tests.
echo "=== Step 1/3: Querying native fee ==="
# `cast call` with multi-return prints one value per line. The integer line
# also carries a "[1.5e13]"-style scientific suffix that awk strips by
# selecting only the first field.
if ! GET_FEE_OUTPUT=$(cast call \
    "$TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS" \
    "getFee(bytes)(uint256,address)" \
    "$SIGNED_QUOTE" \
    --rpc-url "$BLOCKCHAIN_RPC_URL" 2>&1); then
  echo "ERROR: getFee query failed:" >&2
  echo "$GET_FEE_OUTPUT" >&2
  exit 1
fi
QUOTED_FEE=$(echo "$GET_FEE_OUTPUT" | sed -n '1p' | awk '{print $1}')
FEE_TOKEN=$(echo "$GET_FEE_OUTPUT" | sed -n '2p' | awk '{print $1}')
if [[ -z "$QUOTED_FEE" || -z "$FEE_TOKEN" ]]; then
  echo "ERROR: failed to parse getFee output:" >&2
  echo "$GET_FEE_OUTPUT" >&2
  exit 1
fi
# Lowercase via tr so this works on macOS's stock bash 3.2 (no ${var,,}).
FEE_TOKEN_LC=$(printf '%s' "$FEE_TOKEN" | tr '[:upper:]' '[:lower:]')
ZERO_ADDRESS_LC=$(printf '%s' "$ZERO_ADDRESS" | tr '[:upper:]' '[:lower:]')
if [[ "$FEE_TOKEN_LC" != "$ZERO_ADDRESS_LC" ]]; then
  echo "ERROR: quote feeToken is $FEE_TOKEN; this script only supports native fees." >&2
  echo "       Either supply a native-fee quote or use a separate ERC-20 approve flow." >&2
  exit 1
fi

if [[ -n "${NATIVE_FEE:-}" ]]; then
  if [[ "$NATIVE_FEE" != "$QUOTED_FEE" ]]; then
    echo "Note: caller-provided NATIVE_FEE=$NATIVE_FEE wei differs from quoted $QUOTED_FEE wei" >&2
    echo "      (the wrapper requires an exact match and will revert with IncorrectNativePayment)." >&2
  fi
  echo "Using caller-provided NATIVE_FEE=$NATIVE_FEE wei (quoted fee: $QUOTED_FEE wei, feeToken=$FEE_TOKEN)"
else
  NATIVE_FEE="$QUOTED_FEE"
  echo "Resolved native fee: $NATIVE_FEE wei (feeToken=$FEE_TOKEN)"
fi
echo ""

# Step 2 — Approve the burn token for the wrapper.
echo "=== Step 2/3: Approving burn token ==="
cast send "$BURN_TOKEN_ADDRESS" \
  "approve(address,uint256)" \
  "$TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS" "$BURN_AMOUNT" \
  --private-key "$CALLER_PRIVATE_KEY" \
  --rpc-url "$BLOCKCHAIN_RPC_URL"
echo ""

# Step 3 — Relay the burn. Choose between depositForBurnWithFees and
# depositForBurnWithHookAndFees based on whether HOOK_DATA is non-empty.
# QuoteClaim is a (bytes signedQuote, address refundAddress) tuple — passed
# to cast as "($SIGNED_QUOTE,$REFUND_ADDRESS)" with sig type `(bytes,address)`.
if [[ "$HOOK_DATA" == "0x" || -z "${HOOK_DATA:2}" ]]; then
  echo "=== Step 3/3: depositForBurnWithFees ==="
  cast send "$TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS" \
    "depositForBurnWithFees(uint256,uint32,bytes32,address,bytes32,(bytes,address))" \
    "$BURN_AMOUNT" \
    "$DESTINATION_DOMAIN" \
    "$MINT_RECIPIENT" \
    "$BURN_TOKEN_ADDRESS" \
    "$DESTINATION_CALLER" \
    "($SIGNED_QUOTE,$REFUND_ADDRESS)" \
    --value "$NATIVE_FEE" \
    --private-key "$CALLER_PRIVATE_KEY" \
    --rpc-url "$BLOCKCHAIN_RPC_URL"
else
  echo "=== Step 3/3: depositForBurnWithHookAndFees ==="
  cast send "$TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS" \
    "depositForBurnWithHookAndFees(uint256,uint32,bytes32,address,bytes32,bytes,(bytes,address))" \
    "$BURN_AMOUNT" \
    "$DESTINATION_DOMAIN" \
    "$MINT_RECIPIENT" \
    "$BURN_TOKEN_ADDRESS" \
    "$DESTINATION_CALLER" \
    "$HOOK_DATA" \
    "($SIGNED_QUOTE,$REFUND_ADDRESS)" \
    --value "$NATIVE_FEE" \
    --private-key "$CALLER_PRIVATE_KEY" \
    --rpc-url "$BLOCKCHAIN_RPC_URL"
fi

echo ""
echo "=== Done ==="
