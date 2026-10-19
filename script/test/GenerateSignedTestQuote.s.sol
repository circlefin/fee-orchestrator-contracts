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

import {QuoteTypes} from "../../src/constants/QuoteTypes.sol";
import {IFeeManager} from "../../src/interfaces/IFeeManager.sol";
import {HookDataLib} from "../../src/libraries/HookDataLib.sol";
import {QuoteScriptUtils} from "./QuoteScriptUtils.sol";
import {console} from "forge-std/console.sol";

/// @title GenerateSignedTestQuote
/// @notice Produces a version-prefixed signed quote blob for local testing.
/// @dev Required env vars:
///      - QUOTE_SIGNER: private key used for vm.sign
///      - FEE_MANAGER_PROXY_ADDRESS: verifying contract used in EIP-712 domain
///      - TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS: wrapper address bound into both FORWARD and PRE_FINALITY quote args
///      - BURN_TOKEN_ADDRESS: burn token bound into both FORWARD and PRE_FINALITY quote args (must match a real burn if you use the quote on-chain)
///      Optional env vars:
///      - DESTINATION_DOMAIN: destination domain bound into both FORWARD and PRE_FINALITY quote args (default: 0)
///      - QUOTE_BASE_TIMESTAMP: unix timestamp used as "now" (default: block.timestamp)
///      - QUOTE_TYPES: comma-separated subset of {FORWARD, PRE_FINALITY} to include in the quote
///        (default: "FORWARD,PRE_FINALITY"). Order is irrelevant; unknown entries, duplicates,
///        empty tokens, and an empty selection all revert.
contract GenerateSignedTestQuote is QuoteScriptUtils {
    uint256 private constant BURN_AMOUNT = 500_000; // 0.5 USDC (6 decimals); must match intended `depositForBurnWithFees` amount
    uint256 private constant FORWARD_COST = 0.00001 ether;
    uint256 private constant PRE_FINALITY_COST = 0.000005 ether;

    function run() external view {
        uint256 signerPk = vm.envUint("QUOTE_SIGNER");
        address signer = vm.addr(signerPk);
        address feeManager = vm.envAddress("FEE_MANAGER_PROXY_ADDRESS");
        address tokenMessengerWithFees = vm.envAddress("TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS");
        address burnToken = vm.envAddress("BURN_TOKEN_ADDRESS");
        address feeToken = address(0);
        uint32 destinationDomain = uint32(vm.envOr("DESTINATION_DOMAIN", uint256(0)));
        (bool includeForward, bool includePreFinality) = _readSelectedQuoteTypes();

        IFeeManager.QuoteItem[] memory items =
            _buildItems(tokenMessengerWithFees, destinationDomain, burnToken, includeForward, includePreFinality);

        uint256 baseTimestamp = vm.envOr("QUOTE_BASE_TIMESTAMP", uint256(block.timestamp));
        uint256 expiry = baseTimestamp + 1 hours;
        (bytes memory signedQuote, bytes32 digest, bytes memory signature) =
            _buildAndSignQuote(signerPk, feeManager, items, feeToken, expiry);

        console.log("quoteSigner:", signer);
        console.log("feeManager:", feeManager);
        console.log("tokenMessengerWithFees:", tokenMessengerWithFees);
        console.log("feeToken (native):", feeToken);
        console.log("burnToken:", burnToken);
        console.log("burnAmount (PRE_FINALITY args):", BURN_AMOUNT);
        console.log("destinationDomain:", destinationDomain);
        console.log("destinationCaller (bytes32):");
        console.logBytes32(bytes32(0));
        console.log("includeForward:", includeForward);
        console.log("includePreFinality:", includePreFinality);
        console.log("resolvedForwardHookData (matches depositForBurnWithFees with empty calldata hook):");
        console.logBytes(HookDataLib.defaultForwardHookData());
        console.log("baseTimestamp:", baseTimestamp);
        console.log("validUntil:", expiry);
        console.log("forwardAmount:", includeForward ? FORWARD_COST : 0);
        console.log("preFinalityAmount:", includePreFinality ? PRE_FINALITY_COST : 0);
        console.log("digest:");
        console.logBytes32(digest);
        console.log("signature:");
        console.logBytes(signature);
        console.log("signedQuote:");
        console.logBytes(signedQuote);
    }

    function _buildItems(
        address tokenMessengerWithFees,
        uint32 destinationDomain,
        address burnToken,
        bool includeForward,
        bool includePreFinality
    ) private pure returns (IFeeManager.QuoteItem[] memory items) {
        uint256 itemCount = (includeForward ? 1 : 0) + (includePreFinality ? 1 : 0);
        items = new IFeeManager.QuoteItem[](itemCount);
        uint256 idx;
        if (includeForward) {
            items[idx] = IFeeManager.QuoteItem({
                quoteType: QuoteTypes.FORWARD,
                quoteArgsHash: _forwardArgsHashForDepositWithFees(
                    tokenMessengerWithFees, destinationDomain, burnToken, bytes32(0)
                ),
                amount: FORWARD_COST
            });
            ++idx;
        }
        if (includePreFinality) {
            items[idx] = IFeeManager.QuoteItem({
                quoteType: QuoteTypes.PRE_FINALITY,
                quoteArgsHash: _preFinalityArgsHash(tokenMessengerWithFees, destinationDomain, burnToken, BURN_AMOUNT),
                amount: PRE_FINALITY_COST
            });
            ++idx;
        }
    }
}
