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

/// @title IFeeManager
/// @notice Interface for the FeeManager contract that handles fee collection and assertion.
interface IFeeManager {
    /// @notice A single line item within a quote, binding a fee type and its
    ///         arguments to a specific amount.
    /// @param quoteType  Identifier for the kind of fee (e.g. "FORWARD", "PRE_FINALITY").
    /// @param quoteArgsHash  Keccak-256 hash of the ABI-encoded quote arguments,
    ///                       used to match a request to its quote item without
    ///                       storing the full arguments on-chain.
    /// @param amount  The fee amount denominated in the quote's `feeToken`
    ///                (wei for native currency).
    struct QuoteItem {
        string quoteType;
        bytes32 quoteArgsHash;
        uint256 amount;
    }

    /// @notice A server-signed bundle of fee line items, specifying the token,
    ///         expiry, and an EIP-712 ECDSA signature over the contents.
    /// @param items     Ordered list of fee line items. Each `quoteType` should appear at most once; if the same
    ///                  `quoteType` string appears on multiple lines, lookups and fee collection use the **first**
    ///                  matching line only (see `QuoteLib.findItemByType`).
    /// @param expiry    Packed expiry: the high byte (bits 255–248) selects the mode; the lower 248 bits hold
    ///                  the deadline value. Mode `0x00` (default): deadline is a Unix timestamp and the quote
    ///                  is valid while `block.timestamp <= deadline`. Mode `0x01`: deadline is a block height and
    ///                  the quote is valid while `block.number <= deadline`. Other mode bytes are rejected on
    ///                  collection. The full `uint256` is included in the EIP-712 struct hash unchanged.
    /// @param feeToken  Token address in which all fees are denominated.
    ///                   Use `address(0)` to indicate the chain's native currency.
    /// @param nonce     Must be `0`. Non-zero values are rejected with `QuoteLib.NonZeroNonce`.
    ///                  The field is retained in the EIP-712 struct hash for domain
    ///                  binding and is reserved for future use.
    /// @param signature Signature over the canonical encoding of the quote,
    ///                  verified against a trusted signer.
    struct Quote {
        QuoteItem[] items;
        uint256 expiry;
        address feeToken;
        uint256 nonce;
        bytes signature;
    }

    /// @notice Caller-supplied request to collect a specific fee from the quote.
    /// @param quoteType  Must match a `QuoteItem.quoteType` in the signed quote.
    /// @param quoteArgs  Original arguments whose keccak-256 hash must equal the
    ///                   corresponding `QuoteItem.quoteArgsHash`.
    /// @param required   If true, revert when no line item with this `quoteType`
    ///                   exists in the quote. If false, silently skip only in
    ///                   that case. If a line item of this type exists but its
    ///                   `quoteArgsHash` does not match the request, the call
    ///                   reverts regardless of `required`.
    struct FeeWithQuoteRequest {
        string quoteType;
        string[] quoteArgs;
        bool required;
    }

    /// @notice Bundles a server-signed quote payload with the runtime-supplied
    ///         refund address. `refundAddress` is **not** part of the signed
    ///         payload — it is declared per call by the on-chain layer that
    ///         knows who the fee payer is (typically a wrapper such as
    ///         `TokenMessengerWithFees`, which itself collects the fee from
    ///         the end user it serves). Refunds, if any, are attributed
    ///         off-chain and routed to this address.
    /// @dev    Using a struct here lets every wrapper above FeeManager pass a
    ///         single value through unchanged instead of growing an extra
    ///         parameter alongside `signedQuote`.
    /// @param signedQuote    Version-prefixed, ABI-encoded `Quote` struct
    ///                       (`[uint8 version][abi.encode(Quote)]`).
    /// @param refundAddress  Address to attribute fee refunds to. Use
    ///                       `address(0)` when no refund address should be
    ///                       recorded. Non-zero values are screened against
    ///                       the configured USDC blacklist on collection and
    ///                       the call reverts if listed.
    struct QuoteClaim {
        bytes signedQuote;
        address payable refundAddress;
    }

    /// @notice Decoded counterpart to `QuoteClaim`: bundles an already-decoded `Quote` body with
    ///         the runtime-supplied refund address. Used by the `Quote calldata` overload of
    ///         `collectFeesWithQuote` and by wrappers (e.g. `TokenMessengerWithFees`) that have
    ///         already decoded the wire payload and want to skip a redundant decode at the
    ///         FeeManager boundary.
    /// @dev    Same `refundAddress` semantics as `QuoteClaim`.
    /// @param decodedQuote   The v1 `Quote` body, equivalent to `abi.decode(signedQuote[1:], (Quote))`
    ///                       for a valid v1 versioned blob. Future formats use a distinct struct
    ///                       type and matching overload.
    /// @param refundAddress  See `QuoteClaim.refundAddress`.
    struct DecodedQuoteClaim {
        Quote decodedQuote;
        address payable refundAddress;
    }

    /// @notice Emitted for each fee line item that is successfully collected.
    /// @param caller           The address that initiated the fee collection
    ///                         (`msg.sender`).
    /// @param correlationHash  Caller-supplied identifier that ties the fee to
    ///                         an external operation and groups the individual
    ///                         `FeeCollected` events emitted per quote item
    ///                         within a single `collectFeesWithQuote` call.
    /// @param quoteType        The fee type that was charged.
    /// @param quoteArgs        The original quote arguments.
    /// @param refundAddress    Address to attribute fee refunds to (if any).
    ///                         May be `address(0)` (no refund target).
    /// @param feeRecipient     The address that received the fee. Always non-zero.
    /// @param feeToken         The token in which the fee was paid
    ///                          (`address(0)` for native currency).
    /// @param amount           The amount of `feeToken` collected.
    /// @param nonce            The quote's `nonce` (always `0` in the current version).
    event FeeCollected(
        address indexed caller,
        bytes32 indexed correlationHash,
        string quoteType,
        string[] quoteArgs,
        address payable refundAddress,
        address payable feeRecipient,
        address feeToken,
        uint256 amount,
        uint256 nonce
    );

    /// @notice The supplied non-zero `refundAddress` is on the configured USDC blacklist.
    /// @dev `address(0)` is accepted ("no refund target") and bypasses this check.
    error DenylistedRefundAddress(address refundAddress);

    /// @notice Signed quotes may contain at most 256 line items (bitmap width).
    error TooManyQuoteItems(uint256 length);

    /// @notice The same quote line item was requested more than once in one call.
    error DuplicateRequestType(string quoteType);

    /// @notice A required request did not have a matching quote line item.
    error RequiredFeeNotInQuote(string quoteType, bytes32 quoteArgsHash);

    /// @notice A quote line item existed for the request type, but its args did not match.
    error QuoteArgsMismatch(string quoteType, bytes32 requestArgsHash);

    /// @notice The signed quote's format version is not supported by this contract.
    /// @param version The unrecognised version byte.
    error UnsupportedQuoteVersion(uint8 version);

    /// @notice Decoding `signedQuote` failed (empty payload, tail too short, signature not exactly 65 bytes, etc.).
    /// @dev Returned when cheap checks fail before or after `abi.decode` (see `SignedQuoteLib`). If the tail is long
    ///      enough to pass those checks but the bytes are still not a valid ABI encoding of `Quote`, the compiler
    ///      may revert with **Panic(0x21)** instead of this error. Off-chain callers should treat any revert while
    ///      decoding as failure; do not rely on a specific error selector for malformed blobs.
    error SignedQuoteDecodeFailed();

    /// @notice Collect fees from `msg.sender` according to a server-signed quote.
    /// @dev    The fee token is derived from the signed quote; callers do not
    ///        specify it directly. Callers may use `sumFees` with the relevant
    ///        quote types to prepare ERC-20 allowance or native `msg.value` for
    ///        an assumed-valid quote; this function performs the full
    ///        quote-argument, signature, expiry, and payment validation.
    ///        **Wire decode:** `claim.signedQuote` is parsed with `SignedQuoteLib` (same rules as `decodeQuote`).
    ///        EIP-712 signature verification runs after a successful decode.
    ///        **Refund address:** `claim.refundAddress` is **not** part of the signed payload — it is supplied
    ///        per call by the on-chain layer that knows who is paying, and is reflected verbatim in every
    ///        emitted `FeeCollected` event. `address(0)` is allowed (no refund target). When non-zero, the
    ///        address is screened against the USDC blacklist.
    /// @param correlationHash  Opaque identifier emitted in every `FeeCollected`
    ///                         event, used both to correlate the per-item events
    ///                         with each other and to tie them back to the
    ///                         external operation that triggered collection.
    /// @param requests         Ordered list of fees to collect. Each request is
    ///                         matched against the signed quote by `quoteType`
    ///                         and `quoteArgsHash`.
    /// @param claim            Bundle of the version-prefixed signed quote
    ///                         payload and the runtime-supplied
    ///                         `refundAddress`. See `QuoteClaim`.
    /// @return amount          Total amount of `feeToken` collected across all
    ///                         matched requests.
    function collectFeesWithQuote(
        bytes32 correlationHash,
        FeeWithQuoteRequest[] calldata requests,
        QuoteClaim calldata claim
    ) external payable returns (uint256 amount);

    /// @notice Same as the `QuoteClaim` overload, but accepts an already-decoded `Quote` body
    ///         to skip redundant decoding when the caller already decoded the payload
    ///         (e.g. after `decodeQuote` or off-chain ABI decoding).
    /// @dev    The `Quote` struct type inside `DecodedQuoteClaim` denotes the v1 quote body;
    ///         future wire-format versions will use separate struct types (e.g. `QuoteV2`) and
    ///         matching overloads. For EIP-712 verification, `claim.decodedQuote.signature` must
    ///         be a 65-byte `bytes` value accepted by OpenZeppelin `ECDSA.recover` (non-65-byte
    ///         lengths revert with `ECDSAInvalidSignatureLength`). The `QuoteClaim` path
    ///         additionally enforces length in `SignedQuoteLib.decodeQuote` (`SignedQuoteDecodeFailed`).
    /// @param correlationHash  See the `QuoteClaim` overload.
    /// @param requests         See the `QuoteClaim` overload.
    /// @param claim            Bundle of the decoded `Quote` body and the runtime-supplied
    ///                         `refundAddress`. See `DecodedQuoteClaim`.
    function collectFeesWithQuote(
        bytes32 correlationHash,
        FeeWithQuoteRequest[] calldata requests,
        DecodedQuoteClaim calldata claim
    ) external payable returns (uint256 amount);

    /// @notice Return the amount of `feeToken` present for the supplied quote
    ///         types in a signed quote.
    /// @dev    This is a lightweight pure query: it decodes the quote and sums
    ///         quote items by `quoteType` only. It does not validate quote
    ///         arguments, required-fee presence, signature/expiry, nonce,
    ///         refund addresses, emit events, or transfer funds. Full
    ///         validation happens only during `collectFeesWithQuote`. Empty
    ///         `signedQuote` returns `(0, address(0))`, matching `getQuoteTotal`.
    ///         Reverts `TooManyQuoteItems` when the decoded quote has more than
    ///         256 items, mirroring `collectFeesWithQuote`. Duplicate entries
    ///         in `quoteTypes` are silently deduplicated so the returned
    ///         `totalFee` mirrors what `collectFeesWithQuote` would charge (it
    ///         rejects per-call duplicate matches with `DuplicateRequestType`).
    /// @param signedQuote Version-prefixed, ABI-encoded `Quote` struct.
    /// @param quoteTypes  Fee types to include in the sum.
    /// @return totalFee   Sum of first matching `QuoteItem.amount` values.
    /// @return feeToken   Token address from the quote (`address(0)` for native).
    function sumFees(bytes calldata signedQuote, string[] calldata quoteTypes)
        external
        pure
        returns (uint256 totalFee, address feeToken);

    /// @notice Same as the `signedQuote` overload, but accepts a decoded `Quote` body.
    /// @param decodedQuote ABI-decoded v1 `Quote`.
    /// @param quoteTypes   Fee types to include in the sum.
    function sumFees(Quote calldata decodedQuote, string[] calldata quoteTypes)
        external
        pure
        returns (uint256 totalFee, address feeToken);

    /// @notice Validates the version prefix and ABI-decodes a versioned `signedQuote` into a `Quote`.
    /// @dev Wire format: `[uint8 version][abi.encode(Quote)]`. Implementation delegates to `SignedQuoteLib.decodeQuote`.
    ///      Reverts `UnsupportedQuoteVersion` for a wrong version byte, `SignedQuoteDecodeFailed` for failed cheap checks
    ///      (empty payload, tail too short, signature length not 65), or **Panic(0x21)** if `abi.decode` fails on
    ///      sufficiently long but invalid ABI. Does not verify the EIP-712 signature.
    /// @param signedQuote Version-prefixed, ABI-encoded `Quote` struct.
    function decodeQuote(bytes calldata signedQuote) external pure returns (Quote memory);

    /// @notice Look up a single quote item by type from a signed quote.
    /// @dev    Does not validate the quote signature or expiry -- this is a
    ///         lookup utility. Signature validity is asserted inside
    ///         `collectFeesWithQuote`. Decodes `signedQuote` with the same
    ///         `SignedQuoteLib` rules as `decodeQuote` (including panic behavior on malformed ABI).
    /// @param signedQuote  Version-prefixed, ABI-encoded `Quote` struct.
    /// @param quoteType    The fee type to search for.
    /// @return item        The matched `QuoteItem` (zero-valued if not found).
    /// @return found       `true` if a matching item exists in the quote.
    function getQuoteItem(bytes calldata signedQuote, string calldata quoteType)
        external
        pure
        returns (QuoteItem memory item, bool found);

    /// @notice Same as the `signedQuote` overload, but accepts a decoded `Quote` body.
    /// @param decodedQuote ABI-decoded v1 `Quote` (same as for `collectFeesWithQuote`).
    function getQuoteItem(Quote calldata decodedQuote, string calldata quoteType)
        external
        pure
        returns (QuoteItem memory item, bool found);

    /// @notice Return the total fee amount and fee token from a signed quote.
    /// @dev    Does not validate the quote signature or expiry -- this is a
    ///         lookup utility. Signature validity is asserted inside
    ///         `collectFeesWithQuote`. Decodes `signedQuote` with the same
    ///         `SignedQuoteLib` rules as `decodeQuote` (including panic behavior on malformed ABI).
    /// @param signedQuote  Version-prefixed, ABI-encoded `Quote` struct.
    /// @return totalFee    Sum of all `QuoteItem.amount` values in the quote.
    /// @return feeToken    Token address from the quote (`address(0)` for native).
    function getQuoteTotal(bytes calldata signedQuote) external pure returns (uint256 totalFee, address feeToken);

    /// @notice Same as the `signedQuote` overload, but accepts a decoded `Quote` body.
    /// @param decodedQuote ABI-decoded v1 `Quote` (same as for `collectFeesWithQuote`).
    function getQuoteTotal(Quote calldata decodedQuote) external pure returns (uint256 totalFee, address feeToken);

    /// @notice Delegates to the USDC contract address set at deploy and returns its
    ///         `isBlacklisted(account)` result (same USDC deployment `FeeTaker` is wired to on this chain).
    /// @dev    Used to screen third-party intermediaries against that USDC blocklist.
    /// @param account Address to query (typically the caller being screened, e.g. `msg.sender`).
    /// @return Whether the configured USDC contract reports `account` as blacklisted.
    function isDenylisted(address account) external view returns (bool);
}
