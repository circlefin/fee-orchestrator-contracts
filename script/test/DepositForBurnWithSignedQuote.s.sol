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

import {IFeeManager} from "../../src/interfaces/IFeeManager.sol";
import {ITokenMessengerWithFees} from "../../src/interfaces/ITokenMessengerWithFees.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @title DepositForBurnWithSignedQuote
/// @notice Calls TokenMessengerWithFees with a pre-signed quote supplied via env var.
/// @dev Unlike `DepositForBurnWithGeneratedQuote`, this script does **not** sign anything;
///      it assumes the caller already has a version-prefixed signed quote (e.g. from a
///      backend signer service). It reads the fee amount and token from the wrapper's
///      `getFee(signedQuote)` view and supports both fee modes:
///      - native fees (`feeToken == address(0)`) are attached as `msg.value`;
///      - ERC-20 fees are approved to the wrapper, which pulls them from the caller via
///        FeeManager. When the fee token equals the burn token a single combined allowance
///        (`burnAmount + feeAmount`) covers both the fee and burn pulls, since the wrapper
///        runs two separate `transferFrom`s and a second `forceApprove` would clobber the first.
///
///      Required env vars:
///      - CALLER_PRIVATE_KEY: EOA that submits the burn call
///      - TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS: wrapper proxy address
///      - BURN_TOKEN_ADDRESS: token to burn (must match what the quote was signed for)
///      - SIGNED_QUOTE: 0x-prefixed, version-prefixed signed quote bytes
///
///      Optional env vars:
///      - BURN_AMOUNT: token units to burn (default: 500_000 — 0.5 USDC at 6 decimals).
///        Must match the `amount` bound into any PRE_FINALITY quote args.
///      - DESTINATION_DOMAIN: CCTP destination domain (default: 0 — Ethereum)
///      - MINT_RECIPIENT: bytes32 mint recipient on destination (default: caller, left-padded)
///      - DESTINATION_CALLER: bytes32 authorized destination caller (default: bytes32(0))
///      - REFUND_ADDRESS: refund attribution address (default: caller). Forwarded to FeeManager
///        verbatim — `address(0)` bypasses the USDC blocklist screen on refund target.
///      - HOOK_DATA: 0x-prefixed hookData. Empty (default) calls `depositForBurnWithFees` and
///        the wrapper auto-injects `HookDataLib.defaultForwardHookData()` if the quote includes
///        a FORWARD item; non-empty routes through `depositForBurnWithHookAndFees` with the
///        caller-supplied hook, which must match what the FORWARD quote args were bound to.
contract DepositForBurnWithSignedQuote is Script {
    using SafeERC20 for IERC20;

    error WrapperNoCode();
    error BurnTokenNoCode();

    struct Env {
        uint256 callerPk;
        uint256 burnAmount;
        bytes32 mintRecipient;
        bytes32 destinationCaller;
        address caller;
        uint32 destinationDomain;
        address wrapper;
        address burnToken;
        address refundAddress;
        bytes signedQuote;
        bytes hookData;
    }

    function run() external {
        Env memory e = _loadEnv();

        (uint256 feeAmount, address feeToken) = ITokenMessengerWithFees(e.wrapper).getFee(e.signedQuote);
        // Native fees are paid via msg.value; ERC-20 fees are pulled from the caller by the
        // wrapper (through FeeManager), so they need an allowance instead and carry no value.
        uint256 nativeValue = feeToken == address(0) ? feeAmount : 0;

        IFeeManager.QuoteClaim memory claim =
            IFeeManager.QuoteClaim({signedQuote: e.signedQuote, refundAddress: payable(e.refundAddress)});

        vm.startBroadcast(e.callerPk);
        _approveSpend(e, feeToken, feeAmount);
        if (e.hookData.length > 0) {
            ITokenMessengerWithFees(e.wrapper).depositForBurnWithHookAndFees{value: nativeValue}(
                e.burnAmount, e.destinationDomain, e.mintRecipient, e.burnToken, e.destinationCaller, e.hookData, claim
            );
        } else {
            ITokenMessengerWithFees(e.wrapper).depositForBurnWithFees{value: nativeValue}(
                e.burnAmount, e.destinationDomain, e.mintRecipient, e.burnToken, e.destinationCaller, claim
            );
        }
        vm.stopBroadcast();

        _logRun(e, feeToken, feeAmount, nativeValue);
    }

    /// @dev Approves the wrapper to pull what it needs from the caller. The burn token is
    ///      always approved for `burnAmount`. For an ERC-20 fee quote the fee token is also
    ///      approved for `feeAmount`; when the fee token *is* the burn token a single combined
    ///      allowance is set instead, because the wrapper issues two separate `transferFrom`s
    ///      and independent approvals would overwrite each other. Native-fee quotes
    ///      (`feeToken == address(0)`) only need the burn-token allowance.
    function _approveSpend(Env memory e, address feeToken, uint256 feeAmount) private {
        if (feeToken != address(0) && feeToken == e.burnToken) {
            IERC20(e.burnToken).forceApprove(e.wrapper, e.burnAmount + feeAmount);
            return;
        }
        IERC20(e.burnToken).forceApprove(e.wrapper, e.burnAmount);
        if (feeToken != address(0)) {
            IERC20(feeToken).forceApprove(e.wrapper, feeAmount);
        }
    }

    function _loadEnv() private view returns (Env memory e) {
        e.callerPk = vm.envUint("CALLER_PRIVATE_KEY");
        e.caller = vm.addr(e.callerPk);
        e.wrapper = vm.envAddress("TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS");
        e.burnToken = vm.envAddress("BURN_TOKEN_ADDRESS");
        e.signedQuote = vm.envBytes("SIGNED_QUOTE");
        if (e.wrapper.code.length == 0) revert WrapperNoCode();
        if (e.burnToken.code.length == 0) revert BurnTokenNoCode();
        e.burnAmount = vm.envOr("BURN_AMOUNT", uint256(500_000));
        e.destinationDomain = uint32(vm.envOr("DESTINATION_DOMAIN", uint256(0)));
        e.mintRecipient = vm.envOr("MINT_RECIPIENT", bytes32(uint256(uint160(e.caller))));
        e.destinationCaller = vm.envOr("DESTINATION_CALLER", bytes32(0));
        e.refundAddress = vm.envOr("REFUND_ADDRESS", e.caller);
        e.hookData = vm.envOr("HOOK_DATA", bytes(""));
    }

    function _logRun(Env memory e, address feeToken, uint256 feeAmount, uint256 nativeValue) private pure {
        console.log("caller:", e.caller);
        console.log("wrapper:", e.wrapper);
        console.log("burnToken:", e.burnToken);
        console.log("burnAmount:", e.burnAmount);
        console.log("destinationDomain:", e.destinationDomain);
        console.log("mintRecipient:");
        console.logBytes32(e.mintRecipient);
        console.log("destinationCaller:");
        console.logBytes32(e.destinationCaller);
        console.log("refundAddress:", e.refundAddress);
        console.log("hookDataLength:", e.hookData.length);
        if (e.hookData.length > 0) {
            console.log("hookData:");
            console.logBytes(e.hookData);
        }
        console.log("feeToken:", feeToken);
        console.log("feeAmount:", feeAmount);
        console.log("attachedNativeValue:", nativeValue);
        console.log("signedQuote:");
        console.logBytes(e.signedQuote);
    }
}
