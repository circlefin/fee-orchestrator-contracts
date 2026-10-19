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
import {TokenMessengerWithFees} from "../src/contracts/TokenMessengerWithFees.sol";
import {IFeeManager} from "../src/interfaces/IFeeManager.sol";
import {ITokenMessengerWithFees} from "../src/interfaces/ITokenMessengerWithFees.sol";
import {BurnMessageV2Lib} from "../src/libraries/BurnMessageV2Lib.sol";
import {MessageV2Lib} from "../src/libraries/MessageV2Lib.sol";
import {SignedQuoteLib} from "../src/libraries/SignedQuoteLib.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Test, Vm} from "forge-std/Test.sol";

import {IFeeTaker} from "../src/interfaces/IFeeTaker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockUSDCBlacklist} from "./mocks/MockUSDCBlacklist.sol";
import {MockUsdcAwareBurnToken} from "./mocks/MockUsdcAwareBurnToken.sol";

// ─────────────────────────────── Mocks ───────────────────────────────

contract MockBurnToken is ERC20 {
    constructor() ERC20("MockUSDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeToken is ERC20 {
    constructor() ERC20("MockFeeToken", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeTakerForWrapper is IFeeTaker {
    function protocolFeeAddress() external view override returns (address) {
        return address(this);
    }

    // solhint-disable-next-line no-empty-blocks
    function takeFeeNative(address payable, bytes8) external payable override {}

    function takeFeeERC20(address token, address, uint256 fee, bytes8) external override {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(token).transferFrom(msg.sender, address(this), fee);
    }
}

contract MockMessageTransmitter {
    uint32 public localDomain;

    constructor(uint32 domain_) {
        localDomain = domain_;
    }
}

/* solhint-disable avoid-tx-origin */
contract MockTokenMessengerV2 {
    address public localMessageTransmitter;
    uint32 public messageBodyVersion;
    mapping(uint32 => bytes32) public remoteTokenMessengers;
    mapping(address => bool) public isDenylisted;

    uint256 public lastAmount;
    uint32 public lastDestinationDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32 public lastMinFinalityThreshold;
    bytes public lastHookData;
    bool public lastCallWasHook;

    constructor(address messageTransmitter_, uint32 bodyVersion_) {
        localMessageTransmitter = messageTransmitter_;
        messageBodyVersion = bodyVersion_;
    }

    function setRemoteTokenMessenger(uint32 domain, bytes32 messenger) external {
        remoteTokenMessengers[domain] = messenger;
    }

    function setDenylisted(address addr, bool denied) external {
        isDenylisted[addr] = denied;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        if (isDenylisted[tx.origin]) {
            revert ITokenMessengerWithFees.DenylistedCaller(tx.origin);
        }
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        ERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastCallWasHook = false;
    }

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        if (isDenylisted[tx.origin]) {
            revert ITokenMessengerWithFees.DenylistedCaller(tx.origin);
        }
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        ERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastHookData = hookData;
        lastCallWasHook = true;
    }
}

/* solhint-enable avoid-tx-origin */

// ─────────────────────────── Test Contract ───────────────────────────

contract TokenMessengerWithFeesTest is Test {
    TokenMessengerWithFees internal wrapper;
    FeeManager internal feeManager;
    MockTokenMessengerV2 internal mockTm;
    MockMessageTransmitter internal mockMt;
    MockBurnToken internal burnToken;
    MockFeeToken internal mockFeeToken;
    MockFeeTakerForWrapper internal mockFeeTaker;
    MockUSDCBlacklist internal mockUsdcBlacklist;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    uint32 internal constant SOURCE_DOMAIN = 0;
    uint32 internal constant DEST_DOMAIN = 6;
    uint32 internal constant BODY_VERSION = 1;
    bytes32 internal constant REMOTE_TM = bytes32(uint256(uint160(0xDeaDBeef)));
    bytes32 internal constant MINT_RECIPIENT = bytes32(uint256(uint160(0xCafe)));
    bytes32 internal constant DEST_CALLER = bytes32(0);

    uint256 internal constant BURN_AMOUNT = 100e6;
    uint256 internal constant TRUSTED_SIGNER_PK = 0xa11ce;

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

    // ──────────────── Helpers ────────────────

    /// @dev Builds a `QuoteClaim` whose refund target is the test's `user` EOA.
    ///      Used by the bulk of bytes-overload entry-point call sites in this file.
    function _userClaim(bytes memory signedQuote) internal view returns (IFeeManager.QuoteClaim memory) {
        return IFeeManager.QuoteClaim({signedQuote: signedQuote, refundAddress: payable(user)});
    }

    /// @dev Builds a `QuoteClaim` with a caller-supplied refund target. Used by the few tests that
    ///      need to exercise non-default refund attribution (e.g. `address(0)` or a non-`user` target).
    function _claim(bytes memory signedQuote, address payable refundAddress)
        internal
        pure
        returns (IFeeManager.QuoteClaim memory)
    {
        return IFeeManager.QuoteClaim({signedQuote: signedQuote, refundAddress: refundAddress});
    }

    /// @dev Decoded counterpart to `_userClaim` — bundles a decoded `Quote` with `user` as refund target.
    function _userDecodedClaim(IFeeManager.Quote memory decoded)
        internal
        view
        returns (IFeeManager.DecodedQuoteClaim memory)
    {
        return IFeeManager.DecodedQuoteClaim({decodedQuote: decoded, refundAddress: payable(user)});
    }

    function _deployFeeManagerProxy(address initialOwner) internal returns (FeeManager) {
        FeeManager impl = new FeeManager(address(mockFeeTaker), address(mockUsdcBlacklist));
        bytes memory initData = abi.encodeCall(FeeManager.initialize, (initialOwner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return FeeManager(payable(address(proxy)));
    }

    function _deployWrapperProxy(address owner_, address tokenMessenger_, address feeManager_)
        internal
        returns (TokenMessengerWithFees)
    {
        TokenMessengerWithFees impl = new TokenMessengerWithFees(tokenMessenger_, feeManager_);
        bytes memory initData = abi.encodeCall(TokenMessengerWithFees.initialize, (owner_));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return TokenMessengerWithFees(payable(address(proxy)));
    }

    function _signQuote(IFeeManager.QuoteItem[] memory items, uint256 expiry, address feeToken)
        internal
        view
        returns (bytes memory)
    {
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
        bytes32 domainSep = keccak256(
            abi.encode(
                EIP712TypeHashes.DOMAIN_TYPEHASH,
                keccak256(bytes("FeeManager")),
                keccak256(bytes("1")),
                block.chainid,
                address(feeManager)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                EIP712TypeHashes.QUOTE_TYPEHASH, keccak256(abi.encodePacked(itemHashes)), expiry, feeToken, uint256(0)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TRUSTED_SIGNER_PK, digest);
        IFeeManager.Quote memory q = IFeeManager.Quote({
            items: items, expiry: expiry, feeToken: feeToken, nonce: 0, signature: abi.encodePacked(r, s, v)
        });
        return abi.encodePacked(uint8(SignedQuoteLib.QUOTE_WIRE_FORMAT_VERSION), abi.encode(q));
    }

    function _preFinArgsHash() internal view returns (bytes32) {
        return _preFinArgsHashFor(address(burnToken), BURN_AMOUNT);
    }

    function _preFinArgsHashFor(address burnTokenAddr, uint256 amount) internal view returns (bytes32) {
        string[] memory args = new string[](4);
        args[0] = Strings.toHexString(address(wrapper));
        args[1] = Strings.toString(uint256(DEST_DOMAIN));
        args[2] = Strings.toHexString(burnTokenAddr);
        args[3] = Strings.toString(amount);
        return keccak256(abi.encode(args));
    }

    function _forwardArgsHash(bytes memory hookData) internal view returns (bytes32) {
        return _forwardArgsHashFor(address(burnToken), hookData);
    }

    function _forwardArgsHashFor(address burnTokenAddr, bytes memory hookData) internal view returns (bytes32) {
        string[] memory args = new string[](5);
        args[0] = Strings.toHexString(address(wrapper));
        args[1] = Strings.toString(uint256(DEST_DOMAIN));
        args[2] = Strings.toHexString(burnTokenAddr);
        args[3] = Strings.toHexString(uint256(DEST_CALLER), 32);
        args[4] = Strings.toHexString(hookData);
        return keccak256(abi.encode(args));
    }

    function _emptySignedQuote() internal view returns (bytes memory) {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        return _signQuote(items, block.timestamp + 300, address(0));
    }

    function _preFinOnlyQuote() internal view returns (bytes memory) {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 100});
        return _signQuote(items, block.timestamp + 300, address(0));
    }

    function _forwardOnlyQuote() internal view returns (bytes memory) {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: _forwardArgsHash(_forwardHookData()), amount: 900_000
        });
        return _signQuote(items, block.timestamp + 300, address(0));
    }

    function _fullQuote() internal view returns (bytes memory) {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: _forwardArgsHash(_forwardHookData()), amount: 900_000
        });
        items[1] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 100});
        return _signQuote(items, block.timestamp + 300, address(0));
    }

    function _preFinOnlyQuoteErc20() internal view returns (bytes memory) {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 5e18});
        return _signQuote(items, block.timestamp + 300, address(mockFeeToken));
    }

    function _fullQuoteErc20() internal view returns (bytes memory) {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: _forwardArgsHash(_forwardHookData()), amount: 3e18
        });
        items[1] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 5e18});
        return _signQuote(items, block.timestamp + 300, address(mockFeeToken));
    }

    /// @dev PRE_FINALITY + extra type the wrapper never requests — mimics partial collection vs `getQuoteTotal`.
    function _preFinPlusSettlementQuoteErc20() internal view returns (bytes memory) {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 5e18});
        items[1] = IFeeManager.QuoteItem({quoteType: "SETTLEMENT", quoteArgsHash: bytes32(0), amount: 5e18});
        return _signQuote(items, block.timestamp + 300, address(mockFeeToken));
    }

    /// @dev Builds a valid cctp-forward hook (version 0, no Circle data).
    function _forwardHookData() internal pure returns (bytes memory) {
        return hex"636374702d666f72776172640000000000000000000000000000000000000000";
    }

    // ──────────────── setUp ────────────────

    function setUp() public {
        mockFeeTaker = new MockFeeTakerForWrapper();
        mockUsdcBlacklist = new MockUSDCBlacklist();
        mockMt = new MockMessageTransmitter(SOURCE_DOMAIN);
        mockTm = new MockTokenMessengerV2(address(mockMt), BODY_VERSION);
        mockTm.setRemoteTokenMessenger(DEST_DOMAIN, REMOTE_TM);

        feeManager = _deployFeeManagerProxy(owner);
        wrapper = _deployWrapperProxy(owner, address(mockTm), address(feeManager));

        vm.startPrank(owner);
        feeManager.grantRole(Roles.CALLER_ADMIN_ROLE, owner);
        feeManager.grantRole(Roles.SIGNER_ADMIN_ROLE, owner);
        feeManager.grantRole(Roles.ALLOWED_CALLER_ROLE, address(wrapper));
        feeManager.setTrustedQuoteSigner(vm.addr(TRUSTED_SIGNER_PK), true);
        vm.stopPrank();

        burnToken = new MockBurnToken();
        burnToken.mint(user, 1000e6);

        mockFeeToken = new MockFeeToken();
        mockFeeToken.mint(user, 1000e18);

        vm.startPrank(user);
        burnToken.approve(address(wrapper), type(uint256).max);
        mockFeeToken.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();
    }

    // ─────────────── initialize ───────────────

    function test_initialize_setsOwner() public view {
        assertEq(wrapper.owner(), owner);
    }

    function test_initialize_setsTokenMessenger() public view {
        assertEq(wrapper.tokenMessenger(), address(mockTm));
    }

    function test_initialize_setsFeeManager() public view {
        assertEq(wrapper.feeManager(), address(feeManager));
    }

    function test_initialize_revertsWhenCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wrapper.initialize(owner);
    }

    function test_constructor_revertsOnZeroTokenMessenger() public {
        vm.expectRevert(ITokenMessengerWithFees.ZeroTokenMessengerAddress.selector);
        new TokenMessengerWithFees(address(0), address(feeManager));
    }

    function test_constructor_revertsOnZeroFeeManager() public {
        vm.expectRevert(ITokenMessengerWithFees.ZeroFeeManagerAddress.selector);
        new TokenMessengerWithFees(address(mockTm), address(0));
    }

    function test_feeManager_feeTaker_returnsCorrectAddress() public view {
        assertEq(feeManager.feeTaker(), address(mockFeeTaker));
    }

    function test_feeManager_usdcBlacklist_returnsCorrectAddress() public view {
        assertEq(feeManager.usdcBlacklist(), address(mockUsdcBlacklist));
    }

    function test_implementation_initializeRevertsWhenCalledDirectly() public {
        TokenMessengerWithFees impl = new TokenMessengerWithFees(address(mockTm), address(feeManager));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(owner);
    }

    // ─────────────── depositForBurnWithFees ───────────────

    function test_depositForBurnWithFees_noFeeItems_delegatesToTokenMessenger() public {
        bytes memory signedQuote = _emptySignedQuote();

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertEq(mockTm.lastAmount(), BURN_AMOUNT);
        assertEq(mockTm.lastDestinationDomain(), DEST_DOMAIN);
        assertEq(mockTm.lastMintRecipient(), MINT_RECIPIENT);
        assertEq(mockTm.lastBurnToken(), address(burnToken));
        assertEq(mockTm.lastDestinationCaller(), DEST_CALLER);
        assertEq(mockTm.lastMaxFee(), 0);
        assertEq(mockTm.lastMinFinalityThreshold(), 2000);
        assertFalse(mockTm.lastCallWasHook());
    }

    function test_depositForBurnWithFees_decodedQuote_matchesWireDecode() public {
        bytes memory signedQuote = _emptySignedQuote();
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userDecodedClaim(decoded)
        );

        assertEq(mockTm.lastAmount(), BURN_AMOUNT);
        assertEq(mockTm.lastMinFinalityThreshold(), 2000);
        assertFalse(mockTm.lastCallWasHook());
    }

    function test_depositForBurnWithFees_decodedQuote_skipsWrapperDecodeQuote() public {
        bytes memory signedQuote = _emptySignedQuote();
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);

        vm.expectCall(address(feeManager), abi.encodeWithSelector(IFeeManager.decodeQuote.selector, signedQuote), 0);

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userDecodedClaim(decoded)
        );
    }

    function test_depositForBurnWithFees_preFinalityQuote_setsConfirmedThreshold() public {
        bytes memory signedQuote = _preFinOnlyQuote();

        vm.deal(user, 1 ether);
        vm.prank(user);
        wrapper.depositForBurnWithFees{value: 100}(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertEq(mockTm.lastMinFinalityThreshold(), 1000);
        assertFalse(mockTm.lastCallWasHook());
    }

    function test_depositForBurnWithFees_forwardQuote_autoConstructsHookData() public {
        bytes memory signedQuote = _forwardOnlyQuote();

        vm.deal(user, 1 ether);
        vm.prank(user);
        wrapper.depositForBurnWithFees{value: 900_000}(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertTrue(mockTm.lastCallWasHook());
        assertEq(mockTm.lastHookData(), _forwardHookData());
        assertEq(mockTm.lastMinFinalityThreshold(), 2000);
    }

    function test_depositForBurnWithFees_fullQuote_autoConstructsHookDataAndFastFinality() public {
        bytes memory signedQuote = _fullQuote();

        vm.deal(user, 1 ether);
        vm.prank(user);
        wrapper.depositForBurnWithFees{value: 900_100}(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertTrue(mockTm.lastCallWasHook());
        assertEq(mockTm.lastHookData(), _forwardHookData());
        assertEq(mockTm.lastMinFinalityThreshold(), 1000);
    }

    function test_depositForBurnWithFees_transfersBurnTokens() public {
        bytes memory signedQuote = _emptySignedQuote();
        uint256 userBefore = burnToken.balanceOf(user);

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertEq(burnToken.balanceOf(user), userBefore - BURN_AMOUNT);
        assertEq(burnToken.balanceOf(address(mockTm)), BURN_AMOUNT);
    }

    function test_depositForBurnWithFees_forwardsNativeFees() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 0.1 ether
        });
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(0));

        vm.deal(user, 1 ether);

        vm.prank(user);
        wrapper.depositForBurnWithFees{value: 0.1 ether}(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertEq(address(feeManager).balance, 0, "FeeManager should not hold funds");
        assertEq(address(wrapper).balance, 0, "wrapper should not hold funds");
        assertEq(address(mockFeeTaker).balance, 0.1 ether, "FeeTaker should receive native fees");
    }

    function test_depositForBurnWithFees_revertsForUnsetRemoteTokenMessenger() public {
        bytes memory signedQuote = _emptySignedQuote();
        uint32 unknownDomain = 999;

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(ITokenMessengerWithFees.RemoteTokenMessengerNotSet.selector, unknownDomain)
        );
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, unknownDomain, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithFees_emitsFeeCollected() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 0});
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(0));

        vm.recordLogs();

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 feeCollectedSig =
            keccak256("FeeCollected(address,bytes32,string,string[],address,address,address,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics[0] == feeCollectedSig) {
                (string memory quoteType,,,,,,) =
                    abi.decode(entries[i].data, (string, string[], address, address, address, uint256, uint256));
                if (keccak256(bytes(quoteType)) == keccak256(bytes(QuoteTypes.PRE_FINALITY))) {
                    assertEq(entries[i].topics[1], bytes32(uint256(uint160(address(wrapper)))));
                    found = true;
                    break;
                }
            }
        }
        assertTrue(found, "FeeCollected(PRE_FINALITY) event not emitted");
    }

    // ─────────────── depositForBurnWithHookAndFees ───────────────

    function test_depositForBurnWithHookAndFees_forwardQuote_delegatesWithHook() public {
        bytes memory signedQuote = _forwardOnlyQuote();
        bytes memory hookData = _forwardHookData();

        vm.deal(user, 1 ether);
        vm.prank(user);
        wrapper.depositForBurnWithHookAndFees{value: 900_000}(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );

        assertTrue(mockTm.lastCallWasHook());
        assertEq(mockTm.lastAmount(), BURN_AMOUNT);
        assertEq(mockTm.lastMinFinalityThreshold(), 2000);
        assertEq(mockTm.lastHookData(), hookData);
    }

    function test_depositForBurnWithHookAndFees_fullQuote_setsConfirmedThresholdAndHook() public {
        bytes memory signedQuote = _fullQuote();
        bytes memory hookData = _forwardHookData();

        vm.deal(user, 1 ether);
        vm.prank(user);
        wrapper.depositForBurnWithHookAndFees{value: 900_100}(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );

        assertTrue(mockTm.lastCallWasHook());
        assertEq(mockTm.lastMinFinalityThreshold(), 1000);
        assertEq(mockTm.lastMaxFee(), 0);
    }

    function test_depositForBurnWithHookAndFees_forwardQuote_nonForwardHook_reverts() public {
        bytes memory signedQuote = _forwardOnlyQuote();
        bytes memory hookData = hex"01";

        vm.prank(user);
        vm.expectRevert(ITokenMessengerWithFees.ForwardFeeWithoutHook.selector);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithHookAndFees_forwardHook_emptyQuote_reverts() public {
        bytes memory signedQuote = _emptySignedQuote();
        bytes memory hookData = _forwardHookData();

        vm.prank(user);
        vm.expectRevert(ITokenMessengerWithFees.ForwardHookWithoutFee.selector);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithHookAndFees_forwardHook_preFinOnlyQuote_reverts() public {
        bytes memory signedQuote = _preFinOnlyQuote();
        bytes memory hookData = _forwardHookData();

        vm.prank(user);
        vm.expectRevert(ITokenMessengerWithFees.ForwardHookWithoutFee.selector);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithHookAndFees_decodedQuote_forwardHook_emptyQuote_reverts() public {
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(_emptySignedQuote());
        bytes memory hookData = _forwardHookData();

        vm.prank(user);
        vm.expectRevert(ITokenMessengerWithFees.ForwardHookWithoutFee.selector);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT,
            DEST_DOMAIN,
            MINT_RECIPIENT,
            address(burnToken),
            DEST_CALLER,
            hookData,
            _userDecodedClaim(decoded)
        );
    }

    function test_depositForBurnWithHookAndFees_decodedQuote_forwardHook_preFinOnlyQuote_reverts() public {
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(_preFinOnlyQuote());
        bytes memory hookData = _forwardHookData();

        vm.prank(user);
        vm.expectRevert(ITokenMessengerWithFees.ForwardHookWithoutFee.selector);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT,
            DEST_DOMAIN,
            MINT_RECIPIENT,
            address(burnToken),
            DEST_CALLER,
            hookData,
            _userDecodedClaim(decoded)
        );
    }

    function test_depositForBurnWithHookAndFees_emptyHookData_reverts() public {
        bytes memory signedQuote = _emptySignedQuote();

        vm.prank(user);
        vm.expectRevert(ITokenMessengerWithFees.EmptyHookData.selector);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, "", _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithHookAndFees_decodedQuote_emptyHookData_reverts() public {
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(_emptySignedQuote());

        vm.prank(user);
        vm.expectRevert(ITokenMessengerWithFees.EmptyHookData.selector);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, "", _userDecodedClaim(decoded)
        );
    }

    function test_depositForBurnWithHookAndFees_noFeeItems_delegatesToTokenMessengerWithHook() public {
        bytes memory signedQuote = _emptySignedQuote();
        bytes memory hookData = hex"01";

        vm.prank(user);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );

        assertTrue(mockTm.lastCallWasHook());
        assertEq(mockTm.lastMinFinalityThreshold(), 2000);
    }

    function test_depositForBurnWithHookAndFees_decodedQuote_matchesWireDecode() public {
        bytes memory signedQuote = _emptySignedQuote();
        bytes memory hookData = hex"01";
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);

        vm.prank(user);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT,
            DEST_DOMAIN,
            MINT_RECIPIENT,
            address(burnToken),
            DEST_CALLER,
            hookData,
            _userDecodedClaim(decoded)
        );

        assertTrue(mockTm.lastCallWasHook());
        assertEq(mockTm.lastMinFinalityThreshold(), 2000);
    }

    function test_depositForBurnWithHookAndFees_decodedQuote_skipsWrapperDecodeQuote() public {
        bytes memory signedQuote = _emptySignedQuote();
        bytes memory hookData = hex"01";
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);

        vm.expectCall(address(feeManager), abi.encodeWithSelector(IFeeManager.decodeQuote.selector, signedQuote), 0);

        vm.prank(user);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT,
            DEST_DOMAIN,
            MINT_RECIPIENT,
            address(burnToken),
            DEST_CALLER,
            hookData,
            _userDecodedClaim(decoded)
        );
    }

    // ───────────────── getFee ─────────────────

    function test_getFee_signedQuote_returnsSupportedTypeFee() public view {
        bytes memory signedQuote = _preFinPlusSettlementQuoteErc20();

        (uint256 totalFee, address feeToken) = wrapper.getFee(signedQuote);

        assertEq(totalFee, 5e18, "getter should exclude unrequested quote items");
        assertEq(feeToken, address(mockFeeToken));
    }

    function test_getFee_decodedQuote_matchesSignedQuote() public view {
        bytes memory signedQuote = _preFinPlusSettlementQuoteErc20();
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);

        (uint256 totalFee, address feeToken) = wrapper.getFee(decoded);

        assertEq(totalFee, 5e18, "getter should exclude unrequested quote items");
        assertEq(feeToken, address(mockFeeToken));
    }

    function test_getFee_sumsForwardAndPreFinalityByType() public view {
        bytes memory signedQuote = _fullQuoteErc20();

        (uint256 totalFee, address feeToken) = wrapper.getFee(signedQuote);

        assertEq(totalFee, 8e18);
        assertEq(feeToken, address(mockFeeToken));
    }

    function test_getFee_sumsSupportedTypeEvenWhenQuoteArgsWouldFailCollection() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: keccak256("wrong forward args"), amount: 3e18
        });
        items[1] = IFeeManager.QuoteItem({quoteType: "SETTLEMENT", quoteArgsHash: bytes32(0), amount: 5e18});
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(mockFeeToken));

        (uint256 totalFee, address feeToken) = wrapper.getFee(signedQuote);

        assertEq(totalFee, 3e18, "getter should sum by supported type only");
        assertEq(feeToken, address(mockFeeToken));
    }

    function test_getFee_decodedQuote_sumsSupportedTypeEvenWhenQuoteArgsWouldFailCollection() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: keccak256("wrong pre-finality args"), amount: 5e18
        });
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(mockFeeToken));
        IFeeManager.Quote memory decoded = feeManager.decodeQuote(signedQuote);

        (uint256 totalFee, address feeToken) = wrapper.getFee(decoded);

        assertEq(totalFee, 5e18, "getter should sum by supported type only");
        assertEq(feeToken, address(mockFeeToken));
    }

    function test_getFee_emptyBytes_returnsZero() public view {
        // Mirrors FeeManager.{sumFees, getQuoteTotal, getQuoteItem} empty-bytes
        // behavior so off-chain callers can use a single "no quote -> no fee"
        // pattern across all read APIs.
        (uint256 totalFee, address feeToken) = wrapper.getFee("");
        assertEq(totalFee, 0);
        assertEq(feeToken, address(0));
    }

    // ───────────────── Correlation hash ─────────────────

    function test_correlationHash_emptyQuote_usesSlowFinalityAndNoHook() public {
        bytes memory signedQuote = _emptySignedQuote();

        // Quote is decoded in-process (`SignedQuoteLib`); no external `FeeManager.decodeQuote`.
        // `collectFeesWithQuote` uses the decoded-`Quote` overload; calldata is long (dynamic arrays + struct).
        vm.expectCall(address(feeManager), bytes(""));

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }

    function test_correlationHash_matchesExpectedFormat() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 0});
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(0));

        bytes memory messageBody = BurnMessageV2Lib.formatMessage(
            BODY_VERSION,
            bytes32(uint256(uint160(address(burnToken)))),
            MINT_RECIPIENT,
            BURN_AMOUNT,
            bytes32(uint256(uint160(address(wrapper)))),
            ""
        );
        bytes32 expectedHash = MessageV2Lib.messageHash(
            SOURCE_DOMAIN,
            DEST_DOMAIN,
            bytes32(uint256(uint160(address(mockTm)))),
            REMOTE_TM,
            DEST_CALLER,
            1000,
            messageBody
        );

        vm.recordLogs();

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 feeCollectedSig =
            keccak256("FeeCollected(address,bytes32,string,string[],address,address,address,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics[0] == feeCollectedSig) {
                assertEq(entries[i].topics[2], expectedHash, "correlationHash mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "FeeCollected event not emitted");
    }

    function test_correlationHash_withHook_includesHookData() public {
        bytes memory hookData = _forwardHookData();
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: _forwardArgsHash(hookData), amount: 0
        });
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(0));

        bytes memory messageBody = BurnMessageV2Lib.formatMessage(
            BODY_VERSION,
            bytes32(uint256(uint160(address(burnToken)))),
            MINT_RECIPIENT,
            BURN_AMOUNT,
            bytes32(uint256(uint160(address(wrapper)))),
            hookData
        );
        bytes32 expectedHash = MessageV2Lib.messageHash(
            SOURCE_DOMAIN,
            DEST_DOMAIN,
            bytes32(uint256(uint160(address(mockTm)))),
            REMOTE_TM,
            DEST_CALLER,
            2000,
            messageBody
        );

        vm.recordLogs();

        vm.prank(user);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 feeCollectedSig =
            keccak256("FeeCollected(address,bytes32,string,string[],address,address,address,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics[0] == feeCollectedSig) {
                assertEq(entries[i].topics[2], expectedHash, "correlationHash mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "FeeCollected event not emitted");
    }

    function test_correlationHash_autoForwardHook_matchesExplicitHook() public {
        bytes memory hookData = _forwardHookData();
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: _forwardArgsHash(hookData), amount: 0
        });
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(0));

        bytes memory messageBody = BurnMessageV2Lib.formatMessage(
            BODY_VERSION,
            bytes32(uint256(uint160(address(burnToken)))),
            MINT_RECIPIENT,
            BURN_AMOUNT,
            bytes32(uint256(uint160(address(wrapper)))),
            hookData
        );
        bytes32 expectedHash = MessageV2Lib.messageHash(
            SOURCE_DOMAIN,
            DEST_DOMAIN,
            bytes32(uint256(uint160(address(mockTm)))),
            REMOTE_TM,
            DEST_CALLER,
            2000,
            messageBody
        );

        vm.recordLogs();

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 feeCollectedSig =
            keccak256("FeeCollected(address,bytes32,string,string[],address,address,address,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics[0] == feeCollectedSig) {
                assertEq(entries[i].topics[2], expectedHash, "correlationHash mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "FeeCollected event not emitted");
    }

    // ─────────────── ERC20 fee collection ───────────────

    function test_depositForBurnWithFees_erc20Fee_pullsFromUserAndForwardsToFeeTaker() public {
        bytes memory signedQuote = _preFinOnlyQuoteErc20();

        uint256 userFeeBefore = mockFeeToken.balanceOf(user);

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertEq(mockFeeToken.balanceOf(user), userFeeBefore - 5e18, "user should pay ERC20 fee");
        assertEq(mockFeeToken.balanceOf(address(wrapper)), 0, "wrapper should not hold fee tokens");
        assertEq(mockFeeToken.balanceOf(address(feeManager)), 0, "FeeManager should not hold fee tokens");
        assertEq(mockFeeToken.balanceOf(address(mockFeeTaker)), 5e18, "FeeTaker should receive ERC20 fees");
        assertEq(
            mockFeeToken.allowance(address(wrapper), address(feeManager)),
            0,
            "wrapper should have zero residual allowance to FeeManager"
        );
        assertEq(
            mockFeeToken.allowance(address(feeManager), address(mockFeeTaker)),
            0,
            "FeeManager should have zero residual allowance to FeeTaker"
        );
    }

    function test_depositForBurnWithFees_erc20Fee_stillTransfersBurnTokens() public {
        bytes memory signedQuote = _preFinOnlyQuoteErc20();

        uint256 userBurnBefore = burnToken.balanceOf(user);

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertEq(burnToken.balanceOf(user), userBurnBefore - BURN_AMOUNT);
        assertEq(burnToken.balanceOf(address(mockTm)), BURN_AMOUNT);
    }

    function test_depositForBurnWithFees_erc20Fee_pullsOnlyMatchedFeeWhenNotAllItemsMatch() public {
        // Quote total 10e18 (PRE_FINALITY + SETTLEMENT); wrapper only collects PRE_FINALITY (5e18).
        bytes memory signedQuote = _preFinPlusSettlementQuoteErc20();

        uint256 userFeeBefore = mockFeeToken.balanceOf(user);

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertEq(mockFeeToken.balanceOf(user), userFeeBefore - 5e18, "only matched PRE_FINALITY should be deducted");
        assertEq(mockFeeToken.balanceOf(address(mockFeeTaker)), 5e18, "FeeTaker should receive matched fees");
        assertEq(mockFeeToken.balanceOf(address(wrapper)), 0, "wrapper should not retain fees");
    }

    function test_depositForBurnWithFees_erc20Fee_succeedsWhenAllowanceCoversMatchedFeeButNotQuoteTotal() public {
        // Quote total 10e18 (PRE_FINALITY + SETTLEMENT); supported matched fee is 5e18.
        // Documents that callers only need to approve the matched fee, not the full quote total.
        bytes memory signedQuote = _preFinPlusSettlementQuoteErc20();

        vm.prank(user);
        mockFeeToken.approve(address(wrapper), 6e18);

        uint256 userFeeBefore = mockFeeToken.balanceOf(user);

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertEq(mockFeeToken.balanceOf(user), userFeeBefore - 5e18, "user should pay only matched fee");
        assertEq(mockFeeToken.balanceOf(address(mockFeeTaker)), 5e18, "FeeTaker should receive matched fees");
        assertEq(mockFeeToken.balanceOf(address(wrapper)), 0, "wrapper should not retain fees");
    }

    function test_depositForBurnWithFees_erc20Fee_revertsWhenAllowanceBelowMatchedFee() public {
        bytes memory signedQuote = _preFinOnlyQuoteErc20();

        vm.prank(user);
        mockFeeToken.approve(address(wrapper), 4e18);

        vm.prank(user);
        vm.expectRevert();
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithFees_erc20Fee_revertsWhenPrecomputedTypeFeeHasWrongArgs() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: keccak256("wrong pre-finality args"), amount: 5e18
        });
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(mockFeeToken));

        vm.prank(user);
        mockFeeToken.approve(address(wrapper), 5e18);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeManager.QuoteArgsMismatch.selector, QuoteTypes.PRE_FINALITY, _preFinArgsHash())
        );
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithFees_erc20Fee_revertsWhenNativeValueSent() public {
        bytes memory signedQuote = _preFinOnlyQuoteErc20();

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FeeManager.IncorrectNativePayment.selector, 0, 0.1 ether));
        wrapper.depositForBurnWithFees{value: 0.1 ether}(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithFees_erc20Fee_feeTokenSameAsBurnToken() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 1e6});
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(burnToken));

        uint256 userBurnBefore = burnToken.balanceOf(user);

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertEq(burnToken.balanceOf(user), userBurnBefore - BURN_AMOUNT - 1e6, "user pays burn + fee from same token");
        assertEq(burnToken.balanceOf(address(mockTm)), BURN_AMOUNT, "TokenMessenger receives burn amount");
        assertEq(burnToken.balanceOf(address(mockFeeTaker)), 1e6, "FeeTaker receives fee");
    }

    function test_depositForBurnWithHookAndFees_erc20Fee_forwardsToFeeTaker() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        bytes memory hookData = _forwardHookData();
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: _forwardArgsHash(hookData), amount: 3e18
        });
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(mockFeeToken));

        uint256 userFeeBefore = mockFeeToken.balanceOf(user);

        vm.prank(user);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );

        assertEq(mockFeeToken.balanceOf(user), userFeeBefore - 3e18, "user should pay ERC20 fee");
        assertEq(mockFeeToken.balanceOf(address(mockFeeTaker)), 3e18, "FeeTaker should receive ERC20 fees");
        assertTrue(mockTm.lastCallWasHook());
    }

    function test_depositForBurnWithHookAndFees_erc20Fee_pullsOnlyMatchedForwardFee() public {
        // Quote contains FORWARD (matches) + an extra item type the wrapper
        // never requests. Total = 8e18, matched = 3e18.
        bytes memory hookData = _forwardHookData();
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD, quoteArgsHash: _forwardArgsHash(hookData), amount: 3e18
        });
        items[1] = IFeeManager.QuoteItem({quoteType: "SETTLEMENT", quoteArgsHash: bytes32(0), amount: 5e18});
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(mockFeeToken));

        uint256 userFeeBefore = mockFeeToken.balanceOf(user);

        vm.prank(user);
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );

        assertEq(mockFeeToken.balanceOf(user), userFeeBefore - 3e18, "only matched FORWARD fee should be deducted");
        assertEq(mockFeeToken.balanceOf(address(mockFeeTaker)), 3e18, "FeeTaker should receive matched fees");
        assertEq(mockFeeToken.balanceOf(address(wrapper)), 0, "wrapper should not retain fees");
        assertTrue(mockTm.lastCallWasHook());
    }

    function test_depositForBurnWithFees_erc20Fee_emitsFeeCollected() public {
        bytes memory signedQuote = _preFinOnlyQuoteErc20();

        vm.recordLogs();

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 feeCollectedSig =
            keccak256("FeeCollected(address,bytes32,string,string[],address,address,address,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics[0] == feeCollectedSig) {
                (string memory quoteType,,,, address feeTokenEmitted, uint256 amount,) =
                    abi.decode(entries[i].data, (string, string[], address, address, address, uint256, uint256));
                if (keccak256(bytes(quoteType)) == keccak256(bytes(QuoteTypes.PRE_FINALITY))) {
                    assertEq(feeTokenEmitted, address(mockFeeToken), "feeToken should be ERC20");
                    assertEq(amount, 5e18, "amount should match quote item");
                    found = true;
                    break;
                }
            }
        }
        assertTrue(found, "FeeCollected(PRE_FINALITY) event not emitted for ERC20 fee");
    }

    // ───────────────── UUPS upgrade ─────────────────

    function test_upgrade_preservesState() public {
        TokenMessengerWithFees newImpl = new TokenMessengerWithFees(address(mockTm), address(feeManager));
        vm.prank(owner);
        wrapper.upgradeToAndCall(address(newImpl), "");

        assertEq(wrapper.owner(), owner);
        assertEq(wrapper.tokenMessenger(), address(mockTm));
        assertEq(wrapper.feeManager(), address(feeManager));
    }

    function test_upgrade_revertsForNonOwner() public {
        address stranger = makeAddr("stranger");
        TokenMessengerWithFees newImpl = new TokenMessengerWithFees(address(mockTm), address(feeManager));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        wrapper.upgradeToAndCall(address(newImpl), "");
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(TokenMessengerWithFees.RenounceDisabled.selector);
        wrapper.renounceOwnership();

        assertEq(wrapper.owner(), owner);
    }

    // ───────────────── Denylist ─────────────────

    function test_depositForBurnWithFees_revertsWhenCallerDenylisted() public {
        mockTm.setDenylisted(user, true);
        bytes memory signedQuote = _emptySignedQuote();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ITokenMessengerWithFees.DenylistedCaller.selector, user));
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithHookAndFees_revertsWhenCallerDenylisted() public {
        mockTm.setDenylisted(user, true);
        bytes memory signedQuote = _forwardOnlyQuote();
        bytes memory hookData = _forwardHookData();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ITokenMessengerWithFees.DenylistedCaller.selector, user));
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithFees_succeedsWhenCallerNotDenylisted() public {
        mockTm.setDenylisted(user, false);
        bytes memory signedQuote = _emptySignedQuote();

        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );

        assertEq(mockTm.lastAmount(), BURN_AMOUNT);
    }

    function test_depositForBurnWithHookAndFees_succeedsWhenCallerNotDenylisted() public {
        mockTm.setDenylisted(user, false);
        bytes memory signedQuote = _forwardOnlyQuote();
        bytes memory hookData = _forwardHookData();

        vm.deal(user, 1 ether);
        vm.prank(user);
        wrapper.depositForBurnWithHookAndFees{value: 900_000}(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );

        assertTrue(mockTm.lastCallWasHook());
    }

    function test_depositForBurnWithFees_denylistChecksCallerNotOrigin() public {
        address intermediary = makeAddr("intermediary");

        // Denylist the intermediary, not the EOA (tx.origin)
        mockTm.setDenylisted(intermediary, true);

        bytes memory signedQuote = _emptySignedQuote();

        vm.prank(intermediary);
        vm.expectRevert(abi.encodeWithSelector(ITokenMessengerWithFees.DenylistedCaller.selector, intermediary));
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }

    /// @dev Wrapper only applies `TokenMessengerV2.isDenylisted` to `msg.sender`, not `tx.origin`.
    ///      `TokenMessengerV2.depositForBurn` still enforces `tx.origin` (mirrored in the mock).
    function test_depositForBurnWithFees_revertsWhenOnlyTxOriginDenylistedOnTokenMessenger() public {
        address cleanSender = makeAddr("cleanSender");
        address denylistedOrigin = makeAddr("denylistedOrigin");

        mockTm.setDenylisted(denylistedOrigin, true);

        burnToken.mint(cleanSender, BURN_AMOUNT);
        vm.prank(cleanSender);
        burnToken.approve(address(wrapper), type(uint256).max);

        bytes memory signedQuote = _emptySignedQuote();

        vm.prank(cleanSender, denylistedOrigin);
        vm.expectRevert(abi.encodeWithSelector(ITokenMessengerWithFees.DenylistedCaller.selector, denylistedOrigin));
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }

    // ───────────────── USDC blocklist (via FeeManager) ─────────────────

    function test_depositForBurnWithFees_revertsWhenSenderUsdcBlacklisted() public {
        address intermediary = makeAddr("usdcBlockedIntermediary");
        mockUsdcBlacklist.setBlacklisted(intermediary, true);
        burnToken.mint(intermediary, BURN_AMOUNT);
        vm.prank(intermediary);
        burnToken.approve(address(wrapper), type(uint256).max);

        bytes memory signedQuote = _emptySignedQuote();

        vm.prank(intermediary);
        vm.expectRevert(abi.encodeWithSelector(ITokenMessengerWithFees.DenylistedCaller.selector, intermediary));
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }

    function test_depositForBurnWithHookAndFees_revertsWhenSenderUsdcBlacklisted() public {
        address intermediary = makeAddr("usdcBlockedIntermediaryHook");
        mockUsdcBlacklist.setBlacklisted(intermediary, true);
        burnToken.mint(intermediary, BURN_AMOUNT);
        vm.prank(intermediary);
        burnToken.approve(address(wrapper), type(uint256).max);

        bytes memory signedQuote = _forwardOnlyQuote();
        bytes memory hookData = _forwardHookData();

        vm.prank(intermediary);
        vm.expectRevert(abi.encodeWithSelector(ITokenMessengerWithFees.DenylistedCaller.selector, intermediary));
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );
    }

    /// @dev EOA path skips wrapper `FeeManager.isDenylisted`; burn `transferFrom` still enforces USDC blocklist.
    function test_depositForBurnWithFees_eoaBlacklisted_revertsOnBurnTokenTransferFrom() public {
        MockUsdcAwareBurnToken usdcLike = new MockUsdcAwareBurnToken(address(mockUsdcBlacklist));
        mockUsdcBlacklist.setBlacklisted(user, true);
        usdcLike.mint(user, BURN_AMOUNT);
        vm.prank(user);
        usdcLike.approve(address(wrapper), type(uint256).max);

        bytes memory signedQuote = _emptySignedQuote();
        // Use a fresh non-blacklisted refund target so the FeeManager refund-address screen
        // doesn't pre-empt the burn-token-layer revert this test is designed to verify.
        address payable cleanRefund = payable(makeAddr("cleanRefund"));

        vm.prank(user, user);
        vm.expectRevert(bytes("MockUsdcAwareBurnToken: blacklisted sender"));
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(usdcLike), DEST_CALLER, _claim(signedQuote, cleanRefund)
        );
    }

    // ───────────── Refund-address attribution & screening ─────────────

    /// @dev Wrapper applies no defaulting to `refundAddress`. A caller-supplied `address(0)` is
    ///      forwarded verbatim and surfaces as `address(0)` in the FeeCollected event.
    function test_depositForBurnWithFees_zeroRefundAddress_forwardsZeroVerbatim() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 0});
        bytes memory signedQuote = _signQuote(items, block.timestamp + 1 hours, address(0));

        vm.recordLogs();
        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT,
            DEST_DOMAIN,
            MINT_RECIPIENT,
            address(burnToken),
            DEST_CALLER,
            _claim(signedQuote, payable(address(0)))
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("FeeCollected(address,bytes32,string,string[],address,address,address,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == sig) {
                (,, address payable refundAddress,,,,) =
                    abi.decode(entries[i].data, (string, string[], address, address, address, uint256, uint256));
                assertEq(refundAddress, payable(address(0)), "wrapper must not default zero refundAddress");
                found = true;
            }
        }
        assertTrue(found, "FeeCollected event not emitted");
    }

    /// @dev Explicit non-zero refundAddress is forwarded verbatim to FeeManager and emitted in the event.
    function test_depositForBurnWithFees_nonZeroRefundAddress_forwardsVerbatim() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] =
            IFeeManager.QuoteItem({quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: _preFinArgsHash(), amount: 0});
        bytes memory signedQuote = _signQuote(items, block.timestamp + 1 hours, address(0));
        address payable target = payable(makeAddr("attributedRefundTarget"));

        vm.recordLogs();
        vm.prank(user);
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _claim(signedQuote, target)
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("FeeCollected(address,bytes32,string,string[],address,address,address,uint256,uint256)");
        bool found = false;
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == sig) {
                (,, address payable refundAddress,,,,) =
                    abi.decode(entries[i].data, (string, string[], address, address, address, uint256, uint256));
                assertEq(refundAddress, target, "non-zero refundAddress must be forwarded unchanged");
                found = true;
            }
        }
        assertTrue(found, "FeeCollected event not emitted");
    }

    /// @dev Non-zero refundAddress is screened by FeeManager against the configured USDC blacklist.
    function test_depositForBurnWithFees_revertsForBlacklistedRefundAddress() public {
        bytes memory signedQuote = _emptySignedQuote();
        address payable blocked = payable(makeAddr("blockedRefund"));
        mockUsdcBlacklist.setBlacklisted(blocked, true);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.DenylistedRefundAddress.selector, blocked));
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _claim(signedQuote, blocked)
        );
    }

    /// @dev FORWARD `quoteArgs` bind `burnToken`; a FORWARD item signed for a different burn token
    ///      reaches `_collectMatchedItems` with a mismatched args hash and reverts. Addresses audit #012.
    function test_depositForBurnWithHookAndFees_forward_revertsForMismatchedBurnToken() public {
        MockBurnToken otherBurnToken = new MockBurnToken();
        bytes memory hookData = _forwardHookData();

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.FORWARD,
            quoteArgsHash: _forwardArgsHashFor(address(otherBurnToken), hookData),
            amount: 0
        });
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(0));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFeeManager.QuoteArgsMismatch.selector, QuoteTypes.FORWARD, _forwardArgsHash(hookData)
            )
        );
        wrapper.depositForBurnWithHookAndFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, hookData, _userClaim(signedQuote)
        );
    }

    /// @dev PRE_FINALITY `quoteArgs` bind `burnToken`; a PRE_FINALITY item signed for a different
    ///      burn token reaches `_collectMatchedItems` with a mismatched args hash and reverts. Addresses audit #012.
    function test_depositForBurnWithFees_preFin_revertsForMismatchedBurnToken() public {
        MockBurnToken otherBurnToken = new MockBurnToken();

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY,
            quoteArgsHash: _preFinArgsHashFor(address(otherBurnToken), BURN_AMOUNT),
            amount: 0
        });
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(0));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeManager.QuoteArgsMismatch.selector, QuoteTypes.PRE_FINALITY, _preFinArgsHash())
        );
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }

    /// @dev PRE_FINALITY `quoteArgs` bind the calling wrapper (`address(this)`); a PRE_FINALITY item
    ///      signed for a different `TokenMessengerWithFees` deployment reaches `_collectMatchedItems`
    ///      with a mismatched args hash and reverts.
    function test_depositForBurnWithFees_preFin_revertsForMismatchedWrapper() public {
        TokenMessengerWithFees otherWrapper = _deployWrapperProxy(owner, address(mockTm), address(feeManager));

        string[] memory args = new string[](4);
        args[0] = Strings.toHexString(address(otherWrapper));
        args[1] = Strings.toString(uint256(DEST_DOMAIN));
        args[2] = Strings.toHexString(address(burnToken));
        args[3] = Strings.toString(BURN_AMOUNT);

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({
            quoteType: QuoteTypes.PRE_FINALITY, quoteArgsHash: keccak256(abi.encode(args)), amount: 0
        });
        bytes memory signedQuote = _signQuote(items, block.timestamp + 300, address(0));

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeManager.QuoteArgsMismatch.selector, QuoteTypes.PRE_FINALITY, _preFinArgsHash())
        );
        wrapper.depositForBurnWithFees(
            BURN_AMOUNT, DEST_DOMAIN, MINT_RECIPIENT, address(burnToken), DEST_CALLER, _userClaim(signedQuote)
        );
    }
}
