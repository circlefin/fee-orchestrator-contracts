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
import {ITokenMessengerWithFees} from "../../src/interfaces/ITokenMessengerWithFees.sol";
import {QuoteScriptUtils} from "./QuoteScriptUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "forge-std/console.sol";

/// @title DepositForBurnWithGeneratedQuote
/// @notice Builds a matching signed quote and calls TokenMessengerWithFees.
/// @dev Required env vars:
///      - CALLER_PRIVATE_KEY: EOA that submits the burn call
///      - QUOTE_SIGNER: private key used to sign quote digest
///      - TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS: wrapper proxy address
///      - BURN_TOKEN_ADDRESS: token to burn (USDC)
///      Immutables on the wrapper are fixed at TMWF deploy: `tokenMessenger()` (CCTP TokenMessengerV2) and
///      `feeManager()` (FeeManager proxy). Fees are collected via `FeeManager.collectFeesWithQuote` on that
///      `feeManager` address. A revert such as call to non-contract on `0x..::collectFeesWithQuote` means
///      there is no contract at that FeeManager address on this RPC's chain (deploy the FeeManager proxy
///      there, or use a wrapper deployed with the correct FeeManager / salt prediction for this network).
///      Optional env vars:
///      - DESTINATION_DOMAIN: CCTP destination domain (default: 0 - Ethereum)
///      - MINT_RECIPIENT: bytes32 mint recipient on destination (default: caller address, left-padded)
///      - QUOTE_BASE_TIMESTAMP: unix timestamp used as "now" (default: block.timestamp)
///      - QUOTE_TYPES: comma-separated subset of {FORWARD, PRE_FINALITY} to include in the quote
///        (default: "FORWARD,PRE_FINALITY"; unknown entries, duplicates, empty tokens, and an
///        empty selection all revert). The attached `msg.value` is the sum of the included
///        items' fees and the wrapper picks the matching finality threshold and hook.
contract DepositForBurnWithGeneratedQuote is QuoteScriptUtils {
    using SafeERC20 for IERC20;

    error WrapperNoCode();
    error BurnTokenNoCode();
    error TokenMessengerNoCode();
    error FeeManagerNoCode();

    uint256 private constant BURN_AMOUNT = 500_000; // 0.5 USDC (6 decimals)
    uint256 private constant FORWARD_COST = 0.00001 ether;
    uint256 private constant PRE_FINALITY_COST = 0.000005 ether;

    struct Env {
        uint256 callerPk;
        uint256 quoteSignerPk;
        address caller;
        address wrapper;
        address burnToken;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address feeManager;
        address tokenMessengerV2;
        bool includeForward;
        bool includePreFinality;
    }

    function run() external {
        Env memory e = _loadEnv();
        bytes memory signedQuote = _buildSignedQuote(e);

        uint256 nativeFeeValue = (e.includeForward ? FORWARD_COST : 0) + (e.includePreFinality ? PRE_FINALITY_COST : 0);
        bytes32 destinationCaller = bytes32(0);

        // Use the script's broadcasting EOA as the refund target so any off-chain refund
        // attribution emitted in `FeeCollected` points back at the caller of this script.
        IFeeManager.QuoteClaim memory claim =
            IFeeManager.QuoteClaim({signedQuote: signedQuote, refundAddress: payable(e.caller)});

        vm.startBroadcast(e.callerPk);
        IERC20(e.burnToken).forceApprove(e.wrapper, BURN_AMOUNT);
        ITokenMessengerWithFees(e.wrapper).depositForBurnWithFees{value: nativeFeeValue}(
            BURN_AMOUNT, e.destinationDomain, e.mintRecipient, e.burnToken, destinationCaller, claim
        );
        vm.stopBroadcast();

        _logRun(e, vm.addr(e.quoteSignerPk), destinationCaller, nativeFeeValue, signedQuote);
    }

    function _loadEnv() private view returns (Env memory e) {
        e.callerPk = vm.envUint("CALLER_PRIVATE_KEY");
        e.quoteSignerPk = vm.envUint("QUOTE_SIGNER");
        e.caller = vm.addr(e.callerPk);
        e.wrapper = vm.envAddress("TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS");
        e.burnToken = vm.envAddress("BURN_TOKEN_ADDRESS");
        if (e.wrapper.code.length == 0) revert WrapperNoCode();
        if (e.burnToken.code.length == 0) revert BurnTokenNoCode();
        e.tokenMessengerV2 = ITokenMessengerWithFees(e.wrapper).tokenMessenger();
        e.feeManager = ITokenMessengerWithFees(e.wrapper).feeManager();
        if (e.tokenMessengerV2.code.length == 0) revert TokenMessengerNoCode();
        if (e.feeManager.code.length == 0) revert FeeManagerNoCode();
        e.destinationDomain = uint32(vm.envOr("DESTINATION_DOMAIN", uint256(0)));
        e.mintRecipient = vm.envOr("MINT_RECIPIENT", bytes32(uint256(uint160(e.caller))));
        (e.includeForward, e.includePreFinality) = _readSelectedQuoteTypes();
    }

    function _buildSignedQuote(Env memory e) private view returns (bytes memory) {
        uint256 itemCount = (e.includeForward ? 1 : 0) + (e.includePreFinality ? 1 : 0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](itemCount);
        uint256 idx;
        if (e.includeForward) {
            items[idx] = IFeeManager.QuoteItem({
                quoteType: QuoteTypes.FORWARD,
                quoteArgsHash: _forwardArgsHashForDepositWithFees(
                    e.wrapper, e.destinationDomain, e.burnToken, bytes32(0)
                ),
                amount: FORWARD_COST
            });
            ++idx;
        }
        if (e.includePreFinality) {
            items[idx] = IFeeManager.QuoteItem({
                quoteType: QuoteTypes.PRE_FINALITY,
                quoteArgsHash: _preFinalityArgsHash(e.wrapper, e.destinationDomain, e.burnToken, BURN_AMOUNT),
                amount: PRE_FINALITY_COST
            });
            ++idx;
        }

        uint256 baseTimestamp = vm.envOr("QUOTE_BASE_TIMESTAMP", uint256(block.timestamp));
        uint256 expiry = baseTimestamp + 1 hours;
        (bytes memory signedQuote,,) = _buildAndSignQuote(e.quoteSignerPk, e.feeManager, items, address(0), expiry);
        return signedQuote;
    }

    function _logRun(
        Env memory e,
        address quoteSigner,
        bytes32 destinationCaller,
        uint256 nativeFeeValue,
        bytes memory signedQuote
    ) private pure {
        console.log("caller:", e.caller);
        console.log("quoteSigner:", quoteSigner);
        console.log("wrapper:", e.wrapper);
        console.log("tokenMessengerV2:", e.tokenMessengerV2);
        console.log("feeManager:", e.feeManager);
        console.log("burnToken:", e.burnToken);
        console.log("burnAmount:", BURN_AMOUNT);
        console.log("destinationDomain:", e.destinationDomain);
        console.log("mintRecipient:");
        console.logBytes32(e.mintRecipient);
        console.log("destinationCaller:");
        console.logBytes32(destinationCaller);
        console.log("includeForward:", e.includeForward);
        console.log("includePreFinality:", e.includePreFinality);
        console.log("attachedNativeValue:", nativeFeeValue);
        console.log("signedQuote:");
        console.logBytes(signedQuote);
    }
}
