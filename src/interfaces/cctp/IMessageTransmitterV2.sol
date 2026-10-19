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

/// @title IMessageTransmitterV2
/// @notice Minimal interface for the existing CCTPv2 MessageTransmitterV2 contract.
///         Only includes the functions required by TokenMessengerWithFees.
/// @dev    Original: https://github.com/circlefin/evm-cctp-contracts
interface IMessageTransmitterV2 {
    /// @notice Returns the CCTP domain ID of the local chain.
    function localDomain() external view returns (uint32);
}
