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

import {IFeeManager} from "./IFeeManager.sol";

/// @title ITokenMessengerWithFees
/// @notice Interface for the wrapper contract that atomically collects fees
///         via FeeManager and delegates to TokenMessengerV2 for the standard
///         CCTP burn flow.
interface ITokenMessengerWithFees {
    /// @notice Thrown when `depositForBurnWithHookAndFees` is called with
    ///         empty `hookData`.
    error EmptyHookData();

    /// @notice Thrown when the signed quote contains a FORWARD fee item but
    ///         the caller-provided `hookData` does not include a valid
    ///         `cctp-forward` hook.
    error ForwardFeeWithoutHook();

    /// @notice Thrown when the caller-provided `hookData` contains a valid
    ///         `cctp-forward` hook but the signed quote does not contain a
    ///         matching FORWARD fee item. Forwarding behavior must always be
    ///         paid for via a signed FORWARD quote item.
    error ForwardHookWithoutFee();

    /// @notice Thrown when `address(0)` is passed as the TokenMessengerV2 address.
    error ZeroTokenMessengerAddress();

    /// @notice Thrown when `address(0)` is passed as the FeeManager address.
    error ZeroFeeManagerAddress();

    /// @notice Thrown when the remote TokenMessenger is not registered for
    ///         the requested destination domain.
    error RemoteTokenMessengerNotSet(uint32 destinationDomain);

    /// @notice Thrown when `msg.sender` fails entry screening: `TokenMessengerV2` denylist
    ///         or USDC blocklist (`FeeManager.isDenylisted` on the intermediary). When
    ///         `msg.sender == tx.origin`, the wrapper defers these checks to downstream contracts.
    error DenylistedCaller(address caller);

    /// @notice Collects fees via `FeeManager`, then delegates to
    ///         `TokenMessengerV2`. For native-currency fees the caller must
    ///         attach the exact matched fee amount as `msg.value`. For ERC-20
    ///         fees the caller must approve this contract for at least that
    ///         matched amount. Use `getFee` to estimate the amount required for
    ///         a valid quote. `maxFee` is omitted because fees
    ///         are prepaid on the source chain.
    ///         `minFinalityThreshold` is inferred from the presence of a
    ///         `PRE_FINALITY` item in the quote. If the quote contains a
    ///         `FORWARD` item, a default forwarding hook is constructed
    ///         automatically and `depositForBurnWithHook` is used.
    ///
    ///         **Refund attribution:** the wrapper passes `claim.refundAddress` through to
    ///         `FeeManager` verbatim. No defaulting — `address(0)` is forwarded as-is and
    ///         results in `FeeCollected.refundAddress == address(0)`. Callers must explicitly
    ///         set `refundAddress` to whatever address should receive refunds, if any.
    /// @param amount             Amount of tokens to burn.
    /// @param destinationDomain  Destination domain.
    /// @param mintRecipient      Mint recipient on destination domain.
    /// @param burnToken          Token to burn.
    /// @param destinationCaller  Authorized caller on destination domain.
    /// @param claim              `IFeeManager.QuoteClaim` bundle: the version-prefixed signed
    ///                           quote bytes plus the per-call `refundAddress`. See
    ///                           `IFeeManager.QuoteClaim` for field semantics.
    function depositForBurnWithFees(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        IFeeManager.QuoteClaim calldata claim
    ) external payable;

    /// @notice Same as the `QuoteClaim` overload, but the caller passes an already-decoded `Quote`
    ///         body bundled with the `refundAddress` via `DecodedQuoteClaim`. Avoids the wire-format
    ///         decode when the caller already has the decoded body.
    /// @param claim  `IFeeManager.DecodedQuoteClaim` bundle: the decoded `Quote` body plus the
    ///               per-call `refundAddress`. `refundAddress` is forwarded to `FeeManager`
    ///               verbatim (no defaulting); see `depositForBurnWithFees(QuoteClaim)`.
    function depositForBurnWithFees(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        IFeeManager.DecodedQuoteClaim calldata claim
    ) external payable;

    /// @notice Collects fees via `FeeManager`, then calls
    ///         `TokenMessengerV2.depositForBurnWithHook`. For native-currency
    ///         fees the caller must attach the exact matched fee amount as
    ///         `msg.value`. For ERC-20 fees the caller must approve this
    ///         contract for at least that matched amount. Use `getFee` to
    ///         estimate the amount required for a valid quote.
    ///         `maxFee` is omitted because fees are prepaid on the source
    ///         chain. `minFinalityThreshold` is inferred from the presence of
    ///         a `PRE_FINALITY` item in the quote. If the quote contains a
    ///         `FORWARD` item, `hookData` must include a valid `cctp-forward`
    ///         hook or the call reverts with `ForwardFeeWithoutHook`. Conversely,
    ///         if `hookData` contains a `cctp-forward` hook but the quote omits
    ///         the `FORWARD` item, the call reverts with `ForwardHookWithoutFee`
    ///         — forwarding behavior must always be paid for.
    ///
    ///         **Refund attribution:** see `depositForBurnWithFees`.
    /// @param amount             Amount of tokens to burn.
    /// @param destinationDomain  Destination domain.
    /// @param mintRecipient      Mint recipient on destination domain.
    /// @param burnToken          Token to burn.
    /// @param destinationCaller  Authorized caller on destination domain.
    /// @param hookData           Hook data for destination domain. Must not
    ///                           be empty. The caller controls the hook
    ///                           format; no automatic reformatting is applied.
    /// @param claim              `IFeeManager.QuoteClaim` bundle.
    function depositForBurnWithHookAndFees(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        bytes calldata hookData,
        IFeeManager.QuoteClaim calldata claim
    ) external payable;

    /// @notice Same as the `QuoteClaim` overload, but the caller passes an already-decoded `Quote`
    ///         body bundled with the `refundAddress` via `DecodedQuoteClaim`.
    /// @param claim  `IFeeManager.DecodedQuoteClaim` bundle.
    function depositForBurnWithHookAndFees(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        bytes calldata hookData,
        IFeeManager.DecodedQuoteClaim calldata claim
    ) external payable;

    /// @notice Return the fee amount and token present in a quote for the fee
    ///         types this wrapper supports (`FORWARD` and `PRE_FINALITY`).
    /// @dev    Decodes the signed quote in-process and computes the sum via
    ///         `QuoteLib.sumFees` (the same library `FeeManager.sumFees`
    ///         delegates to). This is a lightweight type-based query for
    ///         quotes assumed to be valid; quote-argument, signature, expiry,
    ///         nonce, and payment validation happen only during collection.
    ///         Empty `signedQuote` returns `(0, address(0))`, matching
    ///         `FeeManager.sumFees`, `getQuoteTotal`, and `getQuoteItem`.
    /// @param signedQuote Version-prefixed, ABI-encoded `Quote` struct.
    /// @return totalFee   Sum of supported quote-type amounts.
    /// @return feeToken   Fee token (`address(0)` for native).
    function getFee(bytes calldata signedQuote) external pure returns (uint256 totalFee, address feeToken);

    /// @notice Same as the signed-quote overload, but accepts a decoded `Quote`.
    function getFee(IFeeManager.Quote calldata decodedQuote) external pure returns (uint256 totalFee, address feeToken);

    /// @notice Returns the address of the `TokenMessengerV2` contract.
    function tokenMessenger() external view returns (address);

    /// @notice Returns the address of the `FeeManager` proxy contract.
    function feeManager() external view returns (address);
}
