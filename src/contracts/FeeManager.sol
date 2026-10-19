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

import {WithFeeCollectionAddress} from "../access/WithFeeCollectionAddress.sol";
import {WithTrustedQuoteSigners} from "../access/WithTrustedQuoteSigners.sol";
import {EIP712TypeHashes} from "../constants/EIP712TypeHashes.sol";
import {Roles} from "../constants/Roles.sol";
import {IFeeManager} from "../interfaces/IFeeManager.sol";
import {IFeeTaker} from "../interfaces/IFeeTaker.sol";
import {IUSDCBlacklist} from "../interfaces/IUSDCBlacklist.sol";
import {QuoteLib} from "../libraries/QuoteLib.sol";
import {SignedQuoteLib} from "../libraries/SignedQuoteLib.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title FeeManager
/// @notice Collects fees against server-signed quotes on behalf of callers.
/// @dev UUPS upgradeable: implementation uses `_disableInitializers()`; the proxy must call
///      `initialize(owner_)` once. Access control is managed via OpenZeppelin's
///      AccessControlUpgradeable with dedicated roles (`CALLER_ADMIN_ROLE`,
///      `SIGNER_ADMIN_ROLE`, `PAUSER_ROLE`, `ALLOWED_CALLER_ROLE`,
///      `FEE_COLLECTION_ADMIN_ROLE`). The trusted signer set uses EIP-7201
///      namespaced storage (WithTrustedQuoteSignersStorage); the optional fee
///      collection address override (forwarded to `IFeeTaker.takeFee*`) uses
///      a separate EIP-7201 namespace (WithFeeCollectionAddressStorage) and
///      is managed by `FEE_COLLECTION_ADMIN_ROLE`.
///      The owner holds DEFAULT_ADMIN_ROLE and authorizes upgrades.
///      No receive() or fallback() by design — ETH only enters via
///      collectFeesWithQuote{value: ...}() and is forwarded immediately
///      to FeeTaker; FeeManager never holds funds. Direct transfers revert.
///
///      **Signed quotes:** The `collectFeesWithQuote` overload that takes `bytes signedQuote` decodes in-process
///      via `SignedQuoteLib` (same semantics as external `decodeQuote`). See `SignedQuoteLib` and `IFeeManager`
///      NatSpec for custom errors vs Solidity **Panic(0x21)** when ABI-decoding malformed tails.
///
///      Do not cache a full `_DOMAIN_SEPARATOR` immutable for this UUPS implementation:
///      the constructor runs on the implementation contract, but signatures must bind
///      `verifyingContract` to the proxy address observed through `delegatecall`.
/// @custom:oz-upgrades
contract FeeManager is
    IFeeManager,
    WithTrustedQuoteSigners,
    WithFeeCollectionAddress,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using QuoteLib for IFeeManager.Quote;
    using QuoteLib for IFeeManager.QuoteItem;

    // ───────────────────── Errors ─────────────────────

    error RenounceDisabled();
    /// @dev Public `grantRole` / `revokeRole` cannot change `DEFAULT_ADMIN_ROLE`; it follows ownership via `_transferOwnership`.
    error DefaultAdminRoleChangeDisabled();
    /// @dev OpenZeppelin `AccessControl` allows `address(0)`; we reject it on `grantRole` / `revokeRole`.
    error ZeroRoleAccount();
    error ZeroFeeTakerAddress();
    error ZeroUsdcBlacklistAddress();
    error InvalidQuoteSigner(address recovered);
    error IncorrectNativePayment(uint256 required, uint256 provided);

    // ───────────────────── Constants ─────────────────────

    /// @dev Placeholder kitType passed to FeeTaker. FeeManager is not a kit,
    ///      so a placeholder value is used per the design spec.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes8 private constant FEE_TAKER_KIT_TYPE = bytes8("_");

    /// @dev keccak256(bytes("FeeManager")).
    bytes32 internal constant _HASHED_NAME = 0x42e3570c507db8e472a4592e53f4b6df78eb7c8a8d593e718bb47b707f2c6a90;

    /// @dev keccak256(bytes("1")).
    bytes32 internal constant _HASHED_VERSION = 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    // ───────────────────── Immutables ─────────────────────

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    // slither-disable-next-line naming-convention
    IFeeTaker private immutable _FEE_TAKER;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    // slither-disable-next-line naming-convention
    IUSDCBlacklist private immutable _USDC_BLACKLIST;

    /// @dev Constructor that sets immutable FeeTaker and USDC blacklist
    ///      addresses and disables initializers on the implementation contract.
    /// @param feeTaker_ Address of the deployed FeeTaker proxy contract.
    /// @param usdcBlacklist_ The USDC contract that exposes `isBlacklisted`; must be the same
    ///        deployment whose blacklist `FeeTaker` uses for screening on this chain.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address feeTaker_, address usdcBlacklist_) {
        if (feeTaker_ == address(0)) revert ZeroFeeTakerAddress();
        if (usdcBlacklist_ == address(0)) revert ZeroUsdcBlacklistAddress();
        _FEE_TAKER = IFeeTaker(feeTaker_);
        _USDC_BLACKLIST = IUSDCBlacklist(usdcBlacklist_);
        _disableInitializers();
    }

    /// @notice Initializes the FeeManager proxy.
    /// @dev Must be called once via the proxy after deployment. Sets owner to
    ///      `owner_` and grants DEFAULT_ADMIN_ROLE. Sets CALLER_ADMIN_ROLE as
    ///      the role admin for ALLOWED_CALLER_ROLE.
    /// @param owner_ Address to receive ownership and DEFAULT_ADMIN_ROLE.
    function initialize(address owner_) external initializer onlyProxy {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _setRoleAdmin(Roles.ALLOWED_CALLER_ROLE, Roles.CALLER_ADMIN_ROLE);
    }

    /// @dev Syncs DEFAULT_ADMIN_ROLE with ownership on every transfer.
    function _transferOwnership(address newOwner) internal override {
        address oldOwner = owner();
        super._transferOwnership(newOwner);
        _revokeRole(DEFAULT_ADMIN_ROLE, oldOwner);
        _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
    }

    /// @notice Disabled — renouncing ownership would permanently brick the proxy.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @dev Prevents renouncing DEFAULT_ADMIN_ROLE, which would desync from ownership.
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert RenounceDisabled();
        super.renounceRole(role, callerConfirmation);
    }

    /// @inheritdoc AccessControlUpgradeable
    function grantRole(bytes32 role, address account) public override(AccessControlUpgradeable) {
        if (role == DEFAULT_ADMIN_ROLE) revert DefaultAdminRoleChangeDisabled();
        if (account == address(0)) revert ZeroRoleAccount();
        super.grantRole(role, account);
    }

    /// @inheritdoc AccessControlUpgradeable
    function revokeRole(bytes32 role, address account) public override(AccessControlUpgradeable) {
        if (role == DEFAULT_ADMIN_ROLE) revert DefaultAdminRoleChangeDisabled();
        if (account == address(0)) revert ZeroRoleAccount();
        super.revokeRole(role, account);
    }

    /// @inheritdoc UUPSUpgradeable
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ───────────────────── Pause ─────────────────────

    /// @notice Halts all `collectFeesWithQuote` calls.
    function pause() external onlyRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes `collectFeesWithQuote` calls.
    function unpause() external onlyRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    // ───────────────────── External functions ─────────────────────

    /// @inheritdoc IFeeManager
    function collectFeesWithQuote(
        bytes32 correlationHash,
        FeeWithQuoteRequest[] calldata requests,
        QuoteClaim calldata claim
    )
        external
        payable
        override
        onlyRole(Roles.ALLOWED_CALLER_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        _screenRefundAddress(claim.refundAddress);
        if (requests.length == 0) {
            if (msg.value != 0) revert IncorrectNativePayment(0, msg.value);
            return 0;
        }

        return _collectFeesWithQuoteDecoded(correlationHash, requests, SignedQuoteLib.decodeClaim(claim));
    }

    /// @inheritdoc IFeeManager
    function collectFeesWithQuote(
        bytes32 correlationHash,
        FeeWithQuoteRequest[] calldata requests,
        DecodedQuoteClaim calldata claim
    )
        external
        payable
        override
        onlyRole(Roles.ALLOWED_CALLER_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        _screenRefundAddress(claim.refundAddress);
        if (requests.length == 0) {
            if (msg.value != 0) revert IncorrectNativePayment(0, msg.value);
            return 0;
        }

        // Implicit calldata→memory copy of the full claim (Quote body + refundAddress) at the call boundary.
        return _collectFeesWithQuoteDecoded(correlationHash, requests, claim);
    }

    /// @dev `address(0)` is accepted (no refund target) and bypasses the screen. Non-zero
    ///      addresses are checked against the configured USDC blacklist; the call reverts if listed.
    function _screenRefundAddress(address payable refundAddress) private view {
        if (refundAddress != address(0) && _USDC_BLACKLIST.isBlacklisted(refundAddress)) {
            revert DenylistedRefundAddress(refundAddress);
        }
    }

    /// @dev Shared body after the `DecodedQuoteClaim` (Quote body + refundAddress) is in memory,
    ///      whether constructed from a wire decode or copied from calldata.
    function _collectFeesWithQuoteDecoded(
        bytes32 correlationHash,
        FeeWithQuoteRequest[] calldata requests,
        DecodedQuoteClaim memory claim
    ) private returns (uint256 amount) {
        claim.decodedQuote.requireSupportedItemCount();
        claim.decodedQuote.mustNotExpire();
        claim.decodedQuote.requireZeroNonce();

        _verifySignedQuote(claim.decodedQuote);

        // Resolve the recipient once so `_collectMatchedItems` event attribution
        // matches the address that `_forwardFees` pays for the computed total.
        address payable feeRecipient = _resolveFeeCollectionAddress();
        uint256 totalCollected = _collectMatchedItems(claim, correlationHash, requests, feeRecipient);

        if (totalCollected > 0) {
            _forwardFees(claim.decodedQuote.feeToken, totalCollected, feeRecipient);
        } else if (msg.value != 0) {
            revert IncorrectNativePayment(0, msg.value);
        }
        return totalCollected;
    }

    /// @inheritdoc IFeeManager
    function decodeQuote(bytes calldata signedQuote) external pure override returns (Quote memory) {
        return SignedQuoteLib.decodeQuote(signedQuote);
    }

    /// @inheritdoc IFeeManager
    function getQuoteItem(bytes calldata signedQuote, string calldata quoteType)
        external
        pure
        override
        returns (QuoteItem memory item, bool found)
    {
        if (signedQuote.length == 0) {
            return (item, false);
        }
        Quote memory quote = SignedQuoteLib.decodeQuote(signedQuote);
        uint256 itemIndex;
        (item, itemIndex, found) = quote.findItemByType(quoteType);
        assert(!found || itemIndex < quote.items.length);
        return (item, found);
    }

    /// @inheritdoc IFeeManager
    function getQuoteItem(Quote calldata decodedQuote, string calldata quoteType)
        external
        pure
        override
        returns (QuoteItem memory item, bool found)
    {
        Quote memory quote = decodedQuote;
        uint256 itemIndex;
        (item, itemIndex, found) = quote.findItemByType(quoteType);
        assert(!found || itemIndex < quote.items.length);
        return (item, found);
    }

    /// @inheritdoc IFeeManager
    function getQuoteTotal(bytes calldata signedQuote)
        external
        pure
        override
        returns (uint256 totalFee, address feeToken)
    {
        if (signedQuote.length == 0) {
            return (0, address(0));
        }
        Quote memory quote = SignedQuoteLib.decodeQuote(signedQuote);
        (uint256 sum, address token) = quote.totalFeeAndFeeToken();
        return (sum, token);
    }

    /// @inheritdoc IFeeManager
    function getQuoteTotal(Quote calldata decodedQuote)
        external
        pure
        override
        returns (uint256 totalFee, address feeToken)
    {
        Quote memory quote = decodedQuote;
        (uint256 sum, address token) = quote.totalFeeAndFeeToken();
        return (sum, token);
    }

    /// @inheritdoc IFeeManager
    function sumFees(bytes calldata signedQuote, string[] calldata quoteTypes)
        external
        pure
        override
        returns (uint256 totalFee, address feeToken)
    {
        if (signedQuote.length == 0) {
            return (0, address(0));
        }
        Quote memory quote = SignedQuoteLib.decodeQuote(signedQuote);
        (totalFee, feeToken) = quote.sumFees(quoteTypes);
    }

    /// @inheritdoc IFeeManager
    function sumFees(Quote calldata decodedQuote, string[] calldata quoteTypes)
        external
        pure
        override
        returns (uint256 totalFee, address feeToken)
    {
        Quote memory quote = decodedQuote;
        (totalFee, feeToken) = quote.sumFees(quoteTypes);
    }

    /// @notice Returns the immutable FeeTaker proxy address.
    function feeTaker() public view returns (address) {
        return address(_FEE_TAKER);
    }

    /// @notice USDC contract used for `isDenylisted` (not part of `IFeeManager`).
    function usdcBlacklist() external view returns (address) {
        return address(_USDC_BLACKLIST);
    }

    /// @inheritdoc IFeeManager
    function isDenylisted(address account) external view override returns (bool) {
        return _USDC_BLACKLIST.isBlacklisted(account);
    }

    /// @dev Forwards collected fees to FeeTaker. For native currency, forwards
    ///      msg.value via takeFeeNative. For ERC-20, pulls tokens from
    ///      msg.sender, approves FeeTaker, then calls takeFeeERC20.
    function _forwardFees(address feeToken, uint256 amount, address payable feeRecipient) private {
        assert(feeRecipient != address(0));
        if (feeToken == address(0)) {
            if (msg.value != amount) revert IncorrectNativePayment(amount, msg.value);
            _FEE_TAKER.takeFeeNative{value: amount}(feeRecipient, FEE_TAKER_KIT_TYPE);
        } else {
            if (msg.value != 0) revert IncorrectNativePayment(0, msg.value);
            IERC20(feeToken).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(feeToken).forceApprove(address(_FEE_TAKER), amount);
            _FEE_TAKER.takeFeeERC20(feeToken, feeRecipient, amount, FEE_TAKER_KIT_TYPE);
        }
    }

    /// @dev Returns the effective fee collection address passed as beneficiary
    ///      to FeeTaker: the override set via `setFeeCollectionAddress` when
    ///      non-zero, or `IFeeTaker.protocolFeeAddress()` (default) when no
    ///      override is set. Returned as `address payable` because
    ///      `IFeeTaker.takeFeeNative` forwards native currency to it.
    function _resolveFeeCollectionAddress() private view returns (address payable) {
        address payable overrideAddr = _feeCollectionAddress();
        if (overrideAddr != address(0)) {
            return overrideAddr;
        }
        return payable(_FEE_TAKER.protocolFeeAddress());
    }

    /// @dev Single fused loop over `requests`. For each request:
    ///      - `QuoteLib.findItemForRequest` performs the per-request quote-structure
    ///        validation (locate by `quoteType`, assert `quoteArgsHash`, enforce
    ///        `required`); missing optional requests are skipped.
    ///      - Per-call duplicate detection (bitmap), fee accumulation, and
    ///        `FeeCollected` event emission are handled here.
    function _collectMatchedItems(
        DecodedQuoteClaim memory claim,
        bytes32 correlationHash,
        FeeWithQuoteRequest[] calldata requests,
        address payable feeRecipient
    ) private returns (uint256 totalCollected) {
        uint256 consumedInTx = 0;
        for (uint256 i = 0; i < requests.length; ++i) {
            (QuoteItem memory item, uint256 itemIndex, bool matched) =
                claim.decodedQuote.findItemForRequest(requests[i]);
            if (!matched) continue;

            uint256 bit = uint256(1) << itemIndex;
            if (consumedInTx & bit != 0) {
                revert DuplicateRequestType(requests[i].quoteType);
            }
            consumedInTx |= bit;
            totalCollected += item.amount;
            _emitFeeCollected(claim, correlationHash, requests[i], item.amount, feeRecipient);
        }
    }

    function _emitFeeCollected(
        DecodedQuoteClaim memory claim,
        bytes32 correlationHash,
        FeeWithQuoteRequest calldata request,
        uint256 amount,
        address payable feeRecipient
    ) private {
        emit FeeCollected(
            msg.sender,
            correlationHash,
            request.quoteType,
            request.quoteArgs,
            claim.refundAddress,
            feeRecipient,
            claim.decodedQuote.feeToken,
            amount,
            claim.decodedQuote.nonce
        );
    }

    /// @dev Recovers the signer from `quote.signature` and requires membership in the trusted signer set.
    ///      Non-65-byte `bytes` signatures revert in `ECDSA.recover` (`ECDSAInvalidSignatureLength`); no separate length check.
    ///      **EIP-712:** `digest` is `keccak256("\x19\x01" || domainSeparator || structHash)` where
    ///      `domainSeparator` binds this contract (`address(this)`) and `block.chainid`, so the same
    ///      signature cannot be replayed on another chain or against another FeeManager deployment.
    ///      `structHash` includes `quote.nonce` (currently required to be 0) for
    ///      EIP-712 domain binding; the field is reserved for future use.
    function _verifySignedQuote(Quote memory quote) private view {
        bytes32 structHash = _quoteStructHash(quote.items, quote.expiry, quote.feeToken, quote.nonce);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        address recovered = ECDSA.recover(digest, quote.signature);
        if (!_isTrustedQuoteSigner(recovered)) revert InvalidQuoteSigner(recovered);
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712TypeHashes.DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this))
        );
    }

    function _hashQuoteItem(QuoteItem memory item) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712TypeHashes.QUOTE_ITEM_TYPEHASH, keccak256(bytes(item.quoteType)), item.quoteArgsHash, item.amount
            )
        );
    }

    function _hashQuoteItems(QuoteItem[] memory items) private pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](items.length);
        for (uint256 i = 0; i < items.length; ++i) {
            hashes[i] = _hashQuoteItem(items[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _quoteStructHash(QuoteItem[] memory items, uint256 expiry, address feeToken, uint256 nonce)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(EIP712TypeHashes.QUOTE_TYPEHASH, _hashQuoteItems(items), expiry, feeToken, nonce));
    }
}
