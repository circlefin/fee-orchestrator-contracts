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

/// @title BurnMessageV2Lib
/// @notice Minimal library for encoding CCTP v2 burn message bodies.
///         Replicates the wire format from circlefin/evm-cctp-contracts
///         BurnMessageV2.sol which cannot be imported directly due to
///         compiler version incompatibility.
/// @dev    Original: https://github.com/circlefin/evm-cctp-contracts
/// @dev    Relay layout reference: https://github.com/circlefin/evm-cctp-contracts/blob/master/src/messages/v2/BurnMessageV2.sol
///         (`_formatMessageForRelay`).
/// @dev Field layout (packed, no padding between fields):
///
///      Field             Bytes   Type      Offset
///      version           4       uint32    0
///      burnToken         32      bytes32   4
///      mintRecipient     32      bytes32   36
///      amount            32      uint256   68
///      messageSender     32      bytes32   100
///      maxFee            32      uint256   132
///      feeExecuted       32      uint256   164
///      expirationBlock   32      uint256   196
///      hookData          dynamic bytes     228
library BurnMessageV2Lib {
    /// @dev Matches upstream `_formatMessageForRelay` when fees are unset on burn.
    ///      Same value as `maxFee` passed to `TokenMessengerV2.depositForBurn` when fees are prepaid on the source chain (via `FeeManager`).
    uint256 internal constant EMPTY_MAX_FEE = 0;
    uint256 private constant EMPTY_FEE_EXECUTED = 0;
    uint256 private constant EMPTY_EXPIRATION_BLOCK = 0;

    /// @notice Encodes a burn message body with optional hook data appended.
    /// @dev    `maxFee`, `feeExecuted`, and `expirationBlock` are encapsulated as
    ///         constants matching the upstream `_formatMessageForRelay`.
    function formatMessage(
        uint32 version,
        bytes32 burnToken,
        bytes32 mintRecipient,
        uint256 amount,
        bytes32 messageSender,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            version,
            burnToken,
            mintRecipient,
            amount,
            messageSender,
            EMPTY_MAX_FEE,
            EMPTY_FEE_EXECUTED,
            EMPTY_EXPIRATION_BLOCK,
            hookData
        );
    }
}
