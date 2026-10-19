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

/// @title IFeeTaker
/// @notice Minimal interface for the FeeTaker contract used by FeeManager
///         to forward collected fees. FeeTaker splits each fee between a
///         protocol fee address and a beneficiary according to a configurable
///         share (set per beneficiary via `setBeneficiaryProtocolFeeShare`).
/// @dev    Minimal interface consumed by FeeManager for fee forwarding.
interface IFeeTaker {
    /// @notice Returns the address that receives the protocol's share of fees.
    function protocolFeeAddress() external view returns (address);

    /// @notice Collects native-asset fee, splits according to protocol rules,
    ///         and forwards the amounts to protocolFeeAddress & beneficiary.
    /// @param beneficiary Merchant / PSP fee recipient.
    /// @param kitType 8-byte kit identifier.
    function takeFeeNative(address payable beneficiary, bytes8 kitType) external payable;

    /// @notice Collects ERC-20 fee, splits according to protocol rules,
    ///         and forwards the amounts to protocolFeeAddress & beneficiary.
    /// @param token ERC-20 token address.
    /// @param beneficiary Merchant / PSP fee recipient.
    /// @param fee Total fee amount (already calculated by caller).
    /// @param kitType 8-byte kit identifier.
    function takeFeeERC20(address token, address beneficiary, uint256 fee, bytes8 kitType) external;
}
