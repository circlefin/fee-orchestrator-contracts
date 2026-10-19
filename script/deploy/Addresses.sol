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
import {Vm} from "forge-std/Vm.sol";

/// @dev Predicts deterministic CREATE3 addresses from the CREATE3_FACTORY_ADDRESS
///      and per-contract salt env vars (see `Salts`).
///      Combines `Create3Factory.getAddress` with the salt derivation from `Salts`
///      so every script and test resolves addresses through a single entry point.
///      `feeManagerProxy()` checks `FEE_MANAGER_PROXY_ADDRESS` first, falling back
///      to the CREATE3-predicted address when the env var is unset or zero.
library Addresses {
    address private constant _VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));

    function _factory() private view returns (Create3Factory) {
        return Create3Factory(Vm(_VM_ADDRESS).envAddress("CREATE3_FACTORY_ADDRESS"));
    }

    function feeManagerImpl() internal view returns (address) {
        return _factory().getAddress(Salts.feeManagerImpl());
    }

    function feeManagerProxy() internal view returns (address) {
        address fromEnv = Vm(_VM_ADDRESS).envOr("FEE_MANAGER_PROXY_ADDRESS", address(0));
        return fromEnv != address(0) ? fromEnv : _factory().getAddress(Salts.feeManagerProxy());
    }

    function tokenMessengerWithFeesImpl() internal view returns (address) {
        return _factory().getAddress(Salts.tokenMessengerWithFeesImpl());
    }

    function tokenMessengerWithFeesProxy() internal view returns (address) {
        return _factory().getAddress(Salts.tokenMessengerWithFeesProxy());
    }
}
