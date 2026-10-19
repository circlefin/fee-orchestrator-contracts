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

/// @title WithTrustedQuoteSignersStorage
/// @notice EIP-7201 namespaced storage for WithTrustedQuoteSigners
library WithTrustedQuoteSignersStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("feeorchestrator.storage.WithTrustedQuoteSigners")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_SLOT = 0x235ef36c4f4f4cc7873a899b041e507ea2c4e1fdd0e5f135e4fd1b5e17c31f00;

    /// @custom:storage-location erc7201:feeorchestrator.storage.WithTrustedQuoteSigners
    struct Layout {
        mapping(address => bool) trustedQuoteSigner;
    }

    function layout() internal pure returns (Layout storage $) {
        bytes32 slot = STORAGE_SLOT;
        // slither-disable-next-line assembly
        assembly {
            $.slot := slot
        }
    }
}
