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

/// @title IWithFeeCollectionAddress
/// @notice Interface for a role-gated, optional override of the address that
///         `FeeManager` forwards to `IFeeTaker.takeFeeNative` /
///         `IFeeTaker.takeFeeERC20` (the recipient of the fee payout).
/// @dev    The override is opt-in: when unset (zero address), implementations
///         must fall back to the prior default
///         (`IFeeTaker.protocolFeeAddress()`).
interface IWithFeeCollectionAddress {
    /// @notice Emitted when the fee collection address override is changed to a new value.
    /// @dev    Only emitted on an actual state change. A `setFeeCollectionAddress` call that
    ///         supplies the currently-stored value is a no-op and emits no event.
    /// @param newFeeCollectionAddress The new fee collection address. The zero
    ///                                address means "use the default" (i.e.
    ///                                fall back to
    ///                                `IFeeTaker.protocolFeeAddress()`).
    event FeeCollectionAddressSet(address indexed newFeeCollectionAddress);

    /// @notice Set the fee collection address forwarded to `IFeeTaker` on
    ///         `takeFee*` calls.
    /// @dev    Only callable by holders of `FEE_COLLECTION_ADMIN_ROLE`. Pass
    ///         `address(0)` to clear the override and revert to the default
    ///         (`IFeeTaker.protocolFeeAddress()`). The address must be
    ///         `payable` because `IFeeTaker.takeFeeNative` forwards native
    ///         currency to it.
    ///
    ///         No-op when `newFeeCollectionAddress` already equals the stored
    ///         value: no SSTORE, no `FeeCollectionAddressSet` event.
    /// @param newFeeCollectionAddress The new fee collection address, or
    ///                                `address(0)` to use the default.
    function setFeeCollectionAddress(address payable newFeeCollectionAddress) external;

    /// @notice Returns the currently configured fee collection address override.
    /// @return The configured address, or `address(0)` when no override is set
    ///         (default behavior is in effect).
    function feeCollectionAddress() external view returns (address payable);
}
