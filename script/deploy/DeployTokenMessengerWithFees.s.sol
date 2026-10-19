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
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script, console} from "forge-std/Script.sol";

struct DeployTokenMessengerWithFeesConfig {
    Create3Factory factory;
    address tokenMessengerV2;
    address feeManagerProxy;
    address owner;
    bytes32 implSalt;
    bytes32 proxySalt;
}

/// @title DeployTokenMessengerWithFees
/// @notice Deploys TokenMessengerWithFees implementation and UUPS proxy via
///         Create3Factory for deterministic, bytecode-independent addresses.
///         Configures ownership atomically via deployAndMultiCall and initiates
///         a two-step ownership transfer to the configured owner.
///         The owner must call acceptOwnership() separately after deployment.
///         The proxy is pre-registered as an allowed caller on FeeManager
///         during FeeManager deployment (see DeployFeeManager.s.sol).
///
/// Required env vars (one of):
///   DEPLOYER_PRIVATE_KEY        – private key used to broadcast transactions
///   DEPLOYER_ADDRESS            – address for unlocked-account mode (Anvil)
///
///   CREATE3_FACTORY_ADDRESS        – address of the pre-deployed Create3Factory
///   TOKEN_MESSENGER_WITH_FEES_PROXY_SALT          – proxy CREATE3 salt (stable across impl upgrades)
///   TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT – impl CREATE3 salt (bump per new impl)
///   TOKEN_MESSENGER_V2_ADDRESS     – address of the existing TokenMessengerV2 contract on the target chain
///
/// Optional env vars:
///   TOKEN_MESSENGER_WITH_FEES_OWNER – final owner address; defaults to the deployer if unset
contract DeployTokenMessengerWithFees is Script {
    TokenMessengerWithFees public tokenMessengerWithFees;
    address public implementation;

    DeployTokenMessengerWithFeesConfig private _config;

    /// @dev Reads deployment config from env vars. Called automatically by `forge script`.
    function setUp() external {
        _config = _loadConfigFromEnv();
    }

    /// @notice Deploy using config loaded from env vars (for `forge script`).
    function run() public {
        _run(_config);
    }

    /// @notice Deploy using an explicit config struct (for tests — avoids vm.setEnv races).
    function runWithConfig(DeployTokenMessengerWithFeesConfig memory config) public {
        _run(config);
    }

    function _run(DeployTokenMessengerWithFeesConfig memory c) private {
        address deployer = Broadcaster.startBroadcast();

        if (c.owner == address(0)) {
            c.owner = deployer;
        }

        implementation = c.factory
            .deploy(
                c.implSalt,
                abi.encodePacked(
                    type(TokenMessengerWithFees).creationCode, abi.encode(c.tokenMessengerV2, c.feeManagerProxy)
                )
            );

        bytes memory initData = abi.encodeCall(TokenMessengerWithFees.initialize, (address(c.factory)));
        bytes memory proxyBytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData));

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Ownable.transferOwnership, (c.owner));

        address proxy = c.factory.deployAndMultiCall(c.proxySalt, proxyBytecode, calls);
        tokenMessengerWithFees = TokenMessengerWithFees(proxy);

        vm.stopBroadcast();

        console.log("TokenMessengerWithFees implementation:", implementation);
        console.log("TokenMessengerWithFees proxy:", address(tokenMessengerWithFees));
        console.log("Pending owner:", c.owner);
        console.log("TokenMessenger:", tokenMessengerWithFees.tokenMessenger());
        console.log("FeeManager:", tokenMessengerWithFees.feeManager());
        console.log("\nPost-deploy: owner must call acceptOwnership() on proxy", address(tokenMessengerWithFees));
    }

    function _loadConfigFromEnv() private view returns (DeployTokenMessengerWithFeesConfig memory c) {
        c.factory = Create3Factory(vm.envAddress("CREATE3_FACTORY_ADDRESS"));
        c.tokenMessengerV2 = vm.envAddress("TOKEN_MESSENGER_V2_ADDRESS");
        c.feeManagerProxy = Addresses.feeManagerProxy();
        c.owner = vm.envOr("TOKEN_MESSENGER_WITH_FEES_OWNER", address(0));
        c.implSalt = Salts.tokenMessengerWithFeesImpl();
        c.proxySalt = Salts.tokenMessengerWithFeesProxy();
    }
}
