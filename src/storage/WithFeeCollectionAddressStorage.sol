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

/// @title WithFeeCollectionAddressStorage
/// @notice EIP-7201 namespaced storage for WithFeeCollectionAddress
library WithFeeCollectionAddressStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("feeorchestrator.storage.WithFeeCollectionAddress")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_SLOT = 0x115995aaebe10c4a52214233cf5c663349854e10926ccaff7128ebf40098e900;

    /// @custom:storage-location erc7201:feeorchestrator.storage.WithFeeCollectionAddress
    struct Layout {
        address payable feeCollectionAddress;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 slot = STORAGE_SLOT;
        // slither-disable-next-line assembly
        assembly {
            $.slot := slot
        }
    }
}
