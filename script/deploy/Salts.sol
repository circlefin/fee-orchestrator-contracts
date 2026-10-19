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

/// @dev Derives deterministic CREATE3 / CREATE2 salts from per-contract env vars.
///        Create3Factory bootstrap (via Create2Factory.deployAndMultiCall):
///          CREATE3_FACTORY_SALT — used by the bootstrap to land Create3Factory at a
///                                 deterministic CREATE2 address. Same across chains in
///                                 an env that share the same create2Factory.
///        FeeManager:
///          FEE_MANAGER_PROXY_SALT          — stable across impl upgrades; same across chains for identical proxy addresses.
///          FEE_MANAGER_IMPLEMENTATION_SALT — bump when deploying a new implementation (avoids CREATE3 collision).
///        TokenMessengerWithFees:
///          TOKEN_MESSENGER_WITH_FEES_PROXY_SALT          — same semantics as FEE_MANAGER_PROXY_SALT.
///          TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT — same semantics as FEE_MANAGER_IMPLEMENTATION_SALT.
library Salts {
    address private constant _VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));

    function create3Factory() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(Vm(_VM_ADDRESS).envString("CREATE3_FACTORY_SALT")));
    }

    function feeManagerImpl() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(Vm(_VM_ADDRESS).envString("FEE_MANAGER_IMPLEMENTATION_SALT")));
    }

    function feeManagerProxy() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(Vm(_VM_ADDRESS).envString("FEE_MANAGER_PROXY_SALT")));
    }

    function tokenMessengerWithFeesImpl() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(Vm(_VM_ADDRESS).envString("TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT")));
    }

    function tokenMessengerWithFeesProxy() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(Vm(_VM_ADDRESS).envString("TOKEN_MESSENGER_WITH_FEES_PROXY_SALT")));
    }
}
