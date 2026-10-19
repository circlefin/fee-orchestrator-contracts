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

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
// solhint-disable-next-line import-path-check
import {CREATE3} from "solady/utils/CREATE3.sol";

/// @title Create3Factory
/// @notice Deterministic deployment factory using CREATE3. Ensures identical
///         proxy and implementation addresses across all chains when deployed
///         from the same factory address with the same salts, regardless of
///         the creation bytecode.
/// @dev    Unlike CREATE2, CREATE3 derives the deployed address solely from
///         `(factory_address, salt)`, making it immune to bytecode differences.
///         This means constructor arguments, compiler settings, or minor code
///         changes do not affect the deployed address.
///         The factory address itself still depends on how this factory is
///         deployed. With `script/deploy/DeployCreate3Factory.s.sol`'s plain
///         CREATE path, identical factory addresses require the same deployer
///         address and deployment nonce/transaction sequence on every chain; that
///         script passes the deployer as `initialOwner`. If a deterministic
///         factory-deploy path is used instead, constructor-encoded `initialOwner`
///         can also participate in address derivation via the creation payload.
///         See `README.md#cross-chain-address-determinism` and
///         `README.md#deployment` for operator guidance.
contract Create3Factory is Ownable2Step {
    /// @notice Thrown when `renounceOwnership()` is called.
    error RenounceDisabled();

    /// @notice Emitted when a contract is deployed via the factory.
    /// @param deployed The address of the deployed contract.
    /// @param salt     The salt used for the deployment.
    event Deployed(address indexed deployed, bytes32 indexed salt);

    /// @param initialOwner Address that will become the factory owner. The repo
    ///        deploy script sets this to the broadcaster/deployer; cross-chain
    ///        factory address parity requires keeping this value aligned with the
    ///        deployer/nonce requirements described above.
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Deploys a contract using CREATE3.
    /// @param salt     Salt for deterministic address derivation.
    /// @param bytecode Creation bytecode (optionally including appended constructor args).
    /// @return addr    The address of the newly deployed contract.
    function deploy(bytes32 salt, bytes calldata bytecode) external onlyOwner returns (address addr) {
        addr = CREATE3.deployDeterministic(bytecode, salt);
        emit Deployed(addr, salt);
    }

    /// @notice Deploys a contract using CREATE3 and immediately executes a
    ///         batch of calls on it in the same transaction. Useful for
    ///         deploying a proxy and configuring roles atomically.
    /// @dev    The factory temporarily owns the deployed contract for the
    ///         duration of the multicall (e.g. proxy initialized with
    ///         `address(factory)` as owner). Callers must ensure the deployed
    ///         contract's initializer does not make arbitrary external callbacks.
    ///         No upper bound is enforced on `calls.length` because this function
    ///         is restricted to `onlyOwner` and bounded by the block gas limit.
    /// @param salt     Salt for deterministic address derivation.
    /// @param bytecode Creation bytecode (optionally including appended constructor args).
    /// @param calls    ABI-encoded function calls to invoke on the deployed contract.
    /// @return addr    The address of the newly deployed contract.
    function deployAndMultiCall(bytes32 salt, bytes calldata bytecode, bytes[] calldata calls)
        external
        onlyOwner
        returns (address addr)
    {
        addr = CREATE3.deployDeterministic(bytecode, salt);
        emit Deployed(addr, salt);

        uint256 len = calls.length;
        for (uint256 i = 0; i < len; ++i) {
            // slither-disable-next-line low-level-calls
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory ret) = addr.call(calls[i]);
            if (!ok) {
                // slither-disable-next-line assembly
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }

    /// @notice Disabled — renouncing ownership would permanently brick the factory.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Computes the deterministic address for a given salt
    ///         without deploying. The address depends only on the factory
    ///         address and salt, not on the bytecode.
    /// @param salt Salt for deterministic address derivation.
    /// @return The address where the contract would be deployed.
    function getAddress(bytes32 salt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(salt);
    }
}
