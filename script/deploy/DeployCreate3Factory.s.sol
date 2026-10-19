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

import {Create3Factory} from "../../src/contracts/Create3Factory.sol";
import {Broadcaster} from "./Broadcaster.sol";
import {Script, console} from "forge-std/Script.sol";

/// @title DeployCreate3Factory
/// @notice Deploys the Create3Factory and sets the deployer as the initial
///         owner. This factory must be deployed once per chain before any
///         other Fee Orchestrator contract deployments.
///
/// Required env vars (one of):
///   DEPLOYER_PRIVATE_KEY  – private key used to broadcast transactions
///   DEPLOYER_ADDRESS      – address for unlocked-account mode (Anvil)
contract DeployCreate3Factory is Script {
    Create3Factory public factory;

    function run() external {
        address deployer = Broadcaster.startBroadcast();
        factory = new Create3Factory(deployer);

        vm.stopBroadcast();

        console.log("Create3Factory:", address(factory));
        console.log("Owner:", factory.owner());
    }
}
