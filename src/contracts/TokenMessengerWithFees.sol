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

import {QuoteTypes} from "../constants/QuoteTypes.sol";
import {IFeeManager} from "../interfaces/IFeeManager.sol";
import {ITokenMessengerWithFees} from "../interfaces/ITokenMessengerWithFees.sol";
import {IMessageTransmitterV2} from "../interfaces/cctp/IMessageTransmitterV2.sol";
import {ITokenMessengerV2} from "../interfaces/cctp/ITokenMessengerV2.sol";
import {AddressUtils} from "../libraries/AddressUtils.sol";
import {BurnMessageV2Lib} from "../libraries/BurnMessageV2Lib.sol";
import {HookDataLib} from "../libraries/HookDataLib.sol";
import {MessageV2Lib} from "../libraries/MessageV2Lib.sol";
import {QuoteLib} from "../libraries/QuoteLib.sol";
import {SignedQuoteLib} from "../libraries/SignedQuoteLib.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title TokenMessengerWithFees
/// @notice Wrapper over `TokenMessengerV2` that atomically collects fees via
///         `FeeManager` and then delegates to the underlying `TokenMessengerV2`
///         for the standard CCTP burn flow. Deployed behind a UUPS proxy so
///         that the coupled `MessageV2` formatting logic can be updated if
///         `TokenMessengerV2` changes in the future.
/// @dev    This contract replicates the `MessageV2` formatting logic from
///         `TokenMessengerV2` to pre-compute the `correlationHash`
///         (`keccak256(relayFormatMessage)`) before the burn call. This is an
///         accepted coupling in exchange for keeping `TokenMessengerV2`
///         unmodified.
///
///         **Quotes:** Entry points that take `bytes signedQuote` decode with `SignedQuoteLib` in-process (no external
///         `FeeManager.decodeQuote` call). Decode errors and **Panic(0x21)** behavior match `IFeeManager.decodeQuote`;
///         see `SignedQuoteLib` NatSpec.
/// @custom:oz-upgrades
contract TokenMessengerWithFees is ITokenMessengerWithFees, Ownable2StepUpgradeable, UUPSUpgradeable {
    using AddressUtils for address;
    using SafeERC20 for IERC20;
    using QuoteLib for IFeeManager.Quote;

    // ───────────────────── Types ─────────────────────

    /// @dev Bundles the core CCTP transfer parameters to keep the EVM stack
    ///      within the 16-slot limit in the legacy (non-viaIR) codegen.
    struct BurnParams {
        uint256 amount;
        bytes32 mintRecipient;
        bytes32 destinationCaller;
        address burnToken;
        uint32 destinationDomain;
        uint32 minFinalityThreshold;
        bytes hookData;
    }

    // ───────────────────── Errors ─────────────────────

    error RenounceDisabled();

    // ───────────────────── Modifiers ─────────────────────

    /// @dev Entry-point compliance: `TokenMessengerV2` denylist and USDC blocklist
    ///      (see `_checkDenylist`). Skipped when `msg.sender == tx.origin` because
    ///      `TokenMessengerV2` and `FeeTaker` already screen `tx.origin`.
    modifier notDenylistedSender() {
        _checkDenylist();
        _;
    }

    // ───────────────────── Constants ─────────────────────

    /// @dev CCTP `minFinalityThreshold` value requesting pre-finality (fast) attestation.
    uint32 private constant FAST_FINALITY_THRESHOLD = 1000;

    /// @dev CCTP `minFinalityThreshold` value requesting post-finality attestation.
    uint32 private constant SLOW_FINALITY_THRESHOLD = 2000;

    // ───────────────────── Immutables ─────────────────────

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    // slither-disable-next-line naming-convention
    ITokenMessengerV2 private immutable _TOKEN_MESSENGER;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    // slither-disable-next-line naming-convention
    IFeeManager private immutable _FEE_MANAGER;

    /// @dev CCTP source domain from `MessageTransmitterV2.localDomain()` at construction. Fixed for this chain
    ///      deployment (same value `TokenMessengerV2` would read on every burn). Cached to avoid two external
    ///      calls per `_computeCorrelationHash` (`localMessageTransmitter` + `localDomain`).
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    // slither-disable-next-line naming-convention
    uint32 private immutable _SOURCE_DOMAIN;

    /// @dev `bytes32(tokenMessenger)` — the message `sender` field in CCTP v2 hashing. Set once from the constructor
    ///      arg to avoid recomputing on every correlation hash.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    // slither-disable-next-line naming-convention
    bytes32 private immutable _SENDER_BYTES32;

    // ───────────────────── Constructor ─────────────────────

    /// @param tokenMessenger_ Address of the existing `TokenMessengerV2` contract.
    /// @param feeManager_     Address of the `FeeManager` proxy contract.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address tokenMessenger_, address feeManager_) {
        if (tokenMessenger_ == address(0)) revert ZeroTokenMessengerAddress();
        if (feeManager_ == address(0)) revert ZeroFeeManagerAddress();
        _TOKEN_MESSENGER = ITokenMessengerV2(tokenMessenger_);
        _FEE_MANAGER = IFeeManager(feeManager_);
        _SENDER_BYTES32 = tokenMessenger_.toBytes32();
        _SOURCE_DOMAIN = IMessageTransmitterV2(_TOKEN_MESSENGER.localMessageTransmitter()).localDomain();
        _disableInitializers();
    }

    /// @notice Disabled — renouncing ownership would permanently brick the proxy.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ───────────────────── Initializer ─────────────────────

    /// @notice Initializes the TokenMessengerWithFees proxy.
    /// @dev Must be called once via the proxy after deployment.
    /// @param owner_ Address to receive Ownable ownership.
    function initialize(address owner_) external initializer onlyProxy {
        __Ownable_init(owner_);
        __Ownable2Step_init();
    }

    // ───────────────────── External functions ─────────────────────

    /// @inheritdoc ITokenMessengerWithFees
    function depositForBurnWithFees(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        IFeeManager.QuoteClaim calldata claim
    ) external payable override notDenylistedSender {
        IFeeManager.DecodedQuoteClaim memory internalClaim = SignedQuoteLib.decodeClaim(claim);
        // msg.data[0:0]: zero-length calldata slice — no caller-provided hookData
        BurnParams memory p = _buildBurnParams(
            amount,
            destinationDomain,
            mintRecipient,
            burnToken,
            destinationCaller,
            internalClaim.decodedQuote,
            msg.data[0:0]
        );
        _collectFeesAndBurn(p, internalClaim);
    }

    /// @inheritdoc ITokenMessengerWithFees
    function depositForBurnWithFees(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        IFeeManager.DecodedQuoteClaim calldata claim
    ) external payable override notDenylistedSender {
        // Copy the claim from calldata to memory once for reuse by downstream internal calls.
        IFeeManager.DecodedQuoteClaim memory internalClaim = claim;
        BurnParams memory p = _buildBurnParams(
            amount,
            destinationDomain,
            mintRecipient,
            burnToken,
            destinationCaller,
            internalClaim.decodedQuote,
            msg.data[0:0]
        );
        _collectFeesAndBurn(p, internalClaim);
    }

    /// @inheritdoc ITokenMessengerWithFees
    function depositForBurnWithHookAndFees(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        bytes calldata hookData,
        IFeeManager.QuoteClaim calldata claim
    ) external payable override notDenylistedSender {
        if (hookData.length == 0) revert EmptyHookData();
        IFeeManager.DecodedQuoteClaim memory internalClaim = SignedQuoteLib.decodeClaim(claim);
        BurnParams memory p = _buildBurnParams(
            amount, destinationDomain, mintRecipient, burnToken, destinationCaller, internalClaim.decodedQuote, hookData
        );
        _collectFeesAndBurn(p, internalClaim);
    }

    /// @inheritdoc ITokenMessengerWithFees
    function depositForBurnWithHookAndFees(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        bytes calldata hookData,
        IFeeManager.DecodedQuoteClaim calldata claim
    ) external payable override notDenylistedSender {
        if (hookData.length == 0) revert EmptyHookData();
        // Copy the claim from calldata to memory once for reuse by downstream internal calls.
        IFeeManager.DecodedQuoteClaim memory internalClaim = claim;
        BurnParams memory p = _buildBurnParams(
            amount, destinationDomain, mintRecipient, burnToken, destinationCaller, internalClaim.decodedQuote, hookData
        );
        _collectFeesAndBurn(p, internalClaim);
    }

    // ───────────────────── View functions ─────────────────────

    /// @inheritdoc ITokenMessengerWithFees
    function tokenMessenger() public view override returns (address) {
        return address(_TOKEN_MESSENGER);
    }

    /// @inheritdoc ITokenMessengerWithFees
    function feeManager() public view override returns (address) {
        return address(_FEE_MANAGER);
    }

    /// @inheritdoc ITokenMessengerWithFees
    function getFee(bytes calldata signedQuote) external pure override returns (uint256 totalFee, address feeToken) {
        if (signedQuote.length == 0) {
            return (0, address(0));
        }
        IFeeManager.Quote memory quote = SignedQuoteLib.decodeQuote(signedQuote);
        (totalFee, feeToken) = _sumSupportedFees(quote);
    }

    /// @inheritdoc ITokenMessengerWithFees
    function getFee(IFeeManager.Quote calldata decodedQuote)
        external
        pure
        override
        returns (uint256 totalFee, address feeToken)
    {
        IFeeManager.Quote memory quote = decodedQuote;
        (totalFee, feeToken) = _sumSupportedFees(quote);
    }

    // ───────────────────── UUPS ─────────────────────

    /// @inheritdoc UUPSUpgradeable
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ───────────────────── Internal ─────────────────────

    /// @dev Builds `BurnParams` from transfer args, quote, and caller hook calldata.
    /// @param callerHookData Empty for auto forward-hook; non-empty for `depositForBurnWithHookAndFees`.
    function _buildBurnParams(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        IFeeManager.Quote memory quote,
        bytes calldata callerHookData
    ) private pure returns (BurnParams memory) {
        (uint32 minFinalityThreshold, bytes memory hookData) = _inferParamsFromQuote(quote, callerHookData);
        return BurnParams({
            amount: amount,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            burnToken: burnToken,
            destinationDomain: destinationDomain,
            minFinalityThreshold: minFinalityThreshold,
            hookData: hookData
        });
    }

    /// @dev Core implementation shared by all public entry points. Computes
    ///      the correlation hash, builds requests, delegates fee collection
    ///      to `_collectFees`, then pulls and approves the burn token and
    ///      forwards the burn to the underlying `TokenMessengerV2`.
    ///      Reentrancy note: this function relies on `FeeManager.collectFeesWithQuote`
    ///      being `nonReentrant`. Both contracts live in the same repo and are
    ///      deployed together, so the invariant is maintained by design.
    /// @param claim In-memory canonical form of the caller's claim. `refundAddress` is forwarded
    ///        to FeeManager verbatim — TMWF applies no defaulting at this or any other layer.
    function _collectFeesAndBurn(BurnParams memory p, IFeeManager.DecodedQuoteClaim memory claim) internal {
        bytes32 correlationHash = _computeCorrelationHash(p);
        IFeeManager.FeeWithQuoteRequest[] memory requests = _buildRequests(p);

        _collectFees(correlationHash, requests, claim);

        IERC20(p.burnToken).safeTransferFrom(msg.sender, address(this), p.amount);
        IERC20(p.burnToken).forceApprove(address(_TOKEN_MESSENGER), p.amount);

        _depositForBurn(p);
    }

    /// @dev Calls `QuoteLib.sumFees` directly via the `using` directive instead of
    ///      routing through `_FEE_MANAGER.sumFees`. The library function is the
    ///      sole implementation of `IFeeManager.sumFees`, so the answer is
    ///      identical, but skipping the external hop saves a CALL and the
    ///      ABI-encode/decode of the in-memory `Quote` struct on every burn.
    function _sumSupportedFees(IFeeManager.Quote memory quote)
        private
        pure
        returns (uint256 totalFee, address feeToken)
    {
        (totalFee, feeToken) = quote.sumFees(_supportedQuoteTypes());
    }

    function _supportedQuoteTypes() private pure returns (string[] memory quoteTypes) {
        quoteTypes = new string[](2);
        quoteTypes[0] = QuoteTypes.FORWARD;
        quoteTypes[1] = QuoteTypes.PRE_FINALITY;
    }

    /// @dev Forwards the burn to the underlying `TokenMessengerV2`, choosing
    ///      `depositForBurnWithHook` or `depositForBurn` based on `hookData`.
    ///      `maxFee` is `BurnMessageV2Lib.EMPTY_MAX_FEE`; fees are collected on source via `FeeManager`.
    function _depositForBurn(BurnParams memory p) internal {
        if (p.hookData.length > 0) {
            _TOKEN_MESSENGER.depositForBurnWithHook(
                p.amount,
                p.destinationDomain,
                p.mintRecipient,
                p.burnToken,
                p.destinationCaller,
                BurnMessageV2Lib.EMPTY_MAX_FEE,
                p.minFinalityThreshold,
                p.hookData
            );
        } else {
            _TOKEN_MESSENGER.depositForBurn(
                p.amount,
                p.destinationDomain,
                p.mintRecipient,
                p.burnToken,
                p.destinationCaller,
                BurnMessageV2Lib.EMPTY_MAX_FEE,
                p.minFinalityThreshold
            );
        }
    }

    /// @dev Inspects the signed quote and resolves `minFinalityThreshold` and
    ///      `hookData`. When `callerHookData` is empty and the quote contains
    ///      a FORWARD item, a default forwarding hook is constructed
    ///      automatically. When `callerHookData` is non-empty, the presence
    ///      of a `cctp-forward` hook must match the presence of a FORWARD
    ///      quote item: a mismatch in either direction reverts.
    function _inferParamsFromQuote(IFeeManager.Quote memory quote, bytes calldata callerHookData)
        internal
        pure
        returns (uint32 minFinalityThreshold, bytes memory hookData)
    {
        bool quotedForPreFinality = quote.hasItemType(QuoteTypes.PRE_FINALITY);
        bool quotedForForward = quote.hasItemType(QuoteTypes.FORWARD);

        minFinalityThreshold = quotedForPreFinality ? FAST_FINALITY_THRESHOLD : SLOW_FINALITY_THRESHOLD;

        if (callerHookData.length > 0) {
            bool hasForwardHook = _hasForwardHook(callerHookData);
            if (quotedForForward && !hasForwardHook) revert ForwardFeeWithoutHook();
            if (!quotedForForward && hasForwardHook) revert ForwardHookWithoutFee();
            hookData = callerHookData;
        } else if (quotedForForward) {
            hookData = HookDataLib.defaultForwardHookData();
        }
    }

    /// @dev Pre-computes the CCTP v2 relay-format message hash that the
    ///      backend will use to correlate `FeeCollected` events with the
    ///      `MessageSent` event.
    function _computeCorrelationHash(BurnParams memory p) internal view returns (bytes32) {
        bytes32 recipient = _TOKEN_MESSENGER.remoteTokenMessengers(p.destinationDomain);
        if (recipient == bytes32(0)) revert RemoteTokenMessengerNotSet(p.destinationDomain);

        bytes memory messageBody = BurnMessageV2Lib.formatMessage(
            _TOKEN_MESSENGER.messageBodyVersion(),
            p.burnToken.toBytes32(),
            p.mintRecipient,
            p.amount,
            address(this).toBytes32(),
            p.hookData
        );

        return MessageV2Lib.messageHash(
            _SOURCE_DOMAIN,
            p.destinationDomain,
            _SENDER_BYTES32,
            recipient,
            p.destinationCaller,
            p.minFinalityThreshold,
            messageBody
        );
    }

    /// @dev Builds the `FeeWithQuoteRequest[]` array for all CCTP-relevant
    ///      quote types. Both FORWARD and PRE_FINALITY are always included
    ///      with `required: false` so that unmatched items are silently skipped.
    ///      FORWARD and PRE_FINALITY `quoteArgs` both begin with this contract
    ///      address so the signed fees bind to the wrapper that constructs the
    ///      burn payload, and both include `burnToken` to account for costs
    ///      associated with the minted token.
    function _buildRequests(BurnParams memory p)
        internal
        view
        returns (IFeeManager.FeeWithQuoteRequest[] memory requests)
    {
        requests = new IFeeManager.FeeWithQuoteRequest[](2);

        string[] memory forwardArgs = new string[](5);
        forwardArgs[0] = Strings.toHexString(address(this));
        forwardArgs[1] = Strings.toString(uint256(p.destinationDomain));
        forwardArgs[2] = Strings.toHexString(p.burnToken);
        forwardArgs[3] = Strings.toHexString(uint256(p.destinationCaller), 32);
        forwardArgs[4] = Strings.toHexString(p.hookData);
        requests[0] =
            IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: forwardArgs, required: false});

        string[] memory preFinArgs = new string[](4);
        preFinArgs[0] = Strings.toHexString(address(this));
        preFinArgs[1] = Strings.toString(uint256(p.destinationDomain));
        preFinArgs[2] = Strings.toHexString(p.burnToken);
        preFinArgs[3] = Strings.toString(p.amount);
        requests[1] = IFeeManager.FeeWithQuoteRequest({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgs: preFinArgs, required: false
        });
    }

    // ───────────────────── Private ─────────────────────

    /// @dev For intermediaries: `TokenMessengerV2` denylist on `msg.sender` and USDC blocklist on
    ///      `msg.sender` (via `FeeManager.isDenylisted`). When `msg.sender == tx.origin` (direct EOA
    ///      entry), returns early so TMv2 / FeeTaker / USDC token policy still applies downstream.
    ///      This only distinguishes EOA vs intermediary routing — **not** authorization via
    ///      `tx.origin` (see Olympix note on `any-tx-origin`):
    ///      http://detectors.olympixdevsectools.com/article/web3-vulnerability/any-tx-origin
    function _checkDenylist() private view {
        /* solhint-disable avoid-tx-origin */
        if (msg.sender == tx.origin) {
            return;
        }
        /* solhint-enable avoid-tx-origin */
        if (_TOKEN_MESSENGER.isDenylisted(msg.sender)) revert DenylistedCaller(msg.sender);
        if (_FEE_MANAGER.isDenylisted(msg.sender)) revert DenylistedCaller(msg.sender);
    }

    /// @dev Collects fees via `FeeManager.collectFeesWithQuote`, handling
    ///      both native and ERC-20 fee tokens. For ERC-20 fees the supported
    ///      fee amount is computed via `sumFees`, pulled from the caller, and
    ///      approved exactly to FeeManager before collection. `msg.value` is
    ///      always forwarded so FeeManager's own `IncorrectNativePayment`
    ///      check rejects native value sent with an ERC-20 quote, keeping
    ///      that validation in a single place.
    ///      The post-collection assert guards the assumed-valid query path
    ///      (`sumFees`) against drift from the validation path
    ///      (`collectFeesWithQuote`); it also consumes the `feeAmount`
    ///      return value, satisfying the Olympix unused-return-value detector.
    ///      See: http://detectors.olympixdevsectools.com/article/web3-vulnerability/unused-return-function-call
    function _collectFees(
        bytes32 correlationHash,
        IFeeManager.FeeWithQuoteRequest[] memory requests,
        IFeeManager.DecodedQuoteClaim memory claim
    ) private {
        (uint256 quotedFee, address feeToken) = _sumSupportedFees(claim.decodedQuote);

        if (feeToken != address(0) && quotedFee > 0) {
            IERC20(feeToken).safeTransferFrom(msg.sender, address(this), quotedFee);
            IERC20(feeToken).forceApprove(address(_FEE_MANAGER), quotedFee);
        }

        uint256 feeAmount = _FEE_MANAGER.collectFeesWithQuote{value: msg.value}(correlationHash, requests, claim);
        assert(feeAmount == quotedFee);
    }

    /// @dev Thin wrapper around `HookDataLib.getForwardHook` that returns
    ///      only the `found` flag. When found, the hook name is verified to
    ///      be the expected forward-hook magic as an integrity check.
    ///      This indirection exists to work around the Olympix
    ///      unused-return-value detector which flags the discarded `Hook`.
    ///      See: http://detectors.olympixdevsectools.com/article/web3-vulnerability/unused-return-function-call
    function _hasForwardHook(bytes calldata hookData) private pure returns (bool found) {
        HookDataLib.Hook memory hook;
        (hook, found) = HookDataLib.getForwardHook(hookData);
        if (found) {
            assert(hook.name == HookDataLib.FORWARD_MAGIC);
        }
    }
}
