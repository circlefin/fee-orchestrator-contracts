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

import {Roles} from "../constants/Roles.sol";
import {IWithFeeCollectionAddress} from "../interfaces/IWithFeeCollectionAddress.sol";
import {WithFeeCollectionAddressStorage} from "../storage/WithFeeCollectionAddressStorage.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @title WithFeeCollectionAddress
/// @notice Abstract contract that exposes a role-gated, optional override of
///         the address forwarded to `IFeeTaker` on `takeFee*` calls (the
///         recipient of the fee payout). Access is restricted to holders of
///         `FEE_COLLECTION_ADMIN_ROLE`. State lives in EIP-7201 namespaced
///         storage (WithFeeCollectionAddressStorage).
/// @dev    Setting the override to `address(0)` clears it; consumers must
///         then fall back to the prior default
///         (`IFeeTaker.protocolFeeAddress()`). Resolution of the effective
///         address is left to the consuming contract.
abstract contract WithFeeCollectionAddress is IWithFeeCollectionAddress, AccessControlUpgradeable {
    /// @inheritdoc IWithFeeCollectionAddress
    /// @dev No-op (no SSTORE, no event) when the supplied value already matches the stored
    ///      override. `FeeCollectionAddressSet` is only emitted on an actual state change so
    ///      indexers see one event per distinct configuration.
    function setFeeCollectionAddress(address payable newFeeCollectionAddress)
        external
        onlyRole(Roles.FEE_COLLECTION_ADMIN_ROLE)
    {
        WithFeeCollectionAddressStorage.Layout storage $ = WithFeeCollectionAddressStorage.layout();
        if ($.feeCollectionAddress == newFeeCollectionAddress) return;
        $.feeCollectionAddress = newFeeCollectionAddress;
        emit FeeCollectionAddressSet(newFeeCollectionAddress);
    }

    /// @inheritdoc IWithFeeCollectionAddress
    function feeCollectionAddress() external view returns (address payable) {
        return _feeCollectionAddress();
    }

    function _feeCollectionAddress() internal view returns (address payable) {
        return WithFeeCollectionAddressStorage.layout().feeCollectionAddress;
    }
}
