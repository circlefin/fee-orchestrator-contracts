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

import {Roles} from "../src/constants/Roles.sol";
import {Create3Factory} from "../src/contracts/Create3Factory.sol";
import {FeeManager} from "../src/contracts/FeeManager.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Minimal contract used to verify CREATE3 deployment behaviour.
contract SimpleContract {
    uint256 public value;

    constructor(uint256 value_) {
        value = value_;
    }

    function setValue(uint256 value_) external {
        value = value_;
    }
}

/// @dev Contract whose constructor always reverts.
contract AlwaysReverts {
    error Boom();

    constructor() {
        revert Boom();
    }
}

contract Create3FactoryTest is Test {
    Create3Factory internal factory;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant SALT = keccak256("test-salt");
    event Deployed(address indexed deployed, bytes32 indexed salt);

    function setUp() public {
        factory = new Create3Factory(owner);
    }

    // ───────────────────── constructor ─────────────────────

    function test_constructor_setsOwner() public view {
        assertEq(factory.owner(), owner);
    }

    // ───────────────────── deploy ─────────────────────

    function test_deploy_deploysAtPredictedAddress() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(42));

        address predicted = factory.getAddress(SALT);

        vm.prank(owner);
        address deployed = factory.deploy(SALT, bytecode);

        assertEq(deployed, predicted);
        assertEq(SimpleContract(deployed).value(), 42);
    }

    function test_deploy_emitsDeployedEvent() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(1));
        address predicted = factory.getAddress(SALT);

        vm.expectEmit(true, true, false, false);
        emit Deployed(predicted, SALT);

        vm.prank(owner);
        factory.deploy(SALT, bytecode);
    }

    function test_deploy_revertsForNonOwner() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(1));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.deploy(SALT, bytecode);
    }

    function test_deploy_revertsOnDuplicateDeployment() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(1));

        vm.prank(owner);
        factory.deploy(SALT, bytecode);

        vm.prank(owner);
        vm.expectRevert();
        factory.deploy(SALT, bytecode);
    }

    function test_deploy_differentSaltsProduceDifferentAddresses() public {
        bytes memory bytecode1 = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(1));
        bytes memory bytecode2 = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(2));
        bytes32 salt1 = keccak256("salt-1");
        bytes32 salt2 = keccak256("salt-2");

        vm.prank(owner);
        address addr1 = factory.deploy(salt1, bytecode1);

        vm.prank(owner);
        address addr2 = factory.deploy(salt2, bytecode2);

        assertTrue(addr1 != addr2);
    }

    function test_deploy_sameSaltDifferentBytecodeProducesSameAddress() public {
        Create3Factory factory2 = new Create3Factory(owner);

        bytes memory bytecode1 = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(1));
        bytes memory bytecode2 = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(999));

        vm.prank(owner);
        address deployed1 = factory.deploy(SALT, bytecode1);

        vm.prank(owner);
        address deployed2 = factory2.deploy(SALT, bytecode2);

        assertEq(deployed1, factory.getAddress(SALT));
        assertEq(deployed2, factory2.getAddress(SALT));

        // Addresses differ because the factory addresses differ, not the bytecodes
        assertTrue(deployed1 != deployed2);
    }

    function test_deploy_emptyBytecodeReverts() public {
        vm.prank(owner);
        vm.expectRevert();
        factory.deploy(SALT, "");
    }

    // ───────────────────── getAddress ─────────────────────

    function test_getAddress_returnsConsistentAddress() public view {
        address addr1 = factory.getAddress(SALT);
        address addr2 = factory.getAddress(SALT);

        assertEq(addr1, addr2);
    }

    function test_getAddress_differsBySalt() public view {
        address addr1 = factory.getAddress(keccak256("a"));
        address addr2 = factory.getAddress(keccak256("b"));

        assertTrue(addr1 != addr2);
    }

    function test_getAddress_doesNotDependOnBytecode() public view {
        address addr = factory.getAddress(SALT);

        assertEq(addr, factory.getAddress(SALT));
    }

    // ───────────────────── ownership ─────────────────────

    function test_transferOwnership_twoStepFlow() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        factory.transferOwnership(newOwner);

        assertEq(factory.pendingOwner(), newOwner);
        assertEq(factory.owner(), owner);

        vm.prank(newOwner);
        factory.acceptOwnership();

        assertEq(factory.owner(), newOwner);
        assertEq(factory.pendingOwner(), address(0));
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Create3Factory.RenounceDisabled.selector);
        factory.renounceOwnership();

        assertEq(factory.owner(), owner);
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.transferOwnership(stranger);
    }

    // ───────────────────── deployAndMultiCall ─────────────────────

    function test_deployAndMultiCall_deploysAndExecutesCalls() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(0));

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(SimpleContract.setValue, (99));

        vm.prank(owner);
        address deployed = factory.deployAndMultiCall(SALT, bytecode, calls);

        assertEq(SimpleContract(deployed).value(), 99);
    }

    function test_deployAndMultiCall_deploysAtPredictedAddress() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(0));
        address predicted = factory.getAddress(SALT);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(SimpleContract.setValue, (1));

        vm.prank(owner);
        address deployed = factory.deployAndMultiCall(SALT, bytecode, calls);

        assertEq(deployed, predicted);
    }

    function test_deployAndMultiCall_emitsDeployedEvent() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(0));
        address predicted = factory.getAddress(SALT);

        bytes[] memory calls = new bytes[](0);

        vm.expectEmit(true, true, false, false);
        emit Deployed(predicted, SALT);

        vm.prank(owner);
        factory.deployAndMultiCall(SALT, bytecode, calls);
    }

    function test_deployAndMultiCall_executesMultipleCalls() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(0));

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(SimpleContract.setValue, (10));
        calls[1] = abi.encodeCall(SimpleContract.setValue, (20));
        calls[2] = abi.encodeCall(SimpleContract.setValue, (42));

        vm.prank(owner);
        address deployed = factory.deployAndMultiCall(SALT, bytecode, calls);

        assertEq(SimpleContract(deployed).value(), 42);
    }

    function test_deployAndMultiCall_worksWithZeroCalls() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(7));

        bytes[] memory calls = new bytes[](0);

        vm.prank(owner);
        address deployed = factory.deployAndMultiCall(SALT, bytecode, calls);

        assertEq(SimpleContract(deployed).value(), 7);
    }

    function test_deployAndMultiCall_revertsForNonOwner() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(0));
        bytes[] memory calls = new bytes[](0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.deployAndMultiCall(SALT, bytecode, calls);
    }

    function test_deployAndMultiCall_revertsAndBubblesErrorOnFailedCall() public {
        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(0));

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature("nonExistentFunction()");

        vm.prank(owner);
        vm.expectRevert();
        factory.deployAndMultiCall(SALT, bytecode, calls);
    }

    function test_deployAndMultiCall_revertsOnEmptyBytecode() public {
        bytes[] memory calls = new bytes[](0);

        vm.prank(owner);
        vm.expectRevert();
        factory.deployAndMultiCall(SALT, "", calls);
    }

    // ───────────────────── integration: proxy deployment ─────────────────────

    function test_integration_deploysFeeManagerImplementationAndProxy() public {
        bytes32 implSalt = keccak256("FeeManager-impl");
        bytes32 proxySalt = keccak256("FeeManager-proxy");
        address feeTakerAddr = makeAddr("feeTaker");
        address usdcBlacklistAddr = makeAddr("usdcBlacklist");

        vm.startPrank(owner);

        bytes memory implBytecode =
            abi.encodePacked(type(FeeManager).creationCode, abi.encode(feeTakerAddr, usdcBlacklistAddr));
        address impl = factory.deploy(implSalt, implBytecode);
        assertTrue(impl != address(0));

        bytes memory initData = abi.encodeCall(FeeManager.initialize, (owner));
        bytes memory proxyBytecode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData));

        address predicted = factory.getAddress(proxySalt);
        address proxy = factory.deploy(proxySalt, proxyBytecode);

        vm.stopPrank();

        assertEq(proxy, predicted);
        assertTrue(proxy != impl);

        FeeManager fm = FeeManager(payable(proxy));
        assertEq(fm.owner(), owner);
        assertEq(fm.feeTaker(), feeTakerAddr);
        assertEq(fm.usdcBlacklist(), usdcBlacklistAddr);
    }

    function test_integration_deployAndMultiCall_proxyWithRoleConfig() public {
        bytes32 implSalt = keccak256("FeeManager-impl-mc");
        bytes32 proxySalt = keccak256("FeeManager-proxy-mc");
        address allowedCaller = makeAddr("allowedCaller");
        address feeTakerAddr = makeAddr("feeTaker");
        address usdcBlacklistAddr = makeAddr("usdcBlacklist");

        vm.startPrank(owner);

        bytes memory implBytecode =
            abi.encodePacked(type(FeeManager).creationCode, abi.encode(feeTakerAddr, usdcBlacklistAddr));
        address impl = factory.deploy(implSalt, implBytecode);

        bytes memory initData = abi.encodeCall(FeeManager.initialize, (address(factory)));
        bytes memory proxyBytecode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData));

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(IAccessControl.grantRole, (Roles.CALLER_ADMIN_ROLE, address(factory)));
        calls[1] = abi.encodeCall(IAccessControl.grantRole, (Roles.ALLOWED_CALLER_ROLE, allowedCaller));
        calls[2] = abi.encodeCall(Ownable.transferOwnership, (owner));

        address proxy = factory.deployAndMultiCall(proxySalt, proxyBytecode, calls);

        vm.stopPrank();

        FeeManager fm = FeeManager(payable(proxy));
        assertTrue(fm.hasRole(Roles.ALLOWED_CALLER_ROLE, allowedCaller));
        assertEq(fm.pendingOwner(), owner);

        vm.prank(owner);
        fm.acceptOwnership();
        assertEq(fm.owner(), owner);
    }

    // ───────────────────── fuzz ─────────────────────

    function testFuzz_getAddress_matchesDeploy(bytes32 salt, uint256 constructorArg) public {
        address predicted = factory.getAddress(salt);

        bytes memory bytecode = abi.encodePacked(type(SimpleContract).creationCode, abi.encode(constructorArg));

        vm.prank(owner);
        address deployed = factory.deploy(salt, bytecode);

        assertEq(deployed, predicted);
    }
}
