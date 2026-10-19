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

import {Addresses} from "./Addresses.sol";
import {Script, console} from "forge-std/Script.sol";

/// @title PrintAddresses
/// @notice Prints CREATE3-predicted deployment addresses from `Addresses` (no transactions, no gas).
///
/// Usage:
///   forge script script/deploy/PrintAddresses.s.sol --rpc-url $BLOCKCHAIN_RPC_URL
///   forge script script/deploy/PrintAddresses.s.sol --rpc-url $BLOCKCHAIN_RPC_URL --sig feeManagerProxyAddress
///
/// `getAddress` is executed on-chain against `CREATE3_FACTORY_ADDRESS`; use the RPC for the chain where that
/// factory is deployed (omit localhost unless the factory exists there).
///
/// Required env vars (same as deploy scripts):
///   CREATE3_FACTORY_ADDRESS
///   FEE_MANAGER_PROXY_SALT
///   FEE_MANAGER_IMPLEMENTATION_SALT
///   TOKEN_MESSENGER_WITH_FEES_PROXY_SALT
///   TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT
contract PrintAddresses is Script {
    /// @dev Short custom error for solhint (no long reason strings on `require`).
    error FactoryHasNoCode();

    function run() external view {
        _checkFactory();
        console.log("Create3Factory:                  ", vm.envAddress("CREATE3_FACTORY_ADDRESS"));
        console.log("FeeManager implementation:       ", Addresses.feeManagerImpl());
        console.log("FeeManager proxy:                ", Addresses.feeManagerProxy());
        console.log("TokenMessengerWithFees impl:     ", Addresses.tokenMessengerWithFeesImpl());
        console.log("TokenMessengerWithFees proxy:    ", Addresses.tokenMessengerWithFeesProxy());
    }

    function feeManagerImplAddress() external view {
        _checkFactory();
        console.log(Addresses.feeManagerImpl());
    }

    function feeManagerProxyAddress() external view {
        _checkFactory();
        console.log(Addresses.feeManagerProxy());
    }

    function tokenMessengerWithFeesImplAddress() external view {
        _checkFactory();
        console.log(Addresses.tokenMessengerWithFeesImpl());
    }

    function tokenMessengerWithFeesProxyAddress() external view {
        _checkFactory();
        console.log(Addresses.tokenMessengerWithFeesProxy());
    }

    function _checkFactory() private view {
        address factory = vm.envAddress("CREATE3_FACTORY_ADDRESS");
        if (factory.code.length == 0) revert FactoryHasNoCode();
    }
}
