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

import {DeployCreate3Factory} from "../script/deploy/DeployCreate3Factory.s.sol";
import {Create3Factory} from "../src/contracts/Create3Factory.sol";
import {Test} from "forge-std/Test.sol";

contract DeployCreate3FactoryTest is Test {
    /// @dev Anvil default account #0
    uint256 internal constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    DeployCreate3Factory internal script;
    Create3Factory internal factory;
    address internal deployer;

    function setUp() public {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_PK));
        script = new DeployCreate3Factory();
        script.run();
        factory = script.factory();
        deployer = vm.addr(DEPLOYER_PK);
    }

    function test_deploy_setsOwnerToDeployer() public view {
        assertEq(factory.owner(), deployer);
    }

    function test_deploy_factoryAddressIsNonZero() public view {
        assertTrue(address(factory) != address(0));
    }
}
