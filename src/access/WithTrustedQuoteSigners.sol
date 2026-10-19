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
import {IWithTrustedQuoteSigners} from "../interfaces/IWithTrustedQuoteSigners.sol";
import {WithTrustedQuoteSignersStorage} from "../storage/WithTrustedQuoteSignersStorage.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @title WithTrustedQuoteSigners
/// @notice Abstract contract that provides a role-gated set of trusted quote
///         signers for EIP-712 signature verification. Access is restricted to
///         holders of `SIGNER_ADMIN_ROLE`. State lives in EIP-7201 namespaced
///         storage (WithTrustedQuoteSignersStorage).
abstract contract WithTrustedQuoteSigners is IWithTrustedQuoteSigners, AccessControlUpgradeable {
    /// @inheritdoc IWithTrustedQuoteSigners
    function setTrustedQuoteSigner(address signer, bool trusted) external onlyRole(Roles.SIGNER_ADMIN_ROLE) {
        if (signer == address(0)) revert ZeroTrustedQuoteSignerAddress();

        WithTrustedQuoteSignersStorage.Layout storage $ = WithTrustedQuoteSignersStorage.layout();
        bool wasTrusted = $.trustedQuoteSigner[signer];
        if (trusted == wasTrusted) {
            emit TrustedQuoteSignerSet(signer, trusted);
            return;
        }

        if (trusted) {
            $.trustedQuoteSigner[signer] = true;
        } else {
            delete $.trustedQuoteSigner[signer];
        }
        emit TrustedQuoteSignerSet(signer, trusted);
    }

    /// @inheritdoc IWithTrustedQuoteSigners
    function isTrustedQuoteSigner(address signer) external view returns (bool) {
        return _isTrustedQuoteSigner(signer);
    }

    function _isTrustedQuoteSigner(address signer) internal view returns (bool) {
        return WithTrustedQuoteSignersStorage.layout().trustedQuoteSigner[signer];
    }
}
