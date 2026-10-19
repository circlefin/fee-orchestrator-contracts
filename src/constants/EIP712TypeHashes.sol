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

/// @title EIP712TypeHashes
/// @notice Precomputed EIP-712 type hashes shared between FeeManager and its tests.
///         Schemas must match the off-chain signer.
/// @dev    Versioning policy: the format version byte in the `signedQuote` blob is
///         NOT included in the EIP-712 struct hash. Each format version defines its
///         own EIP-712 struct (and therefore its own QUOTE_TYPEHASH). A signature
///         produced for one struct can never verify against a different struct's type
///         hash, so the EIP-712 type system already provides cryptographic version
///         isolation. Adding the version to the signed data would redundantly couple
///         the wire format to the signature scheme with no security benefit.
library EIP712TypeHashes {
    /// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 internal constant DOMAIN_TYPEHASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    /// keccak256("QuoteItem(string quoteType,bytes32 quoteArgsHash,uint256 amount)")
    bytes32 internal constant QUOTE_ITEM_TYPEHASH = 0x3d91a2ce6874a25e20e991b5af318af423de58a8ac0ebfeeea4193d329f52c65;

    /// keccak256("Quote(QuoteItem[] items,uint256 expiry,address feeToken,uint256 nonce)QuoteItem(string quoteType,bytes32 quoteArgsHash,uint256 amount)")
    bytes32 internal constant QUOTE_TYPEHASH = 0x2f6d3eeb82ea681c037fd4bcc09c4fce0f959e97f3b22728f3ccc009e3375d42;
}
