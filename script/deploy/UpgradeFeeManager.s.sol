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
import {FeeManager} from "../../src/contracts/FeeManager.sol";
import {Broadcaster} from "./Broadcaster.sol";
import {Salts} from "./Salts.sol";
import {Script, console} from "forge-std/Script.sol";

/// @dev Parameters for deploying a new FeeManager implementation via CREATE3.
struct UpgradeFeeManagerImplConfig {
    Create3Factory factory;
    bytes32 implSalt;
    address feeTaker;
    address usdc;
}

/// @title UpgradeFeeManager
/// @notice Deploys a new `FeeManager` implementation via `Create3Factory` and/or upgrades the UUPS proxy.
///
/// Bump `FEE_MANAGER_IMPLEMENTATION_SALT` before deploying a new implementation so CREATE3 does not
/// collide with the previous implementation.
///
/// Required env vars (all flows, one of):
///   DEPLOYER_PRIVATE_KEY           – private key used to broadcast transactions
///   DEPLOYER_ADDRESS               – address for unlocked-account mode (Anvil)
///
///   CREATE3_FACTORY_ADDRESS
///   FEE_MANAGER_IMPLEMENTATION_SALT
///   FEE_TAKER_ADDRESS
///   USDC_ADDRESS
///
/// Additional for `run()` and `upgradeProxyOnly()`:
///   FEE_MANAGER_PROXY_ADDRESS
///
/// Additional for `upgradeProxyOnly()` when the implementation was deployed out-of-band:
///   FEE_MANAGER_IMPLEMENTATION_ADDRESS
contract UpgradeFeeManager is Script {
    address public implementation;

    // ── Deploy implementation only ──────────────────────────────────────

    /// @notice Deploy a new implementation (reads config from env vars).
    function deployImplementationOnly() external {
        deployImplementationOnlyWithConfig(_loadImplConfigFromEnv());
    }

    /// @notice Deploy a new implementation (explicit config — for tests).
    function deployImplementationOnlyWithConfig(UpgradeFeeManagerImplConfig memory config) public {
        Broadcaster.startBroadcast();
        implementation = _deployImplementation(config);
        vm.stopBroadcast();
        console.log("FeeManager implementation:", implementation);
    }

    // ── Upgrade proxy only ──────────────────────────────────────────────

    /// @notice Upgrade the proxy to `FEE_MANAGER_IMPLEMENTATION_ADDRESS` (reads from env).
    function upgradeProxyOnly() external {
        upgradeProxyOnlyWithConfig(
            vm.envAddress("FEE_MANAGER_PROXY_ADDRESS"), vm.envAddress("FEE_MANAGER_IMPLEMENTATION_ADDRESS")
        );
    }

    /// @notice Upgrade the proxy to a specific implementation (explicit params — for tests).
    function upgradeProxyOnlyWithConfig(address proxy, address impl) public {
        Broadcaster.startBroadcast();
        FeeManager(payable(proxy)).upgradeToAndCall(impl, "");
        vm.stopBroadcast();
        console.log("FeeManager proxy upgraded:", proxy);
        console.log("New implementation:", impl);
    }

    // ── Deploy implementation + upgrade proxy ───────────────────────────

    /// @notice Deploy implementation then upgrade `FEE_MANAGER_PROXY_ADDRESS` to it (reads from env).
    function run() external {
        runWithConfig(_loadImplConfigFromEnv(), vm.envAddress("FEE_MANAGER_PROXY_ADDRESS"));
    }

    /// @notice Deploy implementation then upgrade proxy (explicit config — for tests).
    function runWithConfig(UpgradeFeeManagerImplConfig memory config, address proxy) public {
        Broadcaster.startBroadcast();
        implementation = _deployImplementation(config);
        FeeManager(payable(proxy)).upgradeToAndCall(implementation, "");
        vm.stopBroadcast();
        console.log("FeeManager implementation:", implementation);
        console.log("FeeManager proxy:", proxy);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _loadImplConfigFromEnv() private view returns (UpgradeFeeManagerImplConfig memory c) {
        c.factory = Create3Factory(vm.envAddress("CREATE3_FACTORY_ADDRESS"));
        c.implSalt = Salts.feeManagerImpl();
        c.feeTaker = vm.envAddress("FEE_TAKER_ADDRESS");
        c.usdc = vm.envAddress("USDC_ADDRESS");
    }

    function _deployImplementation(UpgradeFeeManagerImplConfig memory c) private returns (address) {
        return
            c.factory
            .deploy(c.implSalt, abi.encodePacked(type(FeeManager).creationCode, abi.encode(c.feeTaker, c.usdc)));
    }
}
