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
import {TokenMessengerWithFees} from "../../src/contracts/TokenMessengerWithFees.sol";
import {Addresses} from "./Addresses.sol";
import {Broadcaster} from "./Broadcaster.sol";
import {Salts} from "./Salts.sol";
import {Script, console} from "forge-std/Script.sol";

/// @dev Parameters for deploying a new TokenMessengerWithFees implementation via CREATE3.
struct UpgradeTmwfImplConfig {
    Create3Factory factory;
    bytes32 implSalt;
    address tokenMessengerV2;
    address feeManagerProxy;
}

/// @title UpgradeTokenMessengerWithFees
/// @notice Deploys a new `TokenMessengerWithFees` implementation via `Create3Factory` and/or upgrades the UUPS proxy.
///
/// Bump `TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT` before deploying a new implementation so CREATE3 does not
/// collide with the previous implementation.
///
/// Required env vars (all flows, one of):
///   DEPLOYER_PRIVATE_KEY           – private key used to broadcast transactions
///   DEPLOYER_ADDRESS               – address for unlocked-account mode (Anvil)
///
///   CREATE3_FACTORY_ADDRESS
///   TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT
///   TOKEN_MESSENGER_V2_ADDRESS
///
/// Optional:
///   FEE_MANAGER_PROXY_ADDRESS      – FeeManager UUPS proxy for the new implementation's immutable `feeManager`.
///                                    If unset, `Addresses.feeManagerProxy()` derives it from
///                                    `FEE_MANAGER_PROXY_SALT` + `CREATE3_FACTORY_ADDRESS`.
///
/// Additional for `run()` and `upgradeProxyOnly()`:
///   TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS
///
/// Additional for `upgradeProxyOnly()` when the implementation was deployed out-of-band:
///   TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_ADDRESS
contract UpgradeTokenMessengerWithFees is Script {
    address public implementation;

    // ── Deploy implementation only ──────────────────────────────────────

    /// @notice Deploy a new implementation (reads config from env vars).
    function deployImplementationOnly() external {
        deployImplementationOnlyWithConfig(_loadImplConfigFromEnv());
    }

    /// @notice Deploy a new implementation (explicit config — for tests).
    function deployImplementationOnlyWithConfig(UpgradeTmwfImplConfig memory config) public {
        Broadcaster.startBroadcast();
        implementation = _deployImplementation(config);
        vm.stopBroadcast();
        console.log("TokenMessengerWithFees implementation:", implementation);
    }

    // ── Upgrade proxy only ──────────────────────────────────────────────

    /// @notice Upgrade the proxy to `TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_ADDRESS` (reads from env).
    function upgradeProxyOnly() external {
        upgradeProxyOnlyWithConfig(
            vm.envAddress("TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS"),
            vm.envAddress("TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_ADDRESS")
        );
    }

    /// @notice Upgrade the proxy to a specific implementation (explicit params — for tests).
    function upgradeProxyOnlyWithConfig(address proxy, address impl) public {
        Broadcaster.startBroadcast();
        TokenMessengerWithFees(proxy).upgradeToAndCall(impl, "");
        vm.stopBroadcast();
        console.log("TokenMessengerWithFees proxy upgraded:", proxy);
        console.log("New implementation:", impl);
    }

    // ── Deploy implementation + upgrade proxy ───────────────────────────

    /// @notice Deploy implementation then upgrade proxy (reads from env).
    function run() external {
        runWithConfig(_loadImplConfigFromEnv(), vm.envAddress("TOKEN_MESSENGER_WITH_FEES_PROXY_ADDRESS"));
    }

    /// @notice Deploy implementation then upgrade proxy (explicit config — for tests).
    function runWithConfig(UpgradeTmwfImplConfig memory config, address proxy) public {
        Broadcaster.startBroadcast();
        implementation = _deployImplementation(config);
        TokenMessengerWithFees(proxy).upgradeToAndCall(implementation, "");
        vm.stopBroadcast();
        console.log("TokenMessengerWithFees implementation:", implementation);
        console.log("TokenMessengerWithFees proxy:", proxy);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _loadImplConfigFromEnv() private view returns (UpgradeTmwfImplConfig memory c) {
        c.factory = Create3Factory(vm.envAddress("CREATE3_FACTORY_ADDRESS"));
        c.implSalt = Salts.tokenMessengerWithFeesImpl();
        c.tokenMessengerV2 = vm.envAddress("TOKEN_MESSENGER_V2_ADDRESS");
        c.feeManagerProxy = Addresses.feeManagerProxy();
    }

    function _deployImplementation(UpgradeTmwfImplConfig memory c) private returns (address) {
        console.log("TokenMessengerWithFees impl uses feeManager immutable:", c.feeManagerProxy);
        return c.factory
            .deploy(
                c.implSalt,
                abi.encodePacked(
                    type(TokenMessengerWithFees).creationCode, abi.encode(c.tokenMessengerV2, c.feeManagerProxy)
                )
            );
    }
}
