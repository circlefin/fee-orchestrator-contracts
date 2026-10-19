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

import {IFeeManager} from "../src/interfaces/IFeeManager.sol";
import {QuoteLib} from "../src/libraries/QuoteLib.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Exposes internal library helpers for testing.
contract QuoteLibHarness {
    using QuoteLib for uint256;
    using QuoteLib for IFeeManager.Quote;
    using QuoteLib for IFeeManager.QuoteItem;

    function validateExpiry(uint256 encodedExpiry) external view {
        encodedExpiry.validateExpiry();
    }

    function mustNotExpire(IFeeManager.Quote calldata quote) external view {
        IFeeManager.Quote memory q = quote;
        q.mustNotExpire();
    }

    function findItemByType(IFeeManager.Quote calldata quote, string calldata qType)
        external
        pure
        returns (IFeeManager.QuoteItem memory item, uint256 itemIndex, bool matched)
    {
        IFeeManager.Quote memory q = quote;
        return q.findItemByType(qType);
    }

    function matchesRequest(IFeeManager.QuoteItem calldata item, string[] calldata quoteArgs)
        external
        pure
        returns (bool)
    {
        IFeeManager.QuoteItem memory it = item;
        return it.matchesRequest(quoteArgs);
    }

    function hashQuoteArgs(string[] calldata quoteArgs) external pure returns (bytes32) {
        return QuoteLib.hashQuoteArgs(quoteArgs);
    }

    function totalFeeAndFeeToken(IFeeManager.Quote calldata quote)
        external
        pure
        returns (uint256 totalFee, address feeToken)
    {
        IFeeManager.Quote memory q = quote;
        return q.totalFeeAndFeeToken();
    }

    function hasItemType(IFeeManager.Quote calldata quote, string calldata quoteType) external pure returns (bool) {
        IFeeManager.Quote memory q = quote;
        return q.hasItemType(quoteType);
    }

    function requireSupportedItemCount(IFeeManager.Quote calldata quote) external pure {
        IFeeManager.Quote memory q = quote;
        q.requireSupportedItemCount();
    }

    function findItemForRequest(IFeeManager.Quote calldata quote, IFeeManager.FeeWithQuoteRequest calldata request)
        external
        pure
        returns (IFeeManager.QuoteItem memory item, uint256 itemIndex, bool matched)
    {
        IFeeManager.Quote memory q = quote;
        return q.findItemForRequest(request);
    }

    function sumFees(IFeeManager.Quote calldata quote, string[] calldata quoteTypes)
        external
        pure
        returns (uint256 totalFee, address feeToken)
    {
        IFeeManager.Quote memory q = quote;
        return q.sumFees(quoteTypes);
    }
}

contract QuoteLibTest is Test {
    QuoteLibHarness internal harness;

    function setUp() public {
        harness = new QuoteLibHarness();
    }

    function test_validate_timestampMode_succeedsAtDeadline() public view {
        uint256 encoded = block.timestamp; // mode 0, deadline == now
        harness.validateExpiry(encoded);
    }

    function test_validate_timestampMode_succeedsBeforeDeadline() public view {
        uint256 encoded = block.timestamp + 1 days;
        harness.validateExpiry(encoded);
    }

    function test_validate_timestampMode_revertsAfterDeadline() public {
        uint256 deadline = block.timestamp - 1;
        uint256 encoded = deadline; // mode 0
        vm.expectRevert(abi.encodeWithSelector(QuoteLib.QuoteExpired.selector, uint8(0), deadline, block.timestamp));
        harness.validateExpiry(encoded);
    }

    function test_validate_blockNumberMode_succeedsAtDeadline() public view {
        uint256 encoded = (uint256(1) << 248) | block.number;
        harness.validateExpiry(encoded);
    }

    function test_validate_blockNumberMode_succeedsBeforeDeadline() public view {
        uint256 encoded = (uint256(1) << 248) | (block.number + 100);
        harness.validateExpiry(encoded);
    }

    function test_validate_blockNumberMode_revertsAfterDeadline() public {
        uint256 deadline = block.number - 1;
        uint256 encoded = (uint256(1) << 248) | deadline;
        vm.expectRevert(abi.encodeWithSelector(QuoteLib.QuoteExpired.selector, uint8(1), deadline, block.number));
        harness.validateExpiry(encoded);
    }

    function test_validate_unsupportedMode_reverts(uint8 modeRaw) public {
        uint8 mode = uint8(bound(uint256(modeRaw), 2, type(uint8).max));
        uint256 encoded = (uint256(mode) << 248) | uint256(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(QuoteLib.UnsupportedExpiryMode.selector, mode));
        harness.validateExpiry(encoded);
    }

    function test_mustNotExpire_matchesValidate() public view {
        uint256 deadline = block.timestamp + 1;
        IFeeManager.QuoteItem[] memory items;
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: deadline, feeToken: address(0), nonce: 0, signature: ""});
        harness.mustNotExpire(quote);
    }

    function test_mustNotExpire_revertsWhenValidateWould() public {
        uint256 deadline = block.timestamp - 1;
        IFeeManager.QuoteItem[] memory items;
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: deadline, feeToken: address(0), nonce: 0, signature: ""});
        vm.expectRevert(abi.encodeWithSelector(QuoteLib.QuoteExpired.selector, uint8(0), deadline, block.timestamp));
        harness.mustNotExpire(quote);
    }

    function test_validate_timestampMode_warpAffectsExpiry() public {
        uint256 deadline = 1000;
        uint256 encoded = deadline;
        vm.warp(999);
        harness.validateExpiry(encoded);
        vm.warp(1001);
        vm.expectRevert(abi.encodeWithSelector(QuoteLib.QuoteExpired.selector, uint8(0), deadline, uint256(1001)));
        harness.validateExpiry(encoded);
    }

    function test_validate_blockNumberMode_rollAffectsExpiry() public {
        uint256 deadline = 10;
        uint256 encoded = (uint256(1) << 248) | deadline;
        vm.roll(9);
        harness.validateExpiry(encoded);
        vm.roll(11);
        vm.expectRevert(abi.encodeWithSelector(QuoteLib.QuoteExpired.selector, uint8(1), deadline, uint256(11)));
        harness.validateExpiry(encoded);
    }

    function test_findItemByType_emptyItems_notFound() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});
        (IFeeManager.QuoteItem memory item, uint256 itemIndex, bool matched) = harness.findItemByType(quote, "FORWARD");
        assertFalse(matched);
        assertEq(itemIndex, 0);
        assertEq(item.amount, 0);
    }

    function test_findItemByType_returnsFirstOfType() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: bytes32(uint256(1)), amount: 10});
        items[1] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: bytes32(uint256(2)), amount: 20});
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});
        (IFeeManager.QuoteItem memory item, uint256 itemIndex, bool matched) = harness.findItemByType(quote, "A");
        assertTrue(matched);
        assertEq(itemIndex, 0);
        assertEq(item.amount, 10);
        assertEq(item.quoteArgsHash, bytes32(uint256(1)));
    }

    function test_findItemByType_noSuchType() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: "B", quoteArgsHash: bytes32(0), amount: 1});
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});
        (,, bool matched) = harness.findItemByType(quote, "A");
        assertFalse(matched);
    }

    function test_hashQuoteArgs_matchesRequest_consistent() public view {
        string[] memory args = new string[](1);
        args[0] = "x";
        bytes32 h = harness.hashQuoteArgs(args);
        IFeeManager.QuoteItem memory item = IFeeManager.QuoteItem({quoteType: "T", quoteArgsHash: h, amount: 1});
        assertTrue(harness.matchesRequest(item, args));
        string[] memory other = new string[](1);
        other[0] = "y";
        assertFalse(harness.matchesRequest(item, other));
    }

    function test_totalFeeAndFeeToken_emptyItems() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        address token = address(uint160(0xBEEF));
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: token, nonce: 0, signature: ""});
        (uint256 total, address ft) = harness.totalFeeAndFeeToken(quote);
        assertEq(total, 0);
        assertEq(ft, token);
    }

    function test_hasItemType_findsType() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: "FORWARD", quoteArgsHash: bytes32(0), amount: 1});
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});
        assertTrue(harness.hasItemType(quote, "FORWARD"));
        assertFalse(harness.hasItemType(quote, "PRE_FINALITY"));
    }

    function test_requireSupportedItemCount_revertsTooManyQuoteItems() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](257);
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});

        vm.expectRevert(abi.encodeWithSelector(IFeeManager.TooManyQuoteItems.selector, uint256(257)));
        harness.requireSupportedItemCount(quote);
    }

    function test_totalFeeAndFeeToken_sumsAmounts() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: bytes32(0), amount: 100});
        items[1] = IFeeManager.QuoteItem({quoteType: "B", quoteArgsHash: bytes32(0), amount: 5});
        address token = address(uint160(0xCAFE));
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: token, nonce: 0, signature: ""});
        (uint256 total, address ft) = harness.totalFeeAndFeeToken(quote);
        assertEq(total, 105);
        assertEq(ft, token);
    }

    function test_findItemForRequest_optionalMissing_returnsUnmatched() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});

        string[] memory args = new string[](1);
        args[0] = "x";
        IFeeManager.FeeWithQuoteRequest memory request =
            IFeeManager.FeeWithQuoteRequest({quoteType: "A", quoteArgs: args, required: false});

        (IFeeManager.QuoteItem memory item, uint256 itemIndex, bool matched) =
            harness.findItemForRequest(quote, request);
        assertFalse(matched);
        assertEq(itemIndex, 0);
        assertEq(item.amount, 0);
    }

    function test_findItemForRequest_requiredMissing_revertsRequiredFeeNotInQuote() public {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](0);
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});

        string[] memory args = new string[](1);
        args[0] = "x";
        IFeeManager.FeeWithQuoteRequest memory request =
            IFeeManager.FeeWithQuoteRequest({quoteType: "A", quoteArgs: args, required: true});

        bytes32 wantedHash = keccak256(abi.encode(args));
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.RequiredFeeNotInQuote.selector, "A", wantedHash));
        harness.findItemForRequest(quote, request);
    }

    function test_findItemForRequest_argsMismatch_revertsQuoteArgsMismatch() public {
        string[] memory quotedArgs = new string[](1);
        quotedArgs[0] = "quoted";
        string[] memory wantedArgs = new string[](1);
        wantedArgs[0] = "wanted";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: keccak256(abi.encode(quotedArgs)), amount: 10});
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});

        IFeeManager.FeeWithQuoteRequest memory request =
            IFeeManager.FeeWithQuoteRequest({quoteType: "A", quoteArgs: wantedArgs, required: false});

        bytes32 wantedHash = keccak256(abi.encode(wantedArgs));
        vm.expectRevert(abi.encodeWithSelector(IFeeManager.QuoteArgsMismatch.selector, "A", wantedHash));
        harness.findItemForRequest(quote, request);
    }

    function test_findItemForRequest_argsMatch_returnsItem() public view {
        string[] memory args = new string[](1);
        args[0] = "a";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: keccak256(abi.encode(args)), amount: 7});
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: address(0), nonce: 0, signature: ""});

        IFeeManager.FeeWithQuoteRequest memory request =
            IFeeManager.FeeWithQuoteRequest({quoteType: "A", quoteArgs: args, required: true});

        (IFeeManager.QuoteItem memory item, uint256 itemIndex, bool matched) =
            harness.findItemForRequest(quote, request);
        assertTrue(matched);
        assertEq(itemIndex, 0);
        assertEq(item.amount, 7);
    }

    function test_sumFees_sumsRequestedQuoteTypesOnly() public view {
        string[] memory args = new string[](1);
        args[0] = "a";

        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: keccak256(abi.encode(args)), amount: 10});
        items[1] = IFeeManager.QuoteItem({quoteType: "B", quoteArgsHash: bytes32(0), amount: 20});
        address token = address(uint160(0xCAFE));
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: token, nonce: 0, signature: ""});

        string[] memory quoteTypes = new string[](1);
        quoteTypes[0] = "A";

        (uint256 totalFee, address feeToken) = harness.sumFees(quote, quoteTypes);
        assertEq(totalFee, 10);
        assertEq(feeToken, token);
    }

    function test_sumFees_dedupsDuplicateQuoteTypes() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](2);
        items[0] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: bytes32(0), amount: 10});
        items[1] = IFeeManager.QuoteItem({quoteType: "B", quoteArgsHash: bytes32(0), amount: 20});
        address token = address(uint160(0xCAFE));
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: token, nonce: 0, signature: ""});

        // "A" appears twice, "B" once: the duplicate "A" must not be double-counted.
        string[] memory quoteTypes = new string[](3);
        quoteTypes[0] = "A";
        quoteTypes[1] = "B";
        quoteTypes[2] = "A";

        (uint256 totalFee, address feeToken) = harness.sumFees(quote, quoteTypes);
        assertEq(totalFee, 30);
        assertEq(feeToken, token);
    }

    function test_sumFees_dedupOnlyMatchedTypes() public view {
        IFeeManager.QuoteItem[] memory items = new IFeeManager.QuoteItem[](1);
        items[0] = IFeeManager.QuoteItem({quoteType: "A", quoteArgsHash: bytes32(0), amount: 10});
        address token = address(uint160(0xCAFE));
        IFeeManager.Quote memory quote =
            IFeeManager.Quote({items: items, expiry: 0, feeToken: token, nonce: 0, signature: ""});

        // Repeated unmatched types do not contribute regardless of dedup.
        string[] memory quoteTypes = new string[](3);
        quoteTypes[0] = "MISSING";
        quoteTypes[1] = "A";
        quoteTypes[2] = "MISSING";

        (uint256 totalFee, address feeToken) = harness.sumFees(quote, quoteTypes);
        assertEq(totalFee, 10);
        assertEq(feeToken, token);
    }
}
