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

import {WithFeeCollectionAddress} from "../src/access/WithFeeCollectionAddress.sol";
import {Roles} from "../src/constants/Roles.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test, Vm} from "forge-std/Test.sol";

/// @dev Minimal concrete contract for exercising `WithFeeCollectionAddress`.
contract WithFeeCollectionAddressHarness is WithFeeCollectionAddress {
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.FEE_COLLECTION_ADMIN_ROLE, admin);
    }

    function exposedFeeCollectionAddress() external view returns (address payable) {
        return _feeCollectionAddress();
    }
}

contract WithFeeCollectionAddressTest is Test {
    WithFeeCollectionAddressHarness internal harness;

    address internal admin = makeAddr("admin");
    address payable internal feeCollector1 = payable(makeAddr("feeCollector1"));
    address payable internal feeCollector2 = payable(makeAddr("feeCollector2"));
    address internal stranger = makeAddr("stranger");

    event FeeCollectionAddressSet(address indexed feeCollectionAddress);

    function setUp() public {
        WithFeeCollectionAddressHarness impl = new WithFeeCollectionAddressHarness();
        bytes memory initData = abi.encodeCall(WithFeeCollectionAddressHarness.initialize, (admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        harness = WithFeeCollectionAddressHarness(address(proxy));
    }

    // ───────────────────── setFeeCollectionAddress ─────────────────────

    function test_setFeeCollectionAddress_sets() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit FeeCollectionAddressSet(feeCollector1);
        harness.setFeeCollectionAddress(feeCollector1);

        assertEq(harness.feeCollectionAddress(), feeCollector1);
        assertEq(harness.exposedFeeCollectionAddress(), feeCollector1);
    }

    function test_setFeeCollectionAddress_overwritesPrevious() public {
        vm.prank(admin);
        harness.setFeeCollectionAddress(feeCollector1);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit FeeCollectionAddressSet(feeCollector2);
        harness.setFeeCollectionAddress(feeCollector2);

        assertEq(harness.feeCollectionAddress(), feeCollector2);
    }

    function test_setFeeCollectionAddress_clearsToZero() public {
        vm.prank(admin);
        harness.setFeeCollectionAddress(feeCollector1);
        assertEq(harness.feeCollectionAddress(), feeCollector1);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit FeeCollectionAddressSet(address(0));
        harness.setFeeCollectionAddress(payable(address(0)));

        assertEq(harness.feeCollectionAddress(), address(0));
    }

    function test_setFeeCollectionAddress_noop_whenValueUnchanged_doesNotEmit() public {
        vm.prank(admin);
        harness.setFeeCollectionAddress(feeCollector1);

        vm.recordLogs();
        vm.prank(admin);
        harness.setFeeCollectionAddress(feeCollector1);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(_countFeeCollectionAddressSet(entries), 0, "no-op call must not emit FeeCollectionAddressSet");
        assertEq(harness.feeCollectionAddress(), feeCollector1);
    }

    function test_setFeeCollectionAddress_noop_settingZeroFromUnset_doesNotEmit() public {
        vm.recordLogs();
        vm.prank(admin);
        harness.setFeeCollectionAddress(payable(address(0)));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(_countFeeCollectionAddressSet(entries), 0, "no-op call must not emit FeeCollectionAddressSet");
        assertEq(harness.feeCollectionAddress(), address(0));
    }

    function _countFeeCollectionAddressSet(Vm.Log[] memory entries) private pure returns (uint256 count) {
        bytes32 sig = keccak256("FeeCollectionAddressSet(address)");
        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == sig) {
                ++count;
            }
        }
    }

    function test_setFeeCollectionAddress_revertsForNonFeeCollectionAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, Roles.FEE_COLLECTION_ADMIN_ROLE
            )
        );
        harness.setFeeCollectionAddress(feeCollector1);
    }

    function test_setFeeCollectionAddress_revertsWhenDefaultAdminLacksFeeCollectionAdmin() public {
        address defaultAdminOnly = makeAddr("defaultAdminOnly");
        WithFeeCollectionAddressHarness impl = new WithFeeCollectionAddressHarness();
        bytes memory initData = abi.encodeCall(WithFeeCollectionAddressHarness.initialize, (defaultAdminOnly));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        WithFeeCollectionAddressHarness fresh = WithFeeCollectionAddressHarness(address(proxy));

        vm.prank(defaultAdminOnly);
        fresh.revokeRole(Roles.FEE_COLLECTION_ADMIN_ROLE, defaultAdminOnly);

        vm.prank(defaultAdminOnly);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                defaultAdminOnly,
                Roles.FEE_COLLECTION_ADMIN_ROLE
            )
        );
        fresh.setFeeCollectionAddress(feeCollector1);
    }

    // ───────────────────── feeCollectionAddress ─────────────────────

    function test_feeCollectionAddress_zeroByDefault() public view {
        assertEq(harness.feeCollectionAddress(), address(0));
        assertEq(harness.exposedFeeCollectionAddress(), address(0));
    }
}
