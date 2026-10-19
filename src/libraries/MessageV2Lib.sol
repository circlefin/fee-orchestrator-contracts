/**
 * Copyright 2025 Circle Internet Group, Inc.  All rights reserved.
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

/// @title MessageV2Lib
/// @notice Minimal library for encoding CCTP v2 messages and computing their
///         hash. Replicates the wire format from circlefin/evm-cctp-contracts
///         MessageV2.sol (Solidity 0.7.6) which cannot be imported directly
///         due to compiler version incompatibility.
/// @dev    Original: https://github.com/circlefin/evm-cctp-contracts/blob/master/src/messages/v2/MessageV2.sol
/// @dev Field layout (packed, no padding between fields):
///
///      Field                        Bytes   Type      Offset
///      version                      4       uint32    0
///      sourceDomain                 4       uint32    4
///      destinationDomain            4       uint32    8
///      nonce                        32      bytes32   12
///      sender                       32      bytes32   44
///      recipient                    32      bytes32   76
///      destinationCaller            32      bytes32   108
///      minFinalityThreshold         4       uint32    140
///      finalityThresholdExecuted    4       uint32    144
///      messageBody                  dynamic bytes     148
library MessageV2Lib {
    uint32 private constant VERSION = 1;
    bytes32 private constant EMPTY_NONCE = bytes32(0);
    uint32 private constant EMPTY_FINALITY_THRESHOLD_EXECUTED = 0;

    /// @notice Encodes a CCTP v2 message in the relay format and returns its
    ///         keccak256 hash. This is the `correlationHash` used by
    ///         `FeeManager.collectFeesWithQuote`.
    /// @dev    `version`, `nonce`, and `finalityThresholdExecuted` are
    ///         encapsulated as constants matching the upstream
    ///         `_formatMessageForRelay`.
    /// @return messageHash keccak256 of the packed message bytes.
    function messageHash(
        uint32 sourceDomain,
        uint32 destinationDomain,
        bytes32 sender,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        bytes memory messageBody
    ) internal pure returns (bytes32) {
        return keccak256(
            formatMessage(
                sourceDomain, destinationDomain, sender, recipient, destinationCaller, minFinalityThreshold, messageBody
            )
        );
    }

    /// @notice Encodes a CCTP v2 message in the relay format.
    /// @dev    Uses `VERSION = 1`, `EMPTY_NONCE`, and
    ///         `EMPTY_FINALITY_THRESHOLD_EXECUTED` matching the upstream
    ///         `_formatMessageForRelay`.
    /// @return The packed message bytes.
    function formatMessage(
        uint32 sourceDomain,
        uint32 destinationDomain,
        bytes32 sender,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        bytes memory messageBody
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            VERSION,
            sourceDomain,
            destinationDomain,
            EMPTY_NONCE,
            sender,
            recipient,
            destinationCaller,
            minFinalityThreshold,
            EMPTY_FINALITY_THRESHOLD_EXECUTED,
            messageBody
        );
    }
}
