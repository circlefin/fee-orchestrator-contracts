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

import {EIP712TypeHashes} from "../../src/constants/EIP712TypeHashes.sol";
import {QuoteTypes} from "../../src/constants/QuoteTypes.sol";
import {IFeeManager} from "../../src/interfaces/IFeeManager.sol";
import {HookDataLib} from "../../src/libraries/HookDataLib.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Script} from "forge-std/Script.sol";

/// @notice Shared helper for script-side quote hashing/signing.
abstract contract QuoteScriptUtils is Script {
    uint8 internal constant QUOTE_FORMAT_VERSION = 1;

    /// @notice `QUOTE_TYPES` env var contained an entry that is not a TMWF-supported quote type.
    error UnknownQuoteType(string quoteType);
    /// @notice `QUOTE_TYPES` env var listed the same supported quote type more than once.
    /// @dev    Duplicates are rejected so the Solidity-side item builder and the bash-side
    ///         per-item `NATIVE_FEE` accumulator (`cast-deposit-for-burn.sh`) cannot diverge:
    ///         the latter sums fees per entry while the former collapses duplicates into a
    ///         single `QuoteItem`, which would otherwise revert on-chain with
    ///         `IncorrectNativePayment`.
    error DuplicateQuoteType(string quoteType);
    /// @notice `QUOTE_TYPES` parsed to an empty selection (no FORWARD, no PRE_FINALITY).
    error NoQuoteTypesSelected();

    /// @dev Reads the `QUOTE_TYPES` env var (comma-separated; defaults to
    ///      `FORWARD,PRE_FINALITY`) and returns booleans for each supported
    ///      TMWF quote type. Order within the env var does not matter.
    ///      Unknown entries revert with `UnknownQuoteType`, duplicate entries
    ///      revert with `DuplicateQuoteType`, and an empty selection reverts
    ///      with `NoQuoteTypesSelected`.
    function _readSelectedQuoteTypes() internal view returns (bool includeForward, bool includePreFinality) {
        string[] memory defaults = new string[](2);
        defaults[0] = QuoteTypes.FORWARD;
        defaults[1] = QuoteTypes.PRE_FINALITY;
        string[] memory selected = vm.envOr("QUOTE_TYPES", ",", defaults);

        bytes32 forwardHash = keccak256(bytes(QuoteTypes.FORWARD));
        bytes32 preFinHash = keccak256(bytes(QuoteTypes.PRE_FINALITY));
        for (uint256 i = 0; i < selected.length; ++i) {
            bytes32 h = keccak256(bytes(selected[i]));
            if (h == forwardHash) {
                if (includeForward) revert DuplicateQuoteType(QuoteTypes.FORWARD);
                includeForward = true;
            } else if (h == preFinHash) {
                if (includePreFinality) revert DuplicateQuoteType(QuoteTypes.PRE_FINALITY);
                includePreFinality = true;
            } else {
                revert UnknownQuoteType(selected[i]);
            }
        }
        if (!includeForward && !includePreFinality) revert NoQuoteTypesSelected();
    }

    function _buildAndSignQuote(
        uint256 signerPk,
        address feeManager,
        IFeeManager.QuoteItem[] memory items,
        address feeToken,
        uint256 expiry
    ) internal view returns (bytes memory signedQuote, bytes32 digest, bytes memory signature) {
        digest = _quoteDigest(items, expiry, feeToken, feeManager);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        signature = abi.encodePacked(r, s, v);

        // nonce must be 0; the field is reserved for future use
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: expiry, feeToken: feeToken, nonce: 0, signature: signature});
        signedQuote = abi.encodePacked(QUOTE_FORMAT_VERSION, abi.encode(quote));
    }

    function _quoteDigest(IFeeManager.QuoteItem[] memory items, uint256 expiry, address feeToken, address feeManager)
        internal
        view
        returns (bytes32)
    {
        bytes32 domainSep = keccak256(
            abi.encode(
                EIP712TypeHashes.DOMAIN_TYPEHASH,
                keccak256(bytes("FeeManager")),
                keccak256(bytes("1")),
                block.chainid,
                feeManager
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(EIP712TypeHashes.QUOTE_TYPEHASH, _hashQuoteItems(items), expiry, feeToken, 0));
        return keccak256(abi.encodePacked(hex"1901", domainSep, structHash));
    }

    function _hashQuoteItems(IFeeManager.QuoteItem[] memory items) internal pure returns (bytes32) {
        bytes32[] memory itemHashes = new bytes32[](items.length);
        for (uint256 i = 0; i < items.length; ++i) {
            itemHashes[i] = keccak256(
                abi.encode(
                    EIP712TypeHashes.QUOTE_ITEM_TYPEHASH,
                    keccak256(bytes(items[i].quoteType)),
                    items[i].quoteArgsHash,
                    items[i].amount
                )
            );
        }
        return keccak256(abi.encodePacked(itemHashes));
    }

    function _forwardArgsHash(
        address tokenMessengerWithFees,
        uint32 destinationDomain,
        address burnToken,
        bytes32 destinationCaller,
        bytes memory hookData
    ) internal pure returns (bytes32) {
        string[] memory args = new string[](5);
        args[0] = Strings.toHexString(tokenMessengerWithFees);
        args[1] = Strings.toString(uint256(destinationDomain));
        args[2] = Strings.toHexString(burnToken);
        args[3] = Strings.toHexString(uint256(destinationCaller), 32);
        args[4] = Strings.toHexString(hookData);
        return keccak256(abi.encode(args));
    }

    /// @dev FORWARD args hash for `depositForBurnWithFees` when the caller passes no hookData.
    ///      Uses `HookDataLib.defaultForwardHookData()` — the wrapper injects the same bytes before fee matching.
    function _forwardArgsHashForDepositWithFees(
        address tokenMessengerWithFees,
        uint32 destinationDomain,
        address burnToken,
        bytes32 destinationCaller
    ) internal pure returns (bytes32) {
        return _forwardArgsHash(
            tokenMessengerWithFees,
            destinationDomain,
            burnToken,
            destinationCaller,
            HookDataLib.defaultForwardHookData()
        );
    }

    function _preFinalityArgsHash(
        address tokenMessengerWithFees,
        uint32 destinationDomain,
        address burnToken,
        uint256 amount
    ) internal pure returns (bytes32) {
        string[] memory args = new string[](4);
        args[0] = Strings.toHexString(tokenMessengerWithFees);
        args[1] = Strings.toString(uint256(destinationDomain));
        args[2] = Strings.toHexString(burnToken);
        args[3] = Strings.toString(amount);
        return keccak256(abi.encode(args));
    }
}
