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

/// @notice Minimal interface for the canonical CCTP Create2Factory. Mirrors
///         the subset used by fee-orchestrator's bootstrap flow.
interface ICreate2Factory {
    function owner() external view returns (address);

    /// @notice CREATE2-deploys `bytecode` at `salt`, then executes each
    ///         element of `data` on the resulting contract from the factory's
    ///         context (msg.sender = Create2Factory during the multicall).
    /// @param amount   Value (wei) forwarded to the CREATE2 opcode.
    /// @param salt     CREATE2 salt.
    /// @param bytecode Creation bytecode (with constructor args appended).
    /// @param data     Calls to forward to the newly-deployed contract.
    function deployAndMultiCall(uint256 amount, bytes32 salt, bytes calldata bytecode, bytes[] calldata data)
        external
        payable
        returns (address);
}
