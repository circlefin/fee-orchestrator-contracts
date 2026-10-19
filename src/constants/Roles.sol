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

/// @title Roles
/// @notice AccessControl role identifiers shared across FeeManager, deploy
///         scripts, and tests.  Keeping them in one place prevents hash drift
///         and makes audits easier.
library Roles {
    /// @dev Granted to addresses that may call `collectFeesWithQuote`.
    ///      Admin: CALLER_ADMIN_ROLE.
    bytes32 internal constant ALLOWED_CALLER_ROLE = keccak256("ALLOWED_CALLER_ROLE");

    /// @dev Admin role for ALLOWED_CALLER_ROLE. Holders can grant/revoke
    ///      ALLOWED_CALLER_ROLE.  Admin: DEFAULT_ADMIN_ROLE.
    bytes32 internal constant CALLER_ADMIN_ROLE = keccak256("CALLER_ADMIN_ROLE");

    /// @dev Holders can add/remove trusted quote signers via
    ///      `setTrustedQuoteSigner`.  Admin: DEFAULT_ADMIN_ROLE.
    bytes32 internal constant SIGNER_ADMIN_ROLE = keccak256("SIGNER_ADMIN_ROLE");

    /// @dev Holders can pause/unpause `collectFeesWithQuote`.
    ///      Admin: DEFAULT_ADMIN_ROLE.
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @dev Holders can set the fee collection address that overrides the
    ///      default `IFeeTaker.protocolFeeAddress()` recipient via
    ///      `setFeeCollectionAddress`.  Admin: DEFAULT_ADMIN_ROLE.
    bytes32 internal constant FEE_COLLECTION_ADMIN_ROLE = keccak256("FEE_COLLECTION_ADMIN_ROLE");
}
