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

/// @title IWithTrustedQuoteSigners
/// @notice Interface for a role-gated set of trusted quote signers used to
///         validate off-chain fee quotes on-chain.
interface IWithTrustedQuoteSigners {
    /// @notice Emitted when a trusted quote signer is added or removed.
    /// @param signer   The address whose trusted status was updated.
    /// @param trusted  Whether the address is now trusted to sign quotes.
    event TrustedQuoteSignerSet(address indexed signer, bool trusted);

    /// @notice Thrown when `address(0)` is passed to `setTrustedQuoteSigner`.
    error ZeroTrustedQuoteSignerAddress();

    /// @notice Add or remove a trusted quote signer.
    /// @dev    Only callable by holders of `SIGNER_ADMIN_ROLE`.
    /// @param signer   The address to update.
    /// @param trusted  True to trust, false to revoke.
    function setTrustedQuoteSigner(address signer, bool trusted) external;

    /// @notice Returns whether `signer` is currently trusted to sign quotes.
    /// @param signer The address to query.
    /// @return True if the address is trusted.
    function isTrustedQuoteSigner(address signer) external view returns (bool);
}
