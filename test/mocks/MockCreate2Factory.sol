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

import {ICreate2Factory} from "../../script/deploy/interfaces/ICreate2Factory.sol";

/// @notice Minimal Create2Factory mock for tests. Implements the subset used
///         by the fee-orchestrator bootstrap flow.
contract MockCreate2Factory is ICreate2Factory {
    address public override owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function deployAndMultiCall(uint256 amount, bytes32 salt, bytes calldata bytecode, bytes[] calldata data)
        external
        payable
        override
        returns (address addr)
    {
        bytes memory bc = bytecode;
        assembly {
            addr := create2(amount, add(bc, 0x20), mload(bc), salt)
        }
        require(addr != address(0), "MockCreate2Factory: create2 failed");

        for (uint256 i = 0; i < data.length; ++i) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory ret) = addr.call(data[i]);
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}
