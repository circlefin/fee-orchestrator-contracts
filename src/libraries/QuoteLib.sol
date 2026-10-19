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
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title QuoteLib
/// @notice Helpers for `IFeeManager.Quote`: line-item lookup, fee totals, and packed `expiry` validation.
library QuoteLib {
    /// @param expiryMode High byte of encoded expiry: `0` = timestamp deadline, `1` = block-number deadline.
    /// @param deadline Lower 248 bits of encoded expiry (Unix time or block height, per mode).
    /// @param current `block.timestamp` in timestamp mode, `block.number` in block-number mode.
    error QuoteExpired(uint8 expiryMode, uint256 deadline, uint256 current);
    error UnsupportedExpiryMode(uint8 mode);
    error NonZeroNonce(uint256 nonce);

    /// @dev High byte (bits 255–248) of `encodedExpiry`.
    uint8 internal constant MODE_TIMESTAMP = 0;
    uint8 internal constant MODE_BLOCK_NUMBER = 1;

    /// @notice `keccak256(abi.encode(quoteArgs))` — same encoding as `QuoteItem.quoteArgsHash` on signed quotes.
    function hashQuoteArgs(string[] calldata quoteArgs) internal pure returns (bytes32) {
        return keccak256(abi.encode(quoteArgs));
    }

    /// @notice Whether this line item’s `quoteArgsHash` matches the given request arguments.
    /// @dev Use as `qItem.matchesRequest(quoteArgs)` via `using QuoteLib for IFeeManager.QuoteItem`.
    function matchesRequest(IFeeManager.QuoteItem memory item, string[] calldata quoteArgs)
        internal
        pure
        returns (bool)
    {
        return item.quoteArgsHash == hashQuoteArgs(quoteArgs);
    }

    /// @notice First line item whose `quoteType` matches (hashed string equality).
    /// @dev `matched` means a line with that type exists. Use `item.matchesRequest(request.quoteArgs)` to verify args,
    ///      or `quote.findItemForRequest(request)` to do the type lookup and args/required check in one step.
    ///      When `matched` is false, `item` is zeroed and `itemIndex` is 0.
    /// @dev Use as `quote.findItemByType(quoteType)` via `using QuoteLib for IFeeManager.Quote`.
    /// @param quoteType `string memory` so callers may pass calldata strings or `QuoteTypes` constants.
    function findItemByType(IFeeManager.Quote memory quote, string memory quoteType)
        internal
        pure
        returns (IFeeManager.QuoteItem memory item, uint256 itemIndex, bool matched)
    {
        (uint256 idx, bool found) = _itemIndexOf(quote, quoteType);
        if (found) {
            return (quote.items[idx], idx, true);
        }
        return (item, 0, false);
    }

    /// @notice Whether any line item has the given `quoteType` (hashed string equality).
    /// @dev Use as `quote.hasItemType(quoteType)` via `using QuoteLib for IFeeManager.Quote`.
    function hasItemType(IFeeManager.Quote memory quote, string memory quoteType) internal pure returns (bool) {
        (uint256 itemIndex, bool matched) = _itemIndexOf(quote, quoteType);
        // Uses `itemIndex` so analyzers do not flag an unused tuple return from `_itemIndexOf`.
        assert(!matched || itemIndex < quote.items.length);
        return matched;
    }

    /// @notice Require quote items to fit the duplicate-detection bitmap.
    function requireSupportedItemCount(IFeeManager.Quote memory quote) internal pure {
        if (quote.items.length > 256) {
            revert IFeeManager.TooManyQuoteItems(quote.items.length);
        }
    }

    /// @notice Require `nonce == 0`; the field is reserved for future use.
    function requireZeroNonce(IFeeManager.Quote memory quote) internal pure {
        if (quote.nonce != 0) {
            revert NonZeroNonce(quote.nonce);
        }
    }

    /// @notice Locate the quote line item that satisfies a request: same `quoteType`,
    ///         and `quoteArgsHash` consistent with `request.quoteArgs`.
    /// @dev    If a line item with `request.quoteType` exists, its `quoteArgsHash`
    ///         must equal `hashQuoteArgs(request.quoteArgs)` or the call reverts
    ///         with `QuoteArgsMismatch`. If no such line item exists and
    ///         `request.required` is true, the call reverts with
    ///         `RequiredFeeNotInQuote`. Otherwise returns `matched == false` and a
    ///         zeroed `item`/`itemIndex`. This is the per-request quote-structure
    ///         validation step used by `FeeManager._collectMatchedItems`; it does
    ///         not check per-call duplicate request types, expiry, or quote signer.
    function findItemForRequest(IFeeManager.Quote memory quote, IFeeManager.FeeWithQuoteRequest calldata request)
        internal
        pure
        returns (IFeeManager.QuoteItem memory item, uint256 itemIndex, bool matched)
    {
        (item, itemIndex, matched) = findItemByType(quote, request.quoteType);

        if (matched) {
            if (!matchesRequest(item, request.quoteArgs)) {
                revert IFeeManager.QuoteArgsMismatch(request.quoteType, hashQuoteArgs(request.quoteArgs));
            }
        } else if (request.required) {
            revert IFeeManager.RequiredFeeNotInQuote(request.quoteType, hashQuoteArgs(request.quoteArgs));
        }
    }

    /// @notice Return the amount of `feeToken` found for the supplied quote types.
    /// @dev Lightweight query helper for callers that already trust the quote
    ///      context. It intentionally matches by type only and does not verify
    ///      quote arguments, missing required fees, nonce, expiry, or signer.
    ///      Full validation remains in `FeeManager.collectFeesWithQuote`,
    ///      which is what callers should rely on for actual fee collection.
    /// @dev Reverts `TooManyQuoteItems` when `quote.items.length > 256` so the
    ///      preview agrees with `collectFeesWithQuote`, which always rejects
    ///      such quotes via `requireSupportedItemCount`.
    /// @dev Duplicate entries in `quoteTypes` are silently deduplicated so the
    ///      returned `totalFee` mirrors what `collectFeesWithQuote` would
    ///      actually charge (which rejects per-call duplicate matches with
    ///      `DuplicateRequestType`). Dedup uses the same matched-`itemIndex`
    ///      bitmap shape as FeeManager's per-call duplicate detection.
    function sumFees(IFeeManager.Quote memory quote, string[] memory quoteTypes)
        internal
        pure
        returns (uint256 totalFee, address feeToken)
    {
        requireSupportedItemCount(quote);
        feeToken = quote.feeToken;
        uint256 seenItemBitmap = 0;
        for (uint256 i = 0; i < quoteTypes.length; ++i) {
            (IFeeManager.QuoteItem memory item, uint256 itemIndex, bool matched) = findItemByType(quote, quoteTypes[i]);
            if (!matched) continue;
            uint256 bit = uint256(1) << itemIndex;
            if (seenItemBitmap & bit != 0) continue;
            seenItemBitmap |= bit;
            totalFee += item.amount;
        }
    }

    /// @notice Sum of all `QuoteItem.amount` values and the quote’s `feeToken`.
    /// @dev Use as `quote.totalFeeAndFeeToken()` via `using QuoteLib for IFeeManager.Quote`.
    function totalFeeAndFeeToken(IFeeManager.Quote memory quote)
        internal
        pure
        returns (uint256 totalFee, address feeToken)
    {
        feeToken = quote.feeToken;
        IFeeManager.QuoteItem[] memory items = quote.items;
        for (uint256 i = 0; i < items.length; ++i) {
            totalFee += items[i].amount;
        }
    }

    /// @dev Timestamp mode (`0x00`): valid while `block.timestamp <= deadline`.
    ///      Block-number mode (`0x01`): valid while `block.number <= deadline`.
    ///      Reverts `QuoteExpired` or `UnsupportedExpiryMode` otherwise.
    /// @dev Use as `encodedExpiry.validateExpiry()` via `using QuoteLib for uint256`.
    function validateExpiry(uint256 encodedExpiry) internal view {
        uint256 modeWord = encodedExpiry >> 248;
        uint8 mode = SafeCast.toUint8(modeWord);
        uint256 deadline = encodedExpiry & type(uint248).max;
        if (mode == MODE_TIMESTAMP) {
            // Intentional: in timestamp mode the signed quote TTL is wall-clock based.
            // slither-disable-next-line timestamp
            if (block.timestamp > deadline) {
                revert QuoteExpired(mode, deadline, block.timestamp);
            }
        } else if (mode == MODE_BLOCK_NUMBER) {
            if (block.number > deadline) {
                revert QuoteExpired(mode, deadline, block.number);
            }
        } else {
            revert UnsupportedExpiryMode(mode);
        }
    }

    /// @dev Use as `quote.mustNotExpire()` via `using QuoteLib for IFeeManager.Quote`.
    function mustNotExpire(IFeeManager.Quote memory quote) internal view {
        validateExpiry(quote.expiry);
    }

    /// @dev Shared index lookup for `quoteType` (hashed string equality). Used by `findItemByType` and `hasItemType`.
    function _itemIndexOf(IFeeManager.Quote memory quote, string memory quoteType)
        private
        pure
        returns (uint256 itemIndex, bool matched)
    {
        bytes32 requestTypeHash = keccak256(bytes(quoteType));
        IFeeManager.QuoteItem[] memory items = quote.items;
        for (uint256 i = 0; i < items.length; ++i) {
            if (keccak256(bytes(items[i].quoteType)) == requestTypeHash) {
                return (i, true);
            }
        }
        return (0, false);
    }
}
