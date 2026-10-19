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

/// @title ITokenMessengerV2
/// @notice Minimal interface for the existing CCTPv2 TokenMessengerV2 contract.
///         Only includes the functions required by TokenMessengerWithFees.
/// @dev    Original: https://github.com/circlefin/evm-cctp-contracts
interface ITokenMessengerV2 {
    /// @notice Deposit tokens for burn and send a cross-chain message.
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;

    /// @notice Deposit tokens for burn with hook data and send a cross-chain message.
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;

    /// @notice Returns the address of the local MessageTransmitterV2 contract.
    function localMessageTransmitter() external view returns (address);

    /// @notice Returns the BurnMessage body version used by this TokenMessenger.
    function messageBodyVersion() external view returns (uint32);

    /// @notice Returns the remote TokenMessenger address for a given domain, as bytes32.
    function remoteTokenMessengers(uint32 domain) external view returns (bytes32);

    /// @notice Returns whether the given address is on the denylist.
    function isDenylisted(address addr) external view returns (bool);
}
