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
import {Salts} from "./Salts.sol";
import {ICreate2Factory} from "./interfaces/ICreate2Factory.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Script, console} from "forge-std/Script.sol";

/// @title DeployCreate3FactoryViaCreate2
/// @notice Deploys Create3Factory via the canonical Create2Factory using
///         `deployAndMultiCall`, yielding a Create3Factory at a deterministic
///         address identical across every chain in an env that shares the same
///         `create2Factory`. The bootstrap tx:
///
///           1. Deploys Create3Factory (constructor arg = create2Factory; this is
///              why the address is chain-agnostic — owner does not enter bytecode).
///           2. Multicall: Create3Factory.transferOwnership(deployer) executed by
///              create2Factory (allowed because msg.sender == initial owner).
///
///         After this tx, Create3Factory._pendingOwner == deployer. The
///         `deployer` must follow up with a separate `acceptOwnership()` tx
///         (Ownable2Step requires the receiving owner to explicitly accept).
///
/// @dev    Existing `DeployCreate3Factory.s.sol` (plain `new`) is left untouched
///         and remains the path for one-off ops / local Anvil / downstream
///         deployment tooling.
///
/// Required env vars:
///   CREATE2_FACTORY_CONTRACT_ADDRESS  — address of the canonical Create2Factory
///   DEPLOYER_ADDRESS                  — address that will become the post-handoff
///                                       Create3Factory owner (encoded as the
///                                       transferOwnership target inside the multicall)
///   CREATE3_FACTORY_SALT              — string salt; keccak256-hashed by Salts.sol
contract DeployCreate3FactoryViaCreate2 is Script {
    error Create2FactoryAddressUnset();
    error DeployerAddressUnset();

    Create3Factory public factory;

    function run() external {
        address create2Factory = vm.envAddress("CREATE2_FACTORY_CONTRACT_ADDRESS");
        if (create2Factory == address(0)) revert Create2FactoryAddressUnset();

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        if (deployer == address(0)) revert DeployerAddressUnset();

        bytes memory bytecode = abi.encodePacked(type(Create3Factory).creationCode, abi.encode(create2Factory));

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Ownable2Step.transferOwnership, (deployer));

        vm.startBroadcast(ICreate2Factory(create2Factory).owner());

        address deployed =
            ICreate2Factory(create2Factory).deployAndMultiCall(0, Salts.create3Factory(), bytecode, calls);

        vm.stopBroadcast();

        factory = Create3Factory(deployed);

        console.log("Create3Factory deployed at:", deployed);
        console.log("Initial owner (Create2Factory):", create2Factory);
        console.log("Pending owner (post-multicall):", deployer);
        console.log("");
        console.log("Next: deployer must call Create3Factory.acceptOwnership()");
    }
}
