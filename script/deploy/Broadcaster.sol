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

import {Vm} from "forge-std/Vm.sol";

/// @dev Shared broadcast helper for deploy/upgrade scripts.
///      Supports two modes:
///        1. **Live deployment** — set DEPLOYER_PRIVATE_KEY; derives the address
///           and broadcasts with the private key.
///        2. **Offline prepare** — set DEPLOYER_ADDRESS instead; broadcasts with
///           an unlocked address (for Anvil forks).
library Broadcaster {
    address private constant _VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));

    /// @dev Resolves the deployer and starts broadcasting.
    ///      Checks DEPLOYER_PRIVATE_KEY first; if unset or zero, falls back
    ///      to DEPLOYER_ADDRESS for unlocked-account mode.
    function startBroadcast() internal returns (address deployer) {
        Vm vm = Vm(_VM_ADDRESS);
        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            deployer = vm.addr(pk);
            vm.startBroadcast(pk);
        } else {
            deployer = vm.envAddress("DEPLOYER_ADDRESS");
            vm.startBroadcast(deployer);
        }
    }
}
