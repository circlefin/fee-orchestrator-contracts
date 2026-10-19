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

import {WithTrustedQuoteSigners} from "../src/access/WithTrustedQuoteSigners.sol";
import {Roles} from "../src/constants/Roles.sol";
import {IWithTrustedQuoteSigners} from "../src/interfaces/IWithTrustedQuoteSigners.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Minimal concrete contract for exercising `WithTrustedQuoteSigners`.
contract WithTrustedQuoteSignersHarness is WithTrustedQuoteSigners {
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.SIGNER_ADMIN_ROLE, admin);
    }
}

contract WithTrustedQuoteSignersTest is Test {
    WithTrustedQuoteSignersHarness internal harness;

    address internal admin = makeAddr("admin");
    address internal signer1 = makeAddr("signer1");
    address internal signer2 = makeAddr("signer2");
    address internal stranger = makeAddr("stranger");

    event TrustedQuoteSignerSet(address indexed signer, bool trusted);

    function setUp() public {
        WithTrustedQuoteSignersHarness impl = new WithTrustedQuoteSignersHarness();
        bytes memory initData = abi.encodeCall(WithTrustedQuoteSignersHarness.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        harness = WithTrustedQuoteSignersHarness(address(proxy));
    }

    // ───────────────────── setTrustedQuoteSigner ─────────────────────

    function test_setTrustedQuoteSigner_addsSigner() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit TrustedQuoteSignerSet(signer1, true);
        harness.setTrustedQuoteSigner(signer1, true);

        assertTrue(harness.isTrustedQuoteSigner(signer1));
    }

    function test_setTrustedQuoteSigner_removesSigner() public {
        vm.prank(admin);
        harness.setTrustedQuoteSigner(signer1, true);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit TrustedQuoteSignerSet(signer1, false);
        harness.setTrustedQuoteSigner(signer1, false);

        assertFalse(harness.isTrustedQuoteSigner(signer1));
    }

    function test_setTrustedQuoteSigner_multipleSigners() public {
        vm.startPrank(admin);
        harness.setTrustedQuoteSigner(signer1, true);
        harness.setTrustedQuoteSigner(signer2, true);
        vm.stopPrank();

        assertTrue(harness.isTrustedQuoteSigner(signer1));
        assertTrue(harness.isTrustedQuoteSigner(signer2));
    }

    function test_setTrustedQuoteSigner_removingOneLeavesOthersTrusted() public {
        vm.startPrank(admin);
        harness.setTrustedQuoteSigner(signer1, true);
        harness.setTrustedQuoteSigner(signer2, true);
        harness.setTrustedQuoteSigner(signer1, false);
        vm.stopPrank();

        assertFalse(harness.isTrustedQuoteSigner(signer1));
        assertTrue(harness.isTrustedQuoteSigner(signer2));
    }

    function test_setTrustedQuoteSigner_idempotentAdd() public {
        vm.startPrank(admin);
        harness.setTrustedQuoteSigner(signer1, true);
        harness.setTrustedQuoteSigner(signer1, true);
        vm.stopPrank();

        assertTrue(harness.isTrustedQuoteSigner(signer1));

        vm.prank(admin);
        harness.setTrustedQuoteSigner(signer1, false);
        assertFalse(harness.isTrustedQuoteSigner(signer1));
    }

    function test_setTrustedQuoteSigner_idempotentRemove() public {
        vm.prank(admin);
        harness.setTrustedQuoteSigner(signer1, false);
        assertFalse(harness.isTrustedQuoteSigner(signer1));
    }

    function test_setTrustedQuoteSigner_revertsForZeroSigner() public {
        vm.prank(admin);
        vm.expectRevert(IWithTrustedQuoteSigners.ZeroTrustedQuoteSignerAddress.selector);
        harness.setTrustedQuoteSigner(address(0), true);
    }

    function test_setTrustedQuoteSigner_revertsForNonSignerAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.SIGNER_ADMIN_ROLE
            )
        );
        harness.setTrustedQuoteSigner(signer1, true);
    }

    // ───────────────────── isTrustedQuoteSigner ─────────────────────

    function test_isTrustedQuoteSigner_falseByDefault() public view {
        assertFalse(harness.isTrustedQuoteSigner(signer1));
    }
}
