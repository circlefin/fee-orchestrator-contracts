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

import {EIP712TypeHashes} from "../src/constants/EIP712TypeHashes.sol";
import {QuoteTypes} from "../src/constants/QuoteTypes.sol";
import {Roles} from "../src/constants/Roles.sol";
import {FeeManager} from "../src/contracts/FeeManager.sol";
import {IFeeManager} from "../src/interfaces/IFeeManager.sol";
import {IFeeTaker} from "../src/interfaces/IFeeTaker.sol";
import {QuoteLib} from "../src/libraries/QuoteLib.sol";
import {SignedQuoteLib} from "../src/libraries/SignedQuoteLib.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Test} from "forge-std/Test.sol";

import {MockUSDCBlacklist} from "./mocks/MockUSDCBlacklist.sol";

/// @dev Minimal ERC-20 for testing.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock FeeTaker that accepts fees and tracks calls.
contract MockFeeTaker is IFeeTaker {
    uint256 public nativeFeeReceived;
    uint256 public erc20FeeReceived;
    address public lastBeneficiary;
    bytes8 public lastKitType;
    address public lastToken;

    function protocolFeeAddress() external view override returns (address) {
        return address(this);
    }

    function takeFeeNative(address payable beneficiary, bytes8 kitType) external payable override {
        nativeFeeReceived += msg.value;
        lastBeneficiary = beneficiary;
        lastKitType = kitType;
    }

    function takeFeeERC20(address token, address beneficiary, uint256 fee, bytes8 kitType) external override {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token).transferFrom(msg.sender, address(this), fee);
        erc20FeeReceived += fee;
        lastToken = token;
        lastBeneficiary = beneficiary;
        lastKitType = kitType;
    }
}

/// @dev FeeTaker that always reverts, for testing atomic failure.
contract RevertingFeeTaker is IFeeTaker {
    function protocolFeeAddress() external view override returns (address) {
        return address(this);
    }

    function takeFeeNative(address payable, bytes8) external payable override {
        revert("FeeTaker: reverted");
    }

    function takeFeeERC20(address, address, uint256, bytes8) external pure override {
        revert("FeeTaker: reverted");
    }
}

contract FeeManagerTest is Test {
    FeeManager internal feeManager;
    MockFeeTaker internal mockFeeTaker;
    MockUSDCBlacklist internal mockUsdcBlacklist;

    uint256 internal constant TRUSTED_SIGNER_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    bytes32 internal constant CORRELATION_HASH = keccak256("test-correlation");

    address internal trustedSigner;

    address internal owner = makeAddr("owner");
    address internal callerAdmin = makeAddr("callerAdmin");
    address internal signerAdmin = makeAddr("signerAdmin");
    address internal feeCollectionAdmin = makeAddr("feeCollectionAdmin");
    address internal pauser_ = makeAddr("pauser");
    address internal allowedCaller = makeAddr("allowedCaller");
    address internal refundAddress = makeAddr("refundAddress");

    event FeeCollected(
        address indexed caller,
        bytes32 indexed correlationHash,
        string quoteType,
        string[] quoteArgs,
        address payable refundAddress,
        address payable feeRecipient,
        address feeToken,
        uint256 amount,
        uint256 nonce
    );

    /// @dev Builds a `QuoteClaim` from a signed-quote payload, using this test's `refundAddress`
    ///      EOA as the refund target. Used by every call site that exercises the bytes overload.
    function _claim(bytes memory signedQuote) internal view returns (IFeeManager.QuoteClaim memory) {
        return IFeeManager.QuoteClaim({signedQuote: signedQuote, refundAddress: payable(refundAddress)});
    }

    /// @dev Same as `_claim`, but with an explicit refund-target override (e.g. `address(0)`).
    function _claimWithRefund(bytes memory signedQuote, address payable refundTarget)
        internal
        pure
        returns (IFeeManager.QuoteClaim memory)
    {
        return IFeeManager.QuoteClaim({signedQuote: signedQuote, refundAddress: refundTarget});
    }

    /// @dev Decoded counterpart to `_claim` — bundles a decoded `Quote` with this test's `refundAddress`.
    function _decodedClaim(IFeeManager.Quote memory decoded)
        internal
        view
        returns (IFeeManager.DecodedQuoteClaim memory)
    {
        return IFeeManager.DecodedQuoteClaim({decodedQuote: decoded, refundAddress: payable(refundAddress)});
    }

    event Paused(address account);
    event Unpaused(address account);

    function _deployFeeManagerProxy(address initialOwner) internal returns (FeeManager) {
        FeeManager impl = new FeeManager(address(mockFeeTaker), address(mockUsdcBlacklist));
        bytes memory initData = abi.encodeCall(FeeManager.initialize, (initialOwner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return FeeManager(payable(address(proxy)));
    }

    function _deployFeeManagerProxyWithFeeTaker(address initialOwner, address feeTakerAddr)
        internal
        returns (FeeManager)
    {
        FeeManager impl = new FeeManager(feeTakerAddr, address(mockUsdcBlacklist));
        bytes memory initData = abi.encodeCall(FeeManager.initialize, (initialOwner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return FeeManager(payable(address(proxy)));
    }

    function setUp() public {
        mockFeeTaker = new MockFeeTaker();
        mockUsdcBlacklist = new MockUSDCBlacklist();
        trustedSigner = vm.addr(TRUSTED_SIGNER_PK);
        feeManager = _deployFeeManagerProxy(owner);

        vm.startPrank(owner);
        feeManager.grantRole(Roles.CALLER_ADMIN_ROLE, callerAdmin);
        feeManager.grantRole(Roles.SIGNER_ADMIN_ROLE, signerAdmin);
        feeManager.grantRole(Roles.FEE_COLLECTION_ADMIN_ROLE, feeCollectionAdmin);
        feeManager.grantRole(Roles.PAUSER_ROLE, pauser_);
        vm.stopPrank();

        vm.prank(callerAdmin);
        feeManager.grantRole(Roles.ALLOWED_CALLER_ROLE, allowedCaller);

        vm.prank(signerAdmin);
        feeManager.setTrustedQuoteSigner(trustedSigner, true);
    }

    function _domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712TypeHashes.DOMAIN_TYPEHASH,
                keccak256(bytes("FeeManager")),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
    }

    function _hashQuoteItems(IFeeManager.QuoteItem[] memory items) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](items.length);
        for (uint256 i = 0; i < items.length; ++i) {
            hashes[i] = keccak256(
                abi.encode(
                    EIP712TypeHashes.QUOTE_ITEM_TYPEHASH,
                    keccak256(bytes(items[i].quoteType)),
                    items[i].quoteArgsHash,
                    items[i].amount
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _quoteStructHash(IFeeManager.QuoteItem[] memory items, uint256 expiry, address feeToken, uint256 nonce)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(EIP712TypeHashes.QUOTE_TYPEHASH, _hashQuoteItems(items), expiry, feeToken, nonce));
    }

    function _encodeSignedQuote(
        IFeeManager.QuoteItem[] memory items,
        uint256 expiry,
        address feeToken,
        uint256 nonce,
        uint256 signerPk,
        address verifyingContract
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901", _domainSeparator(verifyingContract), _quoteStructHash(items, expiry, feeToken, nonce)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        IFeeManager.Quote memory q = IFeeManager.Quote({
            items: items, expiry: expiry, feeToken: feeToken, nonce: nonce, signature: abi.encodePacked(r, s, v)
        });
        return abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));
    }

    function _encodeSignedQuoteWithWrongDomain(IFeeManager.QuoteItem[] memory items)
        internal
        view
        returns (bytes memory signedQuote, address recovered)
    {
        uint256 expiry = block.timestamp + 1 days;
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712TypeHashes.DOMAIN_TYPEHASH,
                keccak256(bytes("NotFeeManager")),
                keccak256(bytes("2")),
                block.chainid,
                address(feeManager)
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked(hex"1901", domainSeparator, _quoteStructHash(items, expiry, address(0), 0)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TRUSTED_SIGNER_PK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes32 contractDigest = keccak256(
            abi.encodePacked(
                hex"1901", _domainSeparator(address(feeManager)), _quoteStructHash(items, expiry, address(0), 0)
            )
        );
        // This is the address FeeManager recovers against its own domain, not
        // the trusted signer that produced the wrong-domain signature above.
        recovered = ECDSA.recover(contractDigest, signature);
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: expiry, feeToken: address(0), nonce: 0, signature: signature});
        signedQuote = abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));
    }

    function _encodeSignedQuoteWithVersion(
        IFeeManager.QuoteItem[] memory items,
        uint256 expiry,
        address feeToken,
        uint256 nonce,
        uint256 signerPk,
        address verifyingContract,
        uint8 version
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901", _domainSeparator(verifyingContract), _quoteStructHash(items, expiry, feeToken, nonce)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        IFeeManager.Quote memory q = IFeeManager.Quote({
            items: items, expiry: expiry, feeToken: feeToken, nonce: nonce, signature: abi.encodePacked(r, s, v)
        });
        return abi.encodePacked(version, abi.encode(q));
    }

    function _sliceFrom(bytes memory data, uint256 start) internal pure returns (bytes memory result) {
        require(start < data.length + 1, "slice out of bounds");
        result = new bytes(data.length - start);
        for (uint256 i = 0; i < result.length; ++i) {
            result[i] = data[start + i];
        }
    }

    function _encodeLookupQuote(IFeeManager.QuoteItem[] memory items, address feeToken, uint256 nonce)
        internal
        pure
        returns (bytes memory)
    {
        IFeeManager.Quote memory q = IFeeManager.Quote({
            items: items, expiry: 0, feeToken: feeToken, nonce: nonce, signature: new bytes(65)
        });
        return abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));
    }

    // ───────────────────── SignedQuoteLib wire format version ─────────────────────

    function test_signedQuoteLib_wireFormatVersion_isOne() public pure {
        assertEq(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION, uint8(1));
    }

    // ───────────────────── initialize ─────────────────────

    function test_initialize_setsOwner() public view {
        assertEq(feeManager.owner(), owner);
    }

    function test_initialize_hasNoPendingOwner() public view {
        assertEq(feeManager.pendingOwner(), address(0));
    }

    function test_initialize_grantsDefaultAdminRole() public view {
        assertTrue(feeManager.hasRole(feeManager.DEFAULT_ADMIN_ROLE(), owner));
    }

    function test_initialize_setsCallerAdminAsRoleAdminForAllowedCaller() public view {
        assertEq(feeManager.getRoleAdmin(Roles.ALLOWED_CALLER_ROLE), Roles.CALLER_ADMIN_ROLE);
    }

    function test_proxy_initializeRevertsWhenCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        feeManager.initialize(makeAddr("attacker"));
    }

    // ───────────────────── collectFeesWithQuote ─────────────────────

    function test_collectFeesWithQuote_emptyRequests_withoutTrustedSigner_succeeds() public {
        FeeManager fresh = _deployFeeManagerProxyWithFeeTaker(owner, address(mockFeeTaker));
        vm.startPrank(owner);
        fresh.grantRole(Roles.CALLER_ADMIN_ROLE, owner);
        fresh.grantRole(Roles.ALLOWED_CALLER_ROLE, allowedCaller);
        vm.stopPrank();

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);

        vm.prank(allowedCaller);
        uint256 amount = fresh.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(""));
        assertEq(amount, 0);
    }

    function test_collectFeesWithQuote_emptyRequests() public {
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);

        vm.prank(allowedCaller);
        uint256 amount = feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(""));

        assertEq(amount, 0);
    }

    function test_collectFeesWithQuote_emptyRequests_revertsIfNativeSent() public {
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);
        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(FeeManager.IncorrectNativePayment.selector, uint256(0), uint256(0.5 ether))
        );
        feeManager.collectFeesWithQuote{value: 0.5 ether}(CORRELATION_HASH, requests, _claim(""));
    }

    function test_collectFeesWithQuote_succeedsWhenQuoteNotExpired_timestampMode() public {
        string[] memory args = new string[](2);
        args[0] = "chain:137";
        args[1] = "token:USDC";
        bytes32 argsHash = keccak256(abi.encode(args));

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: QuoteTypes.FORWARD, quoteArgsHash: argsHash, amount: 0.25 ether});
        // Mode byte 0x00: deadline is a Unix timestamp sufficiently in the future.
        uint256 expiry = block.timestamp + 1 days;
        bytes memory signedQuote =
            _encodeSignedQuote(items, expiry, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.expectEmit(true, true, false, true);
        emit FeeCollected(
            allowedCaller,
            CORRELATION_HASH,
            QuoteTypes.FORWARD,
            args,
            payable(refundAddress),
            payable(address(mockFeeTaker)),
            address(0),
            0.25 ether,
            0
        );

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        uint256 amount =
            feeManager.collectFeesWithQuote{value: 0.25 ether}(CORRELATION_HASH, requests, _claim(signedQuote));

        assertEq(amount, 0.25 ether);
        assertEq(address(feeManager).balance, 0, "FeeManager should not hold funds");
        assertEq(address(mockFeeTaker).balance, 0.25 ether, "FeeTaker should receive native fees");
        assertEq(mockFeeTaker.nativeFeeReceived(), 0.25 ether);
        assertEq(
            mockFeeTaker.lastBeneficiary(),
            mockFeeTaker.protocolFeeAddress(),
            "beneficiary should be protocolFeeAddress"
        );
    }

    function test_collectFeesWithQuote_succeedsWhenQuoteNotExpired_blockNumberMode() public {
        string[] memory args = new string[](2);
        args[0] = "chain:137";
        args[1] = "token:USDC";
        bytes32 argsHash = keccak256(abi.encode(args));

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: QuoteTypes.FORWARD, quoteArgsHash: argsHash, amount: 0.25 ether});
        // Mode byte 0x01: deadline is a block height sufficiently ahead of the current block.
        uint256 expiry = (uint256(1) << 248) | (block.number + 1000);
        bytes memory signedQuote =
            _encodeSignedQuote(items, expiry, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.expectEmit(true, true, false, true);
        emit FeeCollected(
            allowedCaller,
            CORRELATION_HASH,
            QuoteTypes.FORWARD,
            args,
            payable(refundAddress),
            payable(address(mockFeeTaker)),
            address(0),
            0.25 ether,
            0
        );

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        uint256 amount =
            feeManager.collectFeesWithQuote{value: 0.25 ether}(CORRELATION_HASH, requests, _claim(signedQuote));

        assertEq(amount, 0.25 ether);
        assertEq(address(feeManager).balance, 0, "FeeManager should not hold funds");
        assertEq(mockFeeTaker.nativeFeeReceived(), 0.25 ether);
    }

    function test_collectFeesWithQuote_emitsFeeCollectedPerMatchedRequest() public {
        string[] memory args0 = new string[](1);
        args0[0] = "arg0";
        string[] memory args1 = new string[](1);
        args1[0] = "arg1";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args0)), amount: 10
        });
        items[1] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: keccak256(abi.encode(args1)), amount: 20
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](2);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args0, required: true});
        requests[1] =
            IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.PRE_FINALITY, quoteArgs: args1, required: false});

        vm.expectEmit(true, true, false, true);
        emit FeeCollected(
            allowedCaller,
            CORRELATION_HASH,
            QuoteTypes.FORWARD,
            args0,
            payable(refundAddress),
            payable(address(mockFeeTaker)),
            address(0),
            10,
            0
        );
        vm.expectEmit(true, true, false, true);
        emit FeeCollected(
            allowedCaller,
            CORRELATION_HASH,
            QuoteTypes.PRE_FINALITY,
            args1,
            payable(refundAddress),
            payable(address(mockFeeTaker)),
            address(0),
            20,
            0
        );

        vm.deal(allowedCaller, 100);
        vm.prank(allowedCaller);
        uint256 amount = feeManager.collectFeesWithQuote{value: 30}(CORRELATION_HASH, requests, _claim(signedQuote));

        assertEq(amount, 30);
    }

    function test_collectFeesWithQuote_revertsSignedQuoteDecodeFailed() public {
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        string[] memory args = new string[](0);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: "X", quoteArgs: args, required: true});

        vm.prank(allowedCaller);
        vm.expectRevert(IFeeManager.SignedQuoteDecodeFailed.selector);
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(hex"01deadbeef"));
    }

    function test_collectFeesWithQuote_revertsUnsupportedQuoteVersion_zero() public {
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        string[] memory args = new string[](0);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: "X", quoteArgs: args, required: true});

        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.UnsupportedQuoteVersion.selector, uint8(0)));
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(hex"00aabbccdd"));
    }

    function test_collectFeesWithQuote_revertsUnsupportedQuoteVersion_future() public {
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 1
        });
        bytes memory signedQuote = _encodeSignedQuoteWithVersion(
            items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager), 2
        );

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.UnsupportedQuoteVersion.selector, uint8(2)));
        feeManager.collectFeesWithQuote{value: 1}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_revertsSignedQuoteDecodeFailed_emptyPayload() public {
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        string[] memory args = new string[](0);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: "X", quoteArgs: args, required: true});

        vm.prank(allowedCaller);
        vm.expectRevert(IFeeManager.SignedQuoteDecodeFailed.selector);
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(""));
    }

    /// @dev Complements `QuoteLib.t.sol`: ensures `collectFeesWithQuote` applies expiry checks on the full path.
    function test_collectFeesWithQuote_revertsQuoteExpired_timestampMode() public {
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 1
        });
        uint256 expiry = block.timestamp - 1;
        bytes memory signedQuote =
            _encodeSignedQuote(items, expiry, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(QuoteLib.QuoteExpired.selector, uint8(0), expiry, block.timestamp));
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_revertsQuoteExpired_blockNumberMode() public {
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 1
        });
        uint256 deadline = block.number - 1;
        uint256 expiry = (uint256(1) << 248) | deadline;
        bytes memory signedQuote =
            _encodeSignedQuote(items, expiry, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(QuoteLib.QuoteExpired.selector, uint8(1), deadline, block.number));
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_revertsUnsupportedExpiryMode() public {
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 1
        });
        uint256 expiry = (uint256(0x02) << 248) | uint256(block.timestamp + 1 days);
        bytes memory signedQuote =
            _encodeSignedQuote(items, expiry, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(QuoteLib.UnsupportedExpiryMode.selector, uint8(0x02)));
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_emptyQuoteSucceedsForNonRequiredRequests() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        string[] memory args = new string[](0);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: false});

        vm.prank(allowedCaller);
        uint256 amount = feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
        assertEq(amount, 0);
    }

    function test_collectFeesWithQuote_revertsDuplicateRequestType() public {
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 3
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](2);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});
        requests[1] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 20);
        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.DuplicateRequestType.selector, QuoteTypes.FORWARD));
        feeManager.collectFeesWithQuote{value: 6}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_revertsInvalidQuoteSigner_tamperedAmount() public {
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 100
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.Quote memory tampered = abi.decode(_sliceFrom(signedQuote, 1), (IFeeManager.Quote));
        tampered.items[0].amount = 999;
        bytes memory tamperedEncoded =
            abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(tampered));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 2000);
        vm.prank(allowedCaller);
        vm.expectRevert();
        feeManager.collectFeesWithQuote{value: 999}(CORRELATION_HASH, requests, _claim(tamperedEncoded));
    }

    function test_collectFeesWithQuote_revertsInvalidQuoteSigner_wrongKey() public {
        uint256 otherPk = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
        address otherAddr = vm.addr(otherPk);
        assertTrue(otherAddr != trustedSigner);

        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 1
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, otherPk, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 10);
        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(FeeManager.InvalidQuoteSigner.selector, otherAddr));
        feeManager.collectFeesWithQuote{value: 1}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_revertsInvalidQuoteSigner_wrongDomainNameVersion() public {
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 1
        });
        (bytes memory signedQuote, address recovered) = _encodeSignedQuoteWithWrongDomain(items);

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 10);
        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(FeeManager.InvalidQuoteSigner.selector, recovered));
        feeManager.collectFeesWithQuote{value: 1}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_domainSeparator_constants_matchDocumentedPreimages() public pure {
        assertEq(keccak256(bytes("FeeManager")), 0x42e3570c507db8e472a4592e53f4b6df78eb7c8a8d593e718bb47b707f2c6a90);
        assertEq(keccak256(bytes("1")), 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6);
    }

    function test_collectFeesWithQuote_revertsRequiredFeeNotInQuote() public {
        string[] memory preFinArgs = new string[](1);
        preFinArgs[0] = "x";
        string[] memory forwardArgs = new string[](1);
        forwardArgs[0] = "y";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: keccak256(abi.encode(preFinArgs)), amount: 1
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] =
            IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: forwardArgs, required: true});
        bytes32 wantedHash = keccak256(abi.encode(forwardArgs));

        vm.prank(allowedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeManager.RequiredFeeNotInQuote.selector, QuoteTypes.FORWARD, wantedHash)
        );
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_revertsQuoteArgsMismatch() public {
        string[] memory argsWanted = new string[](1);
        argsWanted[0] = "need-this";
        string[] memory argsInQuote = new string[](1);
        argsInQuote[0] = "other";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(argsInQuote)), amount: 1
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] =
            IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: argsWanted, required: true});
        bytes32 wantedHash = keccak256(abi.encode(argsWanted));

        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.QuoteArgsMismatch.selector, QuoteTypes.FORWARD, wantedHash));
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_revertsQuoteArgsMismatch_whenNotRequired() public {
        string[] memory argsWanted = new string[](1);
        argsWanted[0] = "need-this";
        string[] memory argsInQuote = new string[](1);
        argsInQuote[0] = "other";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(argsInQuote)), amount: 1
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] =
            IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: argsWanted, required: false});
        bytes32 wantedHash = keccak256(abi.encode(argsWanted));

        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.QuoteArgsMismatch.selector, QuoteTypes.FORWARD, wantedHash));
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_optionalRequest_skipsWhenNoMatch() public {
        string[] memory inQuote = new string[](1);
        inQuote[0] = "only";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(inQuote)), amount: 5
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        string[] memory missingArgs = new string[](1);
        missingArgs[0] = "missing";
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgs: missingArgs, required: false
        });

        vm.prank(allowedCaller);
        uint256 amount = feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
        assertEq(amount, 0);
    }

    function test_collectFeesWithQuote_partialMatch_onlyMatchedEmitEvents() public {
        string[] memory a0 = new string[](1);
        a0[0] = "m0";
        string[] memory a1 = new string[](1);
        a1[0] = "m1";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(a0)), amount: 7});
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](2);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: a0, required: true});
        requests[1] = IFeeManager.FeeWithQuoteRequest({quoteType: "OTHER", quoteArgs: a1, required: false});

        vm.expectEmit(true, true, false, true);
        emit FeeCollected(
            allowedCaller,
            CORRELATION_HASH,
            QuoteTypes.FORWARD,
            a0,
            payable(refundAddress),
            payable(address(mockFeeTaker)),
            address(0),
            7,
            0
        );

        vm.deal(allowedCaller, 100);
        vm.prank(allowedCaller);
        uint256 amount = feeManager.collectFeesWithQuote{value: 7}(CORRELATION_HASH, requests, _claim(signedQuote));
        assertEq(amount, 7);
    }

    function test_collectFeesWithQuote_argsHashMismatch_sameQuoteType_revertsQuoteArgsMismatch() public {
        string[] memory inQuote = new string[](1);
        inQuote[0] = "in-quote";
        string[] memory wrongArgs = new string[](1);
        wrongArgs[0] = "different";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(inQuote)), amount: 1
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] =
            IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: wrongArgs, required: true});
        bytes32 wrongHash = keccak256(abi.encode(wrongArgs));

        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.QuoteArgsMismatch.selector, QuoteTypes.FORWARD, wrongHash));
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_e2e_signEncodeSubmit() public {
        string[] memory args = new string[](1);
        args[0] = "e2e";
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 42
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 hours, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 100);
        vm.prank(allowedCaller);
        uint256 out = feeManager.collectFeesWithQuote{value: 42}(CORRELATION_HASH, requests, _claim(signedQuote));
        assertEq(out, 42);
        assertEq(address(feeManager).balance, 0);
        assertEq(address(mockFeeTaker).balance, 42);
    }

    // ───────────────────── collectFeesWithQuote (decoded `Quote` overload) ─────────────────────

    function test_collectFeesWithQuote_decodedQuote_native_happyPath() public {
        string[] memory args = new string[](1);
        args[0] = "e2e";
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 42
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 hours, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 100);
        vm.prank(allowedCaller);
        uint256 out = feeManager.collectFeesWithQuote{value: 42}(CORRELATION_HASH, requests, _decodedClaim(decoded));
        assertEq(out, 42);
        assertEq(address(feeManager).balance, 0);
        assertEq(address(mockFeeTaker).balance, 42);
    }

    function test_collectFeesWithQuote_decodedQuote_erc20_happyPath() public {
        MockERC20 token = new MockERC20();
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 100e18
        });
        bytes memory signedQuote = _encodeSignedQuote(
            items, block.timestamp + 1 days, address(token), 0, TRUSTED_SIGNER_PK, address(feeManager)
        );
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        token.mint(allowedCaller, 100e18);
        vm.prank(allowedCaller);
        token.approve(address(feeManager), 100e18);

        vm.prank(allowedCaller);
        uint256 amount = feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _decodedClaim(decoded));
        assertEq(amount, 100e18);
        assertEq(token.balanceOf(address(feeManager)), 0, "FeeManager should not hold ERC-20 funds");
        assertEq(token.balanceOf(address(mockFeeTaker)), 100e18, "FeeTaker should receive ERC-20 fees");
        assertEq(mockFeeTaker.erc20FeeReceived(), 100e18);
        assertEq(
            token.allowance(address(feeManager), address(mockFeeTaker)),
            0,
            "FeeManager should have zero residual allowance to FeeTaker"
        );
    }

    function test_collectFeesWithQuote_decodedQuote_emptyRequests_returnsZero() public {
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);
        IFeeManager.Quote memory dummy = IFeeManager.Quote({
            items: new IFeeManager.QuoteItem[](0), expiry: 0, feeToken: address(0), nonce: 0, signature: ""
        });

        vm.prank(allowedCaller);
        uint256 amount = feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _decodedClaim(dummy));
        assertEq(amount, 0);
    }

    function test_collectFeesWithQuote_decodedQuote_emptyRequests_revertsIfNativeSent() public {
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);
        IFeeManager.Quote memory dummy = IFeeManager.Quote({
            items: new IFeeManager.QuoteItem[](0), expiry: 0, feeToken: address(0), nonce: 0, signature: ""
        });
        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(FeeManager.IncorrectNativePayment.selector, uint256(0), uint256(0.5 ether))
        );
        feeManager.collectFeesWithQuote{value: 0.5 ether}(CORRELATION_HASH, requests, _decodedClaim(dummy));
    }

    /// @dev Exercises the post-match `else if (msg.value != 0)` branch in `_collectFeesWithQuoteDecoded`:
    ///      requests are non-empty (so the early-return path is bypassed), but the quote contains no
    ///      matching items (so `totalCollected == 0`), and `msg.value > 0` must trigger the revert.
    function test_collectFeesWithQuote_decodedQuote_noMatchedItems_revertsIfNativeSent() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: "OTHER", quoteArgsHash: bytes32(0), amount: 0});
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({
            quoteType: QuoteTypes.FORWARD, quoteArgs: new string[](0), required: false
        });

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(FeeManager.IncorrectNativePayment.selector, uint256(0), uint256(0.25 ether))
        );
        feeManager.collectFeesWithQuote{value: 0.25 ether}(CORRELATION_HASH, requests, _decodedClaim(decoded));
    }

    function test_collectFeesWithQuote_decodedQuote_revertsIfSignatureNot65Bytes() public {
        string[] memory args = new string[](1);
        args[0] = "e2e";
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 42
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 hours, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);
        decoded.signature = new bytes(64);

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, uint256(64)));
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _decodedClaim(decoded));
    }

    function test_collectFeesWithQuote_erc20_transferFromCaller() public {
        MockERC20 token = new MockERC20();
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 100e18
        });
        bytes memory signedQuote = _encodeSignedQuote(
            items, block.timestamp + 1 days, address(token), 0, TRUSTED_SIGNER_PK, address(feeManager)
        );

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        token.mint(allowedCaller, 100e18);
        vm.prank(allowedCaller);
        token.approve(address(feeManager), 100e18);

        vm.prank(allowedCaller);
        uint256 amount = feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
        assertEq(amount, 100e18);
        assertEq(token.balanceOf(address(feeManager)), 0, "FeeManager should not hold ERC-20 funds");
        assertEq(token.balanceOf(address(mockFeeTaker)), 100e18, "FeeTaker should receive ERC-20 fees");
        assertEq(mockFeeTaker.erc20FeeReceived(), 100e18);
        assertEq(
            mockFeeTaker.lastBeneficiary(),
            mockFeeTaker.protocolFeeAddress(),
            "beneficiary should be protocolFeeAddress"
        );
        assertEq(
            token.allowance(address(feeManager), address(mockFeeTaker)),
            0,
            "FeeManager should have zero residual allowance to FeeTaker"
        );
    }

    function test_collectFeesWithQuote_revertsInsufficientNativePayment() public {
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 100
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 200);
        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(FeeManager.IncorrectNativePayment.selector, uint256(100), uint256(50)));
        feeManager.collectFeesWithQuote{value: 50}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_revertsNativeOverpayment() public {
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 10
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 200);
        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(FeeManager.IncorrectNativePayment.selector, uint256(10), uint256(11)));
        feeManager.collectFeesWithQuote{value: 11}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_revertsWithoutErc20Approval() public {
        MockERC20 token = new MockERC20();
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 1e18
        });
        bytes memory signedQuote = _encodeSignedQuote(
            items, block.timestamp + 1 days, address(token), 0, TRUSTED_SIGNER_PK, address(feeManager)
        );

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        token.mint(allowedCaller, 10e18);

        vm.prank(allowedCaller);
        vm.expectRevert();
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_revertsForBlacklistedRefundAddress() public {
        // Non-zero refundAddress is screened against the configured USDC blacklist.
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);
        address blocked = makeAddr("blockedRefund");
        mockUsdcBlacklist.setBlacklisted(blocked, true);

        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.DenylistedRefundAddress.selector, blocked));
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claimWithRefund("", payable(blocked)));
    }

    function test_collectFeesWithQuote_zeroRefundAddress_skipsBlacklistScreen() public {
        // Sanity: a zero refundAddress must never trigger the blacklist screen, even if address(0)
        // were to be marked blacklisted by a misconfigured backing contract.
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);
        mockUsdcBlacklist.setBlacklisted(address(0), true);

        vm.prank(allowedCaller);
        uint256 amount =
            feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claimWithRefund("", payable(address(0))));
        assertEq(amount, 0);
    }

    function test_collectFeesWithQuote_revertsForNonAllowedCaller() public {
        address stranger = makeAddr("stranger");
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.ALLOWED_CALLER_ROLE
            )
        );
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(""));
    }

    function test_collectFeesWithQuote_revertsTooManyQuoteItems() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](257);
        for (uint256 i = 0; i < 257; ++i) {
            items[i] = IFeeManager.QuoteItem({quoteType: "X", quoteArgsHash: bytes32(i), amount: 0});
        }
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));
        string[] memory skipArgs = new string[](1);
        skipArgs[0] = "n/a";
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: "SKIP", quoteArgs: skipArgs, required: false});

        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.TooManyQuoteItems.selector, uint256(257)));
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_nonZeroNonce_reverts() public {
        uint256 nonce = 7;
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 5
        });
        bytes memory signedQuote = _encodeSignedQuote(
            items, block.timestamp + 1 days, address(0), nonce, TRUSTED_SIGNER_PK, address(feeManager)
        );
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 20);
        vm.prank(allowedCaller);
        vm.expectRevert(abi.encodeWithSelector(QuoteLib.NonZeroNonce.selector, nonce));
        feeManager.collectFeesWithQuote{value: 5}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_nonceZero_allowsRepeatCollection() public {
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 2
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));
        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 10);
        vm.prank(allowedCaller);
        feeManager.collectFeesWithQuote{value: 2}(CORRELATION_HASH, requests, _claim(signedQuote));
        vm.prank(allowedCaller);
        feeManager.collectFeesWithQuote{value: 2}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    // ───────────────────── AccessControl roles ─────────────────────

    function test_grantRole_callerAdminCanGrantAllowedCaller() public {
        address newCaller = makeAddr("newCaller");
        vm.prank(callerAdmin);
        feeManager.grantRole(Roles.ALLOWED_CALLER_ROLE, newCaller);
        assertTrue(feeManager.hasRole(Roles.ALLOWED_CALLER_ROLE, newCaller));
    }

    function test_grantRole_callerAdminCanRevokeAllowedCaller() public {
        vm.prank(callerAdmin);
        feeManager.revokeRole(Roles.ALLOWED_CALLER_ROLE, allowedCaller);
        assertFalse(feeManager.hasRole(Roles.ALLOWED_CALLER_ROLE, allowedCaller));
    }

    function test_grantRole_defaultAdminCanGrantCallerAdmin() public {
        address newCallerAdmin = makeAddr("newCallerAdmin");
        vm.prank(owner);
        feeManager.grantRole(Roles.CALLER_ADMIN_ROLE, newCallerAdmin);
        assertTrue(feeManager.hasRole(Roles.CALLER_ADMIN_ROLE, newCallerAdmin));
    }

    function test_grantRole_defaultAdminCanGrantSignerAdmin() public {
        address newSignerAdmin = makeAddr("newSignerAdmin");
        vm.prank(owner);
        feeManager.grantRole(Roles.SIGNER_ADMIN_ROLE, newSignerAdmin);
        assertTrue(feeManager.hasRole(Roles.SIGNER_ADMIN_ROLE, newSignerAdmin));
    }

    function test_grantRole_defaultAdminCanGrantPauserRole() public {
        address newPauser = makeAddr("newPauser");
        vm.prank(owner);
        feeManager.grantRole(Roles.PAUSER_ROLE, newPauser);
        assertTrue(feeManager.hasRole(Roles.PAUSER_ROLE, newPauser));
    }

    function test_grantRole_strangerCannotGrantAllowedCaller() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.CALLER_ADMIN_ROLE
            )
        );
        feeManager.grantRole(Roles.ALLOWED_CALLER_ROLE, stranger);
    }

    function test_multipleHoldersOfSameRole() public {
        address pauser2 = makeAddr("pauser2");
        vm.prank(owner);
        feeManager.grantRole(Roles.PAUSER_ROLE, pauser2);

        assertTrue(feeManager.hasRole(Roles.PAUSER_ROLE, pauser_));
        assertTrue(feeManager.hasRole(Roles.PAUSER_ROLE, pauser2));

        vm.prank(pauser2);
        feeManager.pause();
        assertTrue(feeManager.paused());
    }

    function test_revokedCallerCannotCollectFees() public {
        vm.prank(callerAdmin);
        feeManager.revokeRole(Roles.ALLOWED_CALLER_ROLE, allowedCaller);

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);
        vm.prank(allowedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, allowedCaller, Roles.ALLOWED_CALLER_ROLE
            )
        );
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(""));
    }

    // ───────────────────── trusted quote signers (integration) ─────────────────────

    function test_setTrustedQuoteSigner_onlySignerAdmin() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, owner, Roles.SIGNER_ADMIN_ROLE
            )
        );
        feeManager.setTrustedQuoteSigner(trustedSigner, true);

        vm.prank(signerAdmin);
        feeManager.setTrustedQuoteSigner(trustedSigner, true);
        assertTrue(feeManager.isTrustedQuoteSigner(trustedSigner));
    }

    // ───────────────────── fee collection address (integration) ─────────────────────

    event FeeCollectionAddressSet(address indexed feeCollectionAddress);

    function test_feeCollectionAddress_zeroByDefault_andUsesProtocolFeeAddress() public {
        assertEq(feeManager.feeCollectionAddress(), address(0));

        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 1 ether
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 2 ether);
        vm.prank(allowedCaller);
        feeManager.collectFeesWithQuote{value: 1 ether}(CORRELATION_HASH, requests, _claim(signedQuote));

        assertEq(mockFeeTaker.lastBeneficiary(), mockFeeTaker.protocolFeeAddress());
    }

    function test_setFeeCollectionAddress_onlyFeeCollectionAdmin() public {
        address payable customCollector = payable(makeAddr("customCollector"));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, owner, Roles.FEE_COLLECTION_ADMIN_ROLE
            )
        );
        feeManager.setFeeCollectionAddress(customCollector);

        vm.prank(feeCollectionAdmin);
        feeManager.setFeeCollectionAddress(customCollector);
        assertEq(feeManager.feeCollectionAddress(), customCollector);
    }

    function test_setFeeCollectionAddress_emitsEvent() public {
        address payable customCollector = payable(makeAddr("customCollector"));

        vm.expectEmit(true, false, false, true);
        emit FeeCollectionAddressSet(customCollector);
        vm.prank(feeCollectionAdmin);
        feeManager.setFeeCollectionAddress(customCollector);
    }

    function test_grantRole_defaultAdminCanGrantFeeCollectionAdmin() public {
        address newFeeCollectionAdmin = makeAddr("newFeeCollectionAdmin");
        vm.prank(owner);
        feeManager.grantRole(Roles.FEE_COLLECTION_ADMIN_ROLE, newFeeCollectionAdmin);
        assertTrue(feeManager.hasRole(Roles.FEE_COLLECTION_ADMIN_ROLE, newFeeCollectionAdmin));
    }

    function test_collectFeesWithQuote_native_usesConfiguredFeeCollectionAddress() public {
        address payable customCollector = payable(makeAddr("customCollector"));
        vm.prank(feeCollectionAdmin);
        feeManager.setFeeCollectionAddress(customCollector);

        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 0.5 ether
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        feeManager.collectFeesWithQuote{value: 0.5 ether}(CORRELATION_HASH, requests, _claim(signedQuote));

        assertEq(
            mockFeeTaker.lastBeneficiary(),
            customCollector,
            "FeeTaker should receive the configured fee collection address"
        );
        assertTrue(
            mockFeeTaker.lastBeneficiary() != mockFeeTaker.protocolFeeAddress(),
            "override must not equal protocolFeeAddress"
        );
    }

    /// @dev Verifies the `feeRecipient` field on `FeeCollected` mirrors the resolved beneficiary:
    ///      the configured override when set, not the FeeTaker's `protocolFeeAddress()`.
    function test_collectFeesWithQuote_native_feeCollectedEvent_emitsConfiguredFeeRecipient() public {
        address payable customCollector = payable(makeAddr("customCollectorEvt"));
        vm.prank(feeCollectionAdmin);
        feeManager.setFeeCollectionAddress(customCollector);

        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 0.1 ether
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.expectEmit(true, true, false, true);
        emit FeeCollected(
            allowedCaller,
            CORRELATION_HASH,
            QuoteTypes.FORWARD,
            args,
            payable(refundAddress),
            customCollector,
            address(0),
            0.1 ether,
            0
        );

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        feeManager.collectFeesWithQuote{value: 0.1 ether}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_erc20_usesConfiguredFeeCollectionAddress() public {
        address payable customCollector = payable(makeAddr("customCollector"));
        vm.prank(feeCollectionAdmin);
        feeManager.setFeeCollectionAddress(customCollector);

        MockERC20 token = new MockERC20();
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 25e18
        });
        bytes memory signedQuote = _encodeSignedQuote(
            items, block.timestamp + 1 days, address(token), 0, TRUSTED_SIGNER_PK, address(feeManager)
        );

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        token.mint(allowedCaller, 25e18);
        vm.prank(allowedCaller);
        token.approve(address(feeManager), 25e18);

        vm.prank(allowedCaller);
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));

        assertEq(
            mockFeeTaker.lastBeneficiary(),
            customCollector,
            "FeeTaker should receive the configured fee collection address"
        );
    }

    function test_collectFeesWithQuote_clearedOverride_revertsToProtocolFeeAddress() public {
        address payable customCollector = payable(makeAddr("customCollector"));
        vm.startPrank(feeCollectionAdmin);
        feeManager.setFeeCollectionAddress(customCollector);
        feeManager.setFeeCollectionAddress(payable(address(0)));
        vm.stopPrank();
        assertEq(feeManager.feeCollectionAddress(), address(0));

        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 0.1 ether
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        feeManager.collectFeesWithQuote{value: 0.1 ether}(CORRELATION_HASH, requests, _claim(signedQuote));

        assertEq(mockFeeTaker.lastBeneficiary(), mockFeeTaker.protocolFeeAddress());
    }

    function test_collectFeesWithQuote_overrideUsedAcrossMultipleCalls() public {
        address payable customCollector = payable(makeAddr("customCollector"));
        vm.prank(feeCollectionAdmin);
        feeManager.setFeeCollectionAddress(customCollector);

        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 0.1 ether
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        feeManager.collectFeesWithQuote{value: 0.1 ether}(CORRELATION_HASH, requests, _claim(signedQuote));
        assertEq(mockFeeTaker.lastBeneficiary(), customCollector);

        vm.prank(allowedCaller);
        feeManager.collectFeesWithQuote{value: 0.1 ether}(CORRELATION_HASH, requests, _claim(signedQuote));
        assertEq(mockFeeTaker.lastBeneficiary(), customCollector);
    }

    /// @dev Belt-and-suspenders: pause must not silently bypass the override path.
    function test_collectFeesWithQuote_overrideRespectedAfterUnpause() public {
        address payable customCollector = payable(makeAddr("customCollector"));
        vm.prank(feeCollectionAdmin);
        feeManager.setFeeCollectionAddress(customCollector);

        vm.prank(pauser_);
        feeManager.pause();
        vm.prank(pauser_);
        feeManager.unpause();

        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 0.1 ether
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        feeManager.collectFeesWithQuote{value: 0.1 ether}(CORRELATION_HASH, requests, _claim(signedQuote));
        assertEq(mockFeeTaker.lastBeneficiary(), customCollector);
    }

    // ───────────────────── decodeQuote (public endpoint) ─────────────────────

    function test_decodeQuote_validV1_returnsQuote() public view {
        string[] memory args = new string[](1);
        args[0] = "hello";
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 42
        });
        bytes memory sig65 = new bytes(65);
        sig65[0] = 0xaa;
        sig65[1] = 0xbb;
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: 999, feeToken: address(0), nonce: 7, signature: sig65});
        bytes memory signedQuote = abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));

        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);
        assertEq(decoded.items.length, 1);
        assertEq(decoded.items[0].amount, 42);
        assertEq(decoded.expiry, 999);
        assertEq(decoded.nonce, 7);
        assertEq(decoded.feeToken, address(0));
        assertEq(decoded.signature.length, 65);
        assertEq(uint8(decoded.signature[0]), uint8(0xaa));
        assertEq(uint8(decoded.signature[1]), uint8(0xbb));
    }

    /// @dev `SignedQuoteLib` must stay byte-for-byte compatible with `FeeManager.decodeQuote` (used by TMWF in-process).
    function test_signedQuoteLib_decode_matches_feeManager_decodeQuote() public view {
        string[] memory args = new string[](1);
        args[0] = "hello";
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 42
        });
        bytes memory sig65 = new bytes(65);
        sig65[0] = 0xaa;
        sig65[1] = 0xbb;
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: 999, feeToken: address(0), nonce: 7, signature: sig65});
        bytes memory signedQuote = abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));

        IFeeManager.Quote memory fromLib = this._subjectSignedQuoteLibDecode(signedQuote);
        IFeeManager.Quote memory fromFm = feeManager.decodeQuote(signedQuote);
        assertEq(keccak256(abi.encode(fromLib)), keccak256(abi.encode(fromFm)));
    }

    function _subjectSignedQuoteLibDecode(bytes calldata signedQuote) external pure returns (IFeeManager.Quote memory) {
        return SignedQuoteLib.decodeQuote(signedQuote);
    }

    function test_decodeQuote_revertsOnEmptyPayload() public {
        vm.expectRevert(IFeeManager.SignedQuoteDecodeFailed.selector);
        feeManager.decodeQuote("");
    }

    function test_decodeQuote_revertsUnsupportedQuoteVersion_zero() public {
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.UnsupportedQuoteVersion.selector, uint8(0)));
        feeManager.decodeQuote(hex"00aabbccdd");
    }

    function test_decodeQuote_revertsUnsupportedQuoteVersion_future() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});
        bytes memory signedQuote = abi.encodePacked(uint8(2), abi.encode(q));

        vm.expectRevert(abi.encodeWithSelector(IFeeManager.UnsupportedQuoteVersion.selector, uint8(2)));
        feeManager.decodeQuote(signedQuote);
    }

    function test_decodeQuote_revertsOnGarbageAfterValidVersion() public {
        vm.expectRevert(IFeeManager.SignedQuoteDecodeFailed.selector);
        feeManager.decodeQuote(hex"01deadbeef");
    }

    function test_decodeQuote_revertsWhenTailShorterThanMinimalAbiQuote() public {
        // Version 1 + 351-byte tail: below MIN_ABI_ENCODED_QUOTE_TAIL_BYTES (352 for empty items + 65-byte sig).
        bytes memory tooShort = bytes.concat(hex"01", new bytes(351));
        vm.expectRevert(IFeeManager.SignedQuoteDecodeFailed.selector);
        feeManager.decodeQuote(tooShort);
    }

    /// @dev Smallest ABI-encoded `Quote` that passes `SignedQuoteLib`: empty `items`, 65-byte `signature` (secp256k1).
    function test_decodeQuote_minimalEncodedQuote_decodes() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        bytes memory sig65 = new bytes(65);
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: sig65});
        assertEq(abi.encode(q).length, 352, "sanity: minimal abi.encode(Quote) with 65-byte signature");
        bytes memory signedQuote = abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));
        assertEq(signedQuote.length, 353);

        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);
        assertEq(decoded.items.length, 0);
        assertEq(decoded.expiry, 0);
        assertEq(decoded.feeToken, address(0));
        assertEq(decoded.nonce, 0);
        assertEq(decoded.signature.length, 65);
    }

    function test_decodeQuote_revertsWhenSignatureNot65Bytes() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        // Same ABI tail size as a 65-byte signature (padded dynamic slot), but wrong length for `ECDSA.recover`.
        bytes memory sig66 = new bytes(66);
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: sig66});
        assertEq(abi.encode(q).length, 352);
        bytes memory signedQuote = abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));
        vm.expectRevert(IFeeManager.SignedQuoteDecodeFailed.selector);
        feeManager.decodeQuote(signedQuote);
    }

    // ───────────────────── getQuoteItem / getQuoteTotal ─────────────────────

    function test_getQuoteItem_emptyBytes_returnsNotFound() public view {
        (IFeeManager.QuoteItem memory item, bool found) = feeManager.getQuoteItem("", QuoteTypes.FORWARD);
        assertFalse(found);
        assertEq(item.amount, 0);
    }

    function test_getQuoteItem_findsFirstMatchingQuoteType() public view {
        string[] memory a0 = new string[](1);
        a0[0] = "x";
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({quoteType: "OTHER", quoteArgsHash: bytes32(0), amount: 1});
        items[1] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(a0)), amount: 99
        });
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: new bytes(65)});
        bytes memory signedQuote = abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));

        (IFeeManager.QuoteItem memory item, bool found) = feeManager.getQuoteItem(signedQuote, QuoteTypes.FORWARD);
        assertTrue(found);
        assertEq(item.amount, 99);
    }

    function test_getQuoteItem_revertsUnsupportedQuoteVersion() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: QuoteTypes.FORWARD, quoteArgsHash: bytes32(0), amount: 1});
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});
        bytes memory signedQuote = abi.encodePacked(uint8(2), abi.encode(q));

        vm.expectRevert(abi.encodeWithSelector(IFeeManager.UnsupportedQuoteVersion.selector, uint8(2)));
        feeManager.getQuoteItem(signedQuote, QuoteTypes.FORWARD);
    }

    function test_getQuoteItem_emptyItems_returnsNotFound() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: new bytes(65)});
        bytes memory signedQuote = abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));

        (IFeeManager.QuoteItem memory item, bool found) = feeManager.getQuoteItem(signedQuote, QuoteTypes.FORWARD);
        assertFalse(found);
        assertEq(item.amount, 0);
    }

    function test_getQuoteItem_decodedQuote_findsFirstMatchingQuoteType() public view {
        string[] memory a0 = new string[](1);
        a0[0] = "x";
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({quoteType: "OTHER", quoteArgsHash: bytes32(0), amount: 1});
        items[1] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(a0)), amount: 99
        });
        IFeeManager.Quote memory decoded =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: new bytes(65)});

        (IFeeManager.QuoteItem memory item, bool found) = feeManager.getQuoteItem(decoded, QuoteTypes.FORWARD);
        assertTrue(found);
        assertEq(item.amount, 99);
    }

    function test_getQuoteItem_decodedQuote_returnsNotFoundForMissingType() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: "OTHER", quoteArgsHash: bytes32(0), amount: 1});
        IFeeManager.Quote memory decoded =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: new bytes(65)});

        (IFeeManager.QuoteItem memory item, bool found) = feeManager.getQuoteItem(decoded, QuoteTypes.FORWARD);
        assertFalse(found);
        assertEq(item.amount, 0);
    }

    function test_getQuoteItem_decodedQuote_emptyItems_returnsNotFound() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        IFeeManager.Quote memory decoded =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: new bytes(65)});

        (IFeeManager.QuoteItem memory item, bool found) = feeManager.getQuoteItem(decoded, QuoteTypes.FORWARD);
        assertFalse(found);
        assertEq(item.amount, 0);
    }

    function test_getQuoteTotal_emptyBytes_returnsZero() public view {
        (uint256 totalFee, address feeToken) = feeManager.getQuoteTotal("");
        assertEq(totalFee, 0);
        assertEq(feeToken, address(0));
    }

    function test_getQuoteTotal_sumsItemsAndReturnsFeeToken() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: bytes32(0), amount: 3});
        items[1] = IFeeManager.QuoteItem({quoteType: "B", quoteArgsHash: bytes32(0), amount: 7});
        address token = address(uint160(uint256(keccak256(bytes("token")))));
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: 1, feeToken: token, nonce: 0, signature: new bytes(65)});
        bytes memory signedQuote = abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));

        (uint256 totalFee, address feeToken) = feeManager.getQuoteTotal(signedQuote);
        assertEq(totalFee, 10);
        assertEq(feeToken, token);
    }

    function test_getQuoteTotal_revertsUnsupportedQuoteVersion() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: bytes32(0), amount: 5});
        IFeeManager.Quote memory q =
            IFeeManager.Quote({items: items, expiry: 1, feeToken: address(0), nonce: 0, signature: ""});
        bytes memory signedQuote = abi.encodePacked(uint8(255), abi.encode(q));

        vm.expectRevert(abi.encodeWithSelector(IFeeManager.UnsupportedQuoteVersion.selector, uint8(255)));
        feeManager.getQuoteTotal(signedQuote);
    }

    function test_getQuoteTotal_decodedQuote_sumsItemsAndReturnsFeeToken() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: bytes32(0), amount: 3});
        items[1] = IFeeManager.QuoteItem({quoteType: "B", quoteArgsHash: bytes32(0), amount: 7});
        address token = address(uint160(uint256(keccak256(bytes("token")))));
        IFeeManager.Quote memory decoded =
            IFeeManager.Quote({items: items, expiry: 1, feeToken: token, nonce: 0, signature: new bytes(65)});

        (uint256 totalFee, address feeToken) = feeManager.getQuoteTotal(decoded);
        assertEq(totalFee, 10);
        assertEq(feeToken, token);
    }

    function test_sumFees_signedQuote_sumsOnlyRequestedQuoteTypes() public view {
        string[] memory forwardArgs = new string[](1);
        forwardArgs[0] = "forward";
        string[] memory preFinArgs = new string[](1);
        preFinArgs[0] = "pre";
        string[] memory settlementArgs = new string[](1);
        settlementArgs[0] = "settle";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](3);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(forwardArgs)), amount: 3
        });
        items[1] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: keccak256(abi.encode(preFinArgs)), amount: 7
        });
        items[2] = IFeeManager.QuoteItem({
            quoteType: "SETTLEMENT", quoteArgsHash: keccak256(abi.encode(settlementArgs)), amount: 100
        });
        address token = address(uint160(uint256(keccak256(bytes("token")))));
        bytes memory signedQuote = _encodeLookupQuote(items, token, 0);

        string[] memory quoteTypes = new string[](2);
        quoteTypes[0] = QuoteTypes.FORWARD;
        quoteTypes[1] = QuoteTypes.PRE_FINALITY;

        (uint256 totalFee, address feeToken) = feeManager.sumFees(signedQuote, quoteTypes);
        assertEq(totalFee, 10);
        assertEq(feeToken, token);
    }

    function test_sumFees_decodedQuote_missingType_returnsZeroWithFeeToken() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        address token = address(uint160(uint256(keccak256(bytes("token")))));
        IFeeManager.Quote memory decoded =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: token, nonce: 0, signature: new bytes(65)});

        string[] memory quoteTypes = new string[](1);
        quoteTypes[0] = QuoteTypes.FORWARD;

        (uint256 totalFee, address feeToken) = feeManager.sumFees(decoded, quoteTypes);
        assertEq(totalFee, 0);
        assertEq(feeToken, token);
    }

    function test_sumFees_emptyBytes_returnsZero() public view {
        string[] memory withTypes = new string[](1);
        withTypes[0] = QuoteTypes.FORWARD;

        (uint256 totalFee, address feeToken) = feeManager.sumFees("", withTypes);
        assertEq(totalFee, 0);
        assertEq(feeToken, address(0));

        string[] memory withoutTypes = new string[](0);
        (totalFee, feeToken) = feeManager.sumFees("", withoutTypes);
        assertEq(totalFee, 0);
        assertEq(feeToken, address(0));
    }

    function test_sumFees_ignoresQuoteArgsAndSumsByType() public view {
        string[] memory quotedArgs = new string[](1);
        quotedArgs[0] = "quoted";
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(quotedArgs)), amount: 3
        });
        IFeeManager.Quote memory decoded =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: new bytes(65)});

        string[] memory quoteTypes = new string[](1);
        quoteTypes[0] = QuoteTypes.FORWARD;

        (uint256 totalFee, address feeToken) = feeManager.sumFees(decoded, quoteTypes);
        assertEq(totalFee, 3);
        assertEq(feeToken, address(0));
    }

    function test_sumFees_revertsTooManyQuoteItems() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](257);
        for (uint256 i = 0; i < 257; ++i) {
            items[i] = IFeeManager.QuoteItem({quoteType: "X", quoteArgsHash: bytes32(i), amount: 0});
        }
        IFeeManager.Quote memory decoded =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: new bytes(65)});

        string[] memory quoteTypes = new string[](1);
        quoteTypes[0] = QuoteTypes.FORWARD;

        vm.expectRevert(abi.encodeWithSelector(IFeeManager.TooManyQuoteItems.selector, uint256(257)));
        feeManager.sumFees(decoded, quoteTypes);
    }

    function test_sumFees_dedupsDuplicateQuoteTypes() public view {
        string[] memory forwardArgs = new string[](1);
        forwardArgs[0] = "forward";
        string[] memory preFinArgs = new string[](1);
        preFinArgs[0] = "pre";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(forwardArgs)), amount: 3
        });
        items[1] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: keccak256(abi.encode(preFinArgs)), amount: 7
        });
        address token = address(uint160(uint256(keccak256(bytes("token")))));
        IFeeManager.Quote memory decoded =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: token, nonce: 0, signature: new bytes(65)});

        // FORWARD appears three times, PRE_FINALITY once. Mirrors the
        // collectFeesWithQuote path which would revert DuplicateRequestType
        // rather than double-count.
        string[] memory quoteTypes = new string[](4);
        quoteTypes[0] = QuoteTypes.FORWARD;
        quoteTypes[1] = QuoteTypes.PRE_FINALITY;
        quoteTypes[2] = QuoteTypes.FORWARD;
        quoteTypes[3] = QuoteTypes.FORWARD;

        (uint256 totalFee, address feeToken) = feeManager.sumFees(decoded, quoteTypes);
        assertEq(totalFee, 10);
        assertEq(feeToken, token);
    }

    function test_sumFees_nonZeroNonceDoesNotRevert() public view {
        uint256 nonce = 7;
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 3
        });
        IFeeManager.Quote memory decoded =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: nonce, signature: new bytes(65)});

        string[] memory quoteTypes = new string[](1);
        quoteTypes[0] = QuoteTypes.FORWARD;

        (uint256 totalFee,) = feeManager.sumFees(decoded, quoteTypes);
        assertEq(totalFee, 3);
    }

    // ───────────────────── feeTaker ─────────────────────

    function test_feeTaker_returnsImmutableAddress() public view {
        assertEq(feeManager.feeTaker(), address(mockFeeTaker));
    }

    function test_usdcBlacklist_returnsImmutableAddress() public view {
        assertEq(feeManager.usdcBlacklist(), address(mockUsdcBlacklist));
    }

    function test_isDenylisted_delegatesToUsdc() public {
        address account = makeAddr("maybeBlacklisted");
        assertFalse(feeManager.isDenylisted(account));
        mockUsdcBlacklist.setBlacklisted(account, true);
        assertTrue(feeManager.isDenylisted(account));
    }

    function test_constructor_revertsOnZeroFeeTaker() public {
        vm.expectRevert(FeeManager.ZeroFeeTakerAddress.selector);
        new FeeManager(address(0), address(mockUsdcBlacklist));
    }

    function test_constructor_revertsOnZeroUsdcBlacklist() public {
        vm.expectRevert(FeeManager.ZeroUsdcBlacklistAddress.selector);
        new FeeManager(address(mockFeeTaker), address(0));
    }

    function test_collectFeesWithQuote_native_feeTakerReverts_entireCallReverts() public {
        RevertingFeeTaker revertingFt = new RevertingFeeTaker();
        FeeManager fm = _deployFeeManagerProxyWithFeeTaker(owner, address(revertingFt));
        vm.startPrank(owner);
        fm.grantRole(Roles.CALLER_ADMIN_ROLE, owner);
        fm.grantRole(Roles.SIGNER_ADMIN_ROLE, owner);
        fm.grantRole(Roles.ALLOWED_CALLER_ROLE, allowedCaller);
        fm.setTrustedQuoteSigner(trustedSigner, true);
        vm.stopPrank();

        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 1 ether
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(fm));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        vm.deal(allowedCaller, 2 ether);
        vm.prank(allowedCaller);
        vm.expectRevert("FeeTaker: reverted");
        fm.collectFeesWithQuote{value: 1 ether}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_erc20_feeTakerReverts_entireCallReverts() public {
        RevertingFeeTaker revertingFt = new RevertingFeeTaker();
        FeeManager fm = _deployFeeManagerProxyWithFeeTaker(owner, address(revertingFt));
        vm.startPrank(owner);
        fm.grantRole(Roles.CALLER_ADMIN_ROLE, owner);
        fm.grantRole(Roles.SIGNER_ADMIN_ROLE, owner);
        fm.grantRole(Roles.ALLOWED_CALLER_ROLE, allowedCaller);
        fm.setTrustedQuoteSigner(trustedSigner, true);
        vm.stopPrank();

        MockERC20 token = new MockERC20();
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 50e18
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(token), 0, TRUSTED_SIGNER_PK, address(fm));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        token.mint(allowedCaller, 50e18);
        vm.prank(allowedCaller);
        token.approve(address(fm), 50e18);

        vm.prank(allowedCaller);
        vm.expectRevert("FeeTaker: reverted");
        fm.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    function test_collectFeesWithQuote_native_multipleItems_forwardsTotal() public {
        string[] memory args0 = new string[](1);
        args0[0] = "arg0";
        string[] memory args1 = new string[](1);
        args1[0] = "arg1";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args0)), amount: 0.3 ether
        });
        items[1] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: keccak256(abi.encode(args1)), amount: 0.2 ether
        });
        bytes memory signedQuote =
            _encodeSignedQuote(items, block.timestamp + 1 days, address(0), 0, TRUSTED_SIGNER_PK, address(feeManager));

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](2);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args0, required: true});
        requests[1] =
            IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.PRE_FINALITY, quoteArgs: args1, required: true});

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        uint256 amount =
            feeManager.collectFeesWithQuote{value: 0.5 ether}(CORRELATION_HASH, requests, _claim(signedQuote));

        assertEq(amount, 0.5 ether);
        assertEq(address(feeManager).balance, 0);
        assertEq(address(mockFeeTaker).balance, 0.5 ether);
        assertEq(mockFeeTaker.nativeFeeReceived(), 0.5 ether);
    }

    function test_collectFeesWithQuote_erc20_multipleItems_forwardsTotal() public {
        MockERC20 token = new MockERC20();
        string[] memory args0 = new string[](1);
        args0[0] = "arg0";
        string[] memory args1 = new string[](1);
        args1[0] = "arg1";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args0)), amount: 50e18
        });
        items[1] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: keccak256(abi.encode(args1)), amount: 30e18
        });
        bytes memory signedQuote = _encodeSignedQuote(
            items, block.timestamp + 1 days, address(token), 0, TRUSTED_SIGNER_PK, address(feeManager)
        );

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](2);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args0, required: true});
        requests[1] =
            IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.PRE_FINALITY, quoteArgs: args1, required: true});

        token.mint(allowedCaller, 80e18);
        vm.prank(allowedCaller);
        token.approve(address(feeManager), 80e18);

        vm.prank(allowedCaller);
        uint256 amount = feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(signedQuote));
        assertEq(amount, 80e18);
        assertEq(token.balanceOf(address(feeManager)), 0, "FeeManager should not hold ERC-20 funds");
        assertEq(token.balanceOf(address(mockFeeTaker)), 80e18, "FeeTaker should receive ERC-20 fees");
    }

    function test_collectFeesWithQuote_erc20_revertsIfNativeSent() public {
        MockERC20 token = new MockERC20();
        string[] memory args = new string[](0);
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256(abi.encode(args)), amount: 10e18
        });
        bytes memory signedQuote = _encodeSignedQuote(
            items, block.timestamp + 1 days, address(token), 0, TRUSTED_SIGNER_PK, address(feeManager)
        );

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](1);
        requests[0] = IFeeManager.FeeWithQuoteRequest({quoteType: QuoteTypes.FORWARD, quoteArgs: args, required: true});

        token.mint(allowedCaller, 10e18);
        vm.prank(allowedCaller);
        token.approve(address(feeManager), 10e18);

        vm.deal(allowedCaller, 1 ether);
        vm.prank(allowedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(FeeManager.IncorrectNativePayment.selector, uint256(0), uint256(1 ether))
        );
        feeManager.collectFeesWithQuote{value: 1 ether}(CORRELATION_HASH, requests, _claim(signedQuote));
    }

    // ───────────────────── UUPS upgrade ─────────────────────

    function test_upgrade_success_preservesState() public {
        address payable customCollector = payable(makeAddr("customCollector"));
        vm.prank(feeCollectionAdmin);
        feeManager.setFeeCollectionAddress(customCollector);

        FeeManager newImpl = new FeeManager(address(mockFeeTaker), address(mockUsdcBlacklist));
        vm.prank(owner);
        feeManager.upgradeToAndCall(address(newImpl), "");

        assertEq(feeManager.owner(), owner);
        assertTrue(feeManager.hasRole(Roles.ALLOWED_CALLER_ROLE, allowedCaller));
        assertTrue(feeManager.isTrustedQuoteSigner(trustedSigner));
        assertTrue(feeManager.hasRole(Roles.PAUSER_ROLE, pauser_));
        assertTrue(feeManager.hasRole(Roles.FEE_COLLECTION_ADMIN_ROLE, feeCollectionAdmin));
        assertEq(feeManager.feeCollectionAddress(), customCollector);
        assertEq(feeManager.feeTaker(), address(mockFeeTaker));
    }

    function test_upgrade_revertsForNonOwner() public {
        address stranger = makeAddr("stranger");
        FeeManager newImpl = new FeeManager(address(mockFeeTaker), address(mockUsdcBlacklist));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        feeManager.upgradeToAndCall(address(newImpl), "");
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(FeeManager.RenounceDisabled.selector);
        feeManager.renounceOwnership();

        assertEq(feeManager.owner(), owner);
    }

    function test_renounceRole_revertsForDefaultAdminRole() public {
        bytes32 adminRole = feeManager.DEFAULT_ADMIN_ROLE();
        vm.prank(owner);
        vm.expectRevert(FeeManager.RenounceDisabled.selector);
        feeManager.renounceRole(adminRole, owner);

        assertTrue(feeManager.hasRole(adminRole, owner));
    }

    function test_renounceRole_allowsNonAdminRoles() public {
        vm.prank(pauser_);
        feeManager.renounceRole(Roles.PAUSER_ROLE, pauser_);

        assertFalse(feeManager.hasRole(Roles.PAUSER_ROLE, pauser_));
    }

    function test_grantRole_revertsForDefaultAdminRole() public {
        bytes32 adminRole = feeManager.DEFAULT_ADMIN_ROLE();
        address extra = makeAddr("extra");
        vm.prank(owner);
        vm.expectRevert(FeeManager.DefaultAdminRoleChangeDisabled.selector);
        feeManager.grantRole(adminRole, extra);
    }

    function test_revokeRole_revertsForDefaultAdminRole() public {
        bytes32 adminRole = feeManager.DEFAULT_ADMIN_ROLE();
        vm.prank(owner);
        vm.expectRevert(FeeManager.DefaultAdminRoleChangeDisabled.selector);
        feeManager.revokeRole(adminRole, owner);
    }

    function test_grantRole_revertsForZeroRoleAccount() public {
        vm.prank(owner);
        vm.expectRevert(FeeManager.ZeroRoleAccount.selector);
        feeManager.grantRole(Roles.PAUSER_ROLE, address(0));
    }

    function test_revokeRole_revertsForZeroRoleAccount() public {
        vm.prank(owner);
        vm.expectRevert(FeeManager.ZeroRoleAccount.selector);
        feeManager.revokeRole(Roles.PAUSER_ROLE, address(0));
    }

    function test_implementation_initializeRevertsWhenCalledDirectly() public {
        FeeManager impl = new FeeManager(address(mockFeeTaker), address(mockUsdcBlacklist));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner);
    }

    function test_transferOwnership_syncsDefaultAdminRole() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        feeManager.transferOwnership(newOwner);
        vm.prank(newOwner);
        feeManager.acceptOwnership();

        assertEq(feeManager.owner(), newOwner);
        assertTrue(feeManager.hasRole(feeManager.DEFAULT_ADMIN_ROLE(), newOwner));
        assertFalse(feeManager.hasRole(feeManager.DEFAULT_ADMIN_ROLE(), owner));
    }

    // ───────────────────── pause / unpause ─────────────────────

    function test_pause_blocksCollectFeesWithQuote() public {
        vm.prank(pauser_);
        feeManager.pause();

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);
        vm.prank(allowedCaller);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(""));
    }

    function test_unpause_resumesCollectFeesWithQuote() public {
        vm.prank(pauser_);
        feeManager.pause();

        vm.prank(pauser_);
        feeManager.unpause();

        IFeeManager.FeeWithQuoteRequest[] memory requests = new IFeeManager.FeeWithQuoteRequest[](0);
        vm.prank(allowedCaller);
        uint256 amount = feeManager.collectFeesWithQuote(CORRELATION_HASH, requests, _claim(""));
        assertEq(amount, 0);
    }

    function test_pause_emitsPausedEvent() public {
        vm.expectEmit(true, false, false, true);
        emit Paused(pauser_);

        vm.prank(pauser_);
        feeManager.pause();
    }

    function test_unpause_emitsUnpausedEvent() public {
        vm.prank(pauser_);
        feeManager.pause();

        vm.expectEmit(true, false, false, true);
        emit Unpaused(pauser_);

        vm.prank(pauser_);
        feeManager.unpause();
    }

    function test_pause_revertsForNonPauser() public {
        vm.prank(allowedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, allowedCaller, Roles.PAUSER_ROLE
            )
        );
        feeManager.pause();
    }

    function test_unpause_revertsForNonPauser() public {
        vm.prank(pauser_);
        feeManager.pause();

        vm.prank(allowedCaller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, allowedCaller, Roles.PAUSER_ROLE
            )
        );
        feeManager.unpause();
    }

    function test_pause_doesNotBlockGrantRole() public {
        vm.prank(pauser_);
        feeManager.pause();

        address newCaller = makeAddr("newCaller");
        vm.prank(callerAdmin);
        feeManager.grantRole(Roles.ALLOWED_CALLER_ROLE, newCaller);
        assertTrue(feeManager.hasRole(Roles.ALLOWED_CALLER_ROLE, newCaller));
    }

    function test_newPauserCanPause() public {
        address newPauser = makeAddr("newPauser");
        vm.prank(owner);
        feeManager.grantRole(Roles.PAUSER_ROLE, newPauser);

        vm.prank(newPauser);
        feeManager.pause();
        assertTrue(feeManager.paused());
    }
}
