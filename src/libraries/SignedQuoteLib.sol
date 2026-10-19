/**
 * Copyright 2026 Circle Internet Group, Inc.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
pragma solidity ^0.8.20;

import {IFeeManager} from "../interfaces/IFeeManager.sol";

/// @title SignedQuoteLib
/// @notice Decodes version-prefixed quote blobs `[uint8 version][abi.encode(Quote)]` in-process.
/// @dev Canonical wire decode used by `FeeManager.decodeQuote` (external API) and by any contract that inlines this
///      library (e.g. `TokenMessengerWithFees`, `FeeManager.collectFeesWithQuote` with raw bytes).
///
///      **Success path:** Version byte must equal `QUOTE_WIRE_FORMAT_VERSION`. The ABI tail must be at least
///      `MIN_ABI_ENCODED_QUOTE_TAIL_BYTES` (minimal encoding for empty `items` and a 65-byte ECDSA signature). After
///      `abi.decode`, `signature.length` must be `ECDSA_SECP256K1_SIGNATURE_BYTES` (OpenZeppelin `ECDSA.recover`).
///
///      **Custom errors (predictable selectors):**
///      - `SignedQuoteDecodeFailed` — empty input, tail too short, or signature length not 65.
///      - `UnsupportedQuoteVersion` — first byte is not the supported version.
///
///      **Panic:** If cheap checks pass but the tail is still not valid ABI for `IFeeManager.Quote`, `abi.decode`
///      reverts with Solidity **Panic(0x21)** (ABI decode failure). Callers cannot catch this as a custom error
///      without an external call; treat any revert while decoding as failure.
library SignedQuoteLib {
    /// @dev Version byte prefix for `[uint8 version][abi.encode(IFeeManager.Quote)]`.
    uint8 public constant QUOTE_WIRE_FORMAT_VERSION = 1;

    /// @dev secp256k1 ECDSA signature length used by OpenZeppelin `ECDSA.recover` (r, s, v).
    uint256 internal constant ECDSA_SECP256K1_SIGNATURE_BYTES = 65;

    /// @dev Minimum `abi.encode(IFeeManager.Quote)` tail length when `items` is empty and `signature` holds exactly
    ///      `ECDSA_SECP256K1_SIGNATURE_BYTES` (352). Shorter tails cannot encode a struct that `FeeManager` could
    ///      verify with `ECDSA.recover`; reject them before `abi.decode`.
    uint256 internal constant MIN_ABI_ENCODED_QUOTE_TAIL_BYTES = 352;

    /// @notice Decodes a signed quote blob into `IFeeManager.Quote` memory.
    /// @dev Reverts `SignedQuoteDecodeFailed` when the payload is empty, the ABI tail is shorter than the minimum for
    ///      an empty-items quote with a 65-byte signature, or the decoded `signature` length is not 65. Does not
    ///      catch all malformed tails; those may still fail inside `abi.decode` with **Panic(0x21)** — see above.
    function decodeQuote(bytes calldata signedQuote) internal pure returns (IFeeManager.Quote memory quote) {
        if (signedQuote.length == 0) {
            revert IFeeManager.SignedQuoteDecodeFailed();
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        // slither-disable-next-line unsafe-cast
        // One calldata byte; value is always 0–255 (no truncation).
        uint8 version = uint8(signedQuote[0]);
        if (version != QUOTE_WIRE_FORMAT_VERSION) {
            revert IFeeManager.UnsupportedQuoteVersion(version);
        }
        if (signedQuote.length - 1 < MIN_ABI_ENCODED_QUOTE_TAIL_BYTES) {
            revert IFeeManager.SignedQuoteDecodeFailed();
        }
        quote = abi.decode(signedQuote[1:], (IFeeManager.Quote));
        if (quote.signature.length != ECDSA_SECP256K1_SIGNATURE_BYTES) {
            revert IFeeManager.SignedQuoteDecodeFailed();
        }
    }

    /// @notice Decodes a wire-format `QuoteClaim` into a `DecodedQuoteClaim`: parses the signed quote bytes and pairs
    ///         the resulting `Quote` body with `claim.refundAddress`.
    /// @dev Wire decode has the same revert surface as `decodeQuote`. `refundAddress` is copied through verbatim — this
    ///      library applies no defaulting policy.
    function decodeClaim(IFeeManager.QuoteClaim calldata claim)
        internal
        pure
        returns (IFeeManager.DecodedQuoteClaim memory)
    {
        return IFeeManager.DecodedQuoteClaim({
            decodedQuote: decodeQuote(claim.signedQuote), refundAddress: claim.refundAddress
        });
    }
}
