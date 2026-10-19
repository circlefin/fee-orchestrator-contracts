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

import {HookDataLib} from "../src/libraries/HookDataLib.sol";
import {Test} from "forge-std/Test.sol";

contract HookDataHarness {
    function getForwardHook(bytes calldata hookData) external pure returns (HookDataLib.Hook memory hook, bool found) {
        return HookDataLib.getForwardHook(hookData);
    }
}

/// @dev Reference hook data from Circle docs:
///      https://developers.circle.com/cctp/concepts/forwarding-service#hook-format
contract HookDataLibTest is Test {
    HookDataHarness internal harness;

    function setUp() public {
        harness = new HookDataHarness();
    }

    /// @dev Static forward hook with version 0 and no Circle data, as documented.
    bytes internal constant STATIC_FORWARD_HOOK = hex"636374702d666f72776172640000000000000000000000000000000000000000";

    // ─────────────── helpers ───────────────

    function _buildHook(bytes24 name, uint32 version, bytes memory circleData) internal pure returns (bytes memory) {
        return abi.encodePacked(name, version, uint32(circleData.length), circleData);
    }

    // ───────────────────── single hook ─────────────────────

    function test_getForwardHook_staticHook_found() public view {
        (HookDataLib.Hook memory hook, bool found) = harness.getForwardHook(STATIC_FORWARD_HOOK);
        assertTrue(found);
        assertEq(hook.name, HookDataLib.FORWARD_MAGIC);
        assertEq(hook.version, 0);
        assertEq(hook.circleData.length, 0);
    }

    function test_getForwardHook_withCircleData_returnsData() public view {
        bytes memory circleData = hex"aabbccdd";
        bytes memory hookData = _buildHook(HookDataLib.FORWARD_MAGIC, 0, circleData);
        (HookDataLib.Hook memory hook, bool found) = harness.getForwardHook(hookData);
        assertTrue(found);
        assertEq(hook.circleData, circleData);
    }

    function test_getForwardHook_withVersion_parsesVersion() public view {
        bytes memory hookData = _buildHook(HookDataLib.FORWARD_MAGIC, 3, "");
        (HookDataLib.Hook memory hook, bool found) = harness.getForwardHook(hookData);
        assertTrue(found);
        assertEq(hook.version, 3);
    }

    function test_getForwardHook_emptyData_notFound() public view {
        (, bool found) = harness.getForwardHook("");
        assertFalse(found);
    }

    function test_getForwardHook_tooShort_notFound() public view {
        (, bool found) = harness.getForwardHook(hex"636374702d666f7277617264000000000000000000000000000000000000");
        assertFalse(found);
    }

    function test_getForwardHook_wrongMagic_notFound() public view {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory hookData = _buildHook(bytes24("not-forward"), 0, "");
        (, bool found) = harness.getForwardHook(hookData);
        assertFalse(found);
    }

    function test_getForwardHook_truncatedCircleData_notFound() public view {
        // Header claims 10 bytes of circle data but only 2 are present
        bytes memory hookData = abi.encodePacked(HookDataLib.FORWARD_MAGIC, uint32(0), uint32(10), hex"aabb");
        (, bool found) = harness.getForwardHook(hookData);
        assertFalse(found);
    }

    // ───────────────────── chained hooks ─────────────────────

    function test_getForwardHook_secondHook_found() public view {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory otherHook = _buildHook(bytes24("some-other-hook"), 1, hex"ff");
        bytes memory forwardHook = _buildHook(HookDataLib.FORWARD_MAGIC, 2, hex"cafe");
        bytes memory hookData = abi.encodePacked(otherHook, forwardHook);

        (HookDataLib.Hook memory hook, bool found) = harness.getForwardHook(hookData);
        assertTrue(found);
        assertEq(hook.name, HookDataLib.FORWARD_MAGIC);
        assertEq(hook.version, 2);
        assertEq(hook.circleData, hex"cafe");
    }

    function test_getForwardHook_thirdHook_found() public view {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory hookA = _buildHook(bytes24("hook-a"), 0, hex"01");
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory hookB = _buildHook(bytes24("hook-b"), 0, hex"0203");
        bytes memory forwardHook = _buildHook(HookDataLib.FORWARD_MAGIC, 0, "");
        bytes memory hookData = abi.encodePacked(hookA, hookB, forwardHook);

        (, bool found) = harness.getForwardHook(hookData);
        assertTrue(found);
    }

    function test_getForwardHook_firstOfMultiple_returnsFirst() public view {
        bytes memory forwardHook = _buildHook(HookDataLib.FORWARD_MAGIC, 5, hex"ab");
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory otherHook = _buildHook(bytes24("other"), 0, "");
        bytes memory hookData = abi.encodePacked(forwardHook, otherHook);

        (HookDataLib.Hook memory hook, bool found) = harness.getForwardHook(hookData);
        assertTrue(found);
        assertEq(hook.version, 5);
    }

    function test_getForwardHook_noForwardAmongOthers_notFound() public view {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory hookA = _buildHook(bytes24("hook-a"), 0, "");
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory hookB = _buildHook(bytes24("hook-b"), 0, hex"dead");
        bytes memory hookData = abi.encodePacked(hookA, hookB);

        (, bool found) = harness.getForwardHook(hookData);
        assertFalse(found);
    }

    function test_getForwardHook_backwardsCompatible_singleHookStillWorks() public view {
        // Single hook with no chaining — the original format
        (HookDataLib.Hook memory hook, bool found) = harness.getForwardHook(STATIC_FORWARD_HOOK);
        assertTrue(found);
        assertEq(hook.name, HookDataLib.FORWARD_MAGIC);
        assertEq(hook.version, 0);
        assertEq(hook.circleData.length, 0);
    }

    // ───────────────────── fuzz ─────────────────────

    function testFuzz_getForwardHook_validForward_roundtrips(uint32 version, bytes memory circleData) public view {
        bytes memory hookData = _buildHook(HookDataLib.FORWARD_MAGIC, version, circleData);
        (HookDataLib.Hook memory hook, bool found) = harness.getForwardHook(hookData);
        assertTrue(found);
        assertEq(hook.name, HookDataLib.FORWARD_MAGIC);
        assertEq(hook.version, version);
        assertEq(hook.circleData, circleData);
    }

    function testFuzz_getForwardHook_afterOtherHook_found(
        bytes24 otherName,
        uint32 otherVersion,
        bytes memory otherCircleData,
        uint32 fwdVersion
    ) public view {
        vm.assume(otherName != HookDataLib.FORWARD_MAGIC);
        bytes memory hookData = abi.encodePacked(
            _buildHook(otherName, otherVersion, otherCircleData), _buildHook(HookDataLib.FORWARD_MAGIC, fwdVersion, "")
        );

        (HookDataLib.Hook memory hook, bool found) = harness.getForwardHook(hookData);
        assertTrue(found);
        assertEq(hook.version, fwdVersion);
    }
}
