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

import {MessageV2Lib} from "../src/libraries/MessageV2Lib.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Test vectors derived from a real Base mainnet transaction:
///      https://basescan.org/tx/0x52b96e0f5a0459a830c590a31f8b057847356ff4d7b54a45f3394a5d684ba2c4
///      MessageSent event (log #5), DepositForBurn event (log #6).
///
///      The message bytes were extracted from the event data returned by
///      `cast receipt ... --rpc-url https://mainnet.base.org --json` and
///      ABI-decoded (offset 0x40, length 0x178 = 376 bytes).
///
///      keccak256 was verified independently via `cast keccak <hex>`.
contract MessageV2LibTest is Test {
    // --- relay-formatted message (nonce = 0, as emitted in MessageSent) ---

    /// @dev keccak256 of the 376-byte relay-formatted message from the MessageSent event.
    bytes32 internal constant EXPECTED_HASH = 0xb91aacdec0b76448a882084c57a193108bb8679770a836028894509ab328d06a;

    // --- attested message (nonce assigned by the CCTP attestation service) ---

    /// @dev Nonce assigned by the Iris attestation service for the same message.
    ///      Queried via:
    ///      https://iris-api.circle.com/v2/messages/6?transactionHash=0x52b96e0f5a0459a830c590a31f8b057847356ff4d7b54a45f3394a5d684ba2c4
    bytes32 internal constant ATTESTED_NONCE = 0xd866772989845774d5cac444b530ed02e16683c5d185bd0c16c824bbbe24243b;

    /// @dev keccak256 of the message with ATTESTED_NONCE spliced into the nonce
    ///      field (bytes 12..43). This is the hash the attestation service signs.
    bytes32 internal constant EXPECTED_ATTESTED_HASH =
        0x46b34fe9b711a08e366535049dcdeca2b616d2f0c1d1541d3a33dca7f2715a3f;

    // --- decoded header fields ---

    uint32 internal constant SOURCE_DOMAIN = 6; // Base
    uint32 internal constant DESTINATION_DOMAIN = 2;
    bytes32 internal constant SENDER = bytes32(uint256(uint160(0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d)));
    bytes32 internal constant RECIPIENT = bytes32(uint256(uint160(0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d)));
    bytes32 internal constant DESTINATION_CALLER = bytes32(0);
    uint32 internal constant MIN_FINALITY_THRESHOLD = 0;

    /// @dev Returns the full 376-byte message from the MessageSent event.
    function _rawMessage() internal pure returns (bytes memory) {
        return
            // header (148 bytes)
            hex"00000001" // version = 1
            hex"00000006" // sourceDomain = 6
            hex"00000002" // destinationDomain = 2
            hex"0000000000000000000000000000000000000000000000000000000000000000" // nonce
            hex"00000000000000000000000028b5a0e9c621a5badaa536219b3a228c8168cf5d" // sender
            hex"00000000000000000000000028b5a0e9c621a5badaa536219b3a228c8168cf5d" // recipient
            hex"0000000000000000000000000000000000000000000000000000000000000000" // destinationCaller
            hex"00000000" // minFinalityThreshold = 0
            hex"00000000" // finalityThresholdExecuted = 0
            // BurnMessageV2 body (228 bytes)
            hex"00000001" // burnMessage version = 1
            hex"000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913" // burnToken (USDC)
            hex"000000000000000000000000c01f5e3dcde4f1e8f1dc8cf1232123daeb917b8d" // mintRecipient
            hex"0000000000000000000000000000000000000000000000000000000001cab499" // amount = 30_061_721
            hex"000000000000000000000000c01f5e3dcde4f1e8f1dc8cf1232123daeb917b8d" // messageSender
            hex"0000000000000000000000000000000000000000000000000000000000000000" // maxFee = 0
            hex"0000000000000000000000000000000000000000000000000000000000000000" // feeExecuted = 0
            hex"0000000000000000000000000000000000000000000000000000000000000000"; // expirationBlock = 0
    }

    /// @dev Slices the message body (offset 148+) from the raw message.
    function _messageBody() internal pure returns (bytes memory) {
        bytes memory raw = _rawMessage();
        uint256 bodyLen = raw.length - 148;
        bytes memory body = new bytes(bodyLen);
        for (uint256 i = 0; i < bodyLen; i++) {
            body[i] = raw[148 + i];
        }
        return body;
    }

    // ───────────────────── real transaction verification ─────────────────────

    function test_rawMessageHash_matchesKnownTransaction() public pure {
        assertEq(keccak256(_rawMessage()), EXPECTED_HASH);
    }

    function test_messageHash_matchesKnownTransaction() public pure {
        bytes32 hash = MessageV2Lib.messageHash(
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            MIN_FINALITY_THRESHOLD,
            _messageBody()
        );
        assertEq(hash, EXPECTED_HASH);
    }

    function test_formatMessage_matchesRawBytes() public pure {
        bytes memory formatted = MessageV2Lib.formatMessage(
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            MIN_FINALITY_THRESHOLD,
            _messageBody()
        );
        assertEq(keccak256(formatted), keccak256(_rawMessage()));
    }

    // ───────────────────── attested message verification ─────────────────────

    /// @dev The relay-formatted message (from MessageSent) carries EMPTY_NONCE.
    ///      The CCTP attestation service (Iris) assigns a real nonce before
    ///      signing. Splicing ATTESTED_NONCE into the nonce field must produce
    ///      EXPECTED_ATTESTED_HASH — the hash the attestation service signs and
    ///      that `receiveMessage` on the destination chain verifies.
    function test_attestedMessageHash_matchesIrisApi() public pure {
        bytes memory raw = _rawMessage();
        bytes32 nonce = ATTESTED_NONCE;
        assembly {
            mstore(add(raw, 44), nonce) // offset 32 (mem prefix) + 12 (nonce index)
        }
        assertEq(keccak256(raw), EXPECTED_ATTESTED_HASH);
    }

    // ───────────────────── encoding properties ──────────────────────────────

    function test_formatMessage_length() public pure {
        bytes memory body = hex"deadbeef";
        bytes memory encoded =
            MessageV2Lib.formatMessage(1, 2, bytes32(uint256(0xAA)), bytes32(uint256(0xBB)), bytes32(0), 1000, body);
        assertEq(encoded.length, 148 + body.length);
    }

    function test_formatMessage_emptyBody() public pure {
        bytes memory encoded =
            MessageV2Lib.formatMessage(1, 2, bytes32(uint256(0xAA)), bytes32(uint256(0xBB)), bytes32(0), 0, "");
        assertEq(encoded.length, 148);
    }

    function test_messageHash_isKeccakOfFormatMessage() public pure {
        bytes memory body = hex"cafebabe";
        bytes memory encoded =
            MessageV2Lib.formatMessage(6, 2, bytes32(uint256(0xAA)), bytes32(uint256(0xBB)), bytes32(0), 0, body);
        bytes32 hash =
            MessageV2Lib.messageHash(6, 2, bytes32(uint256(0xAA)), bytes32(uint256(0xBB)), bytes32(0), 0, body);
        assertEq(hash, keccak256(encoded));
    }

    function testFuzz_messageHash_isKeccakOfFormatMessage(
        uint32 sourceDomain,
        uint32 destinationDomain,
        bytes32 sender,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        bytes memory messageBody
    ) public pure {
        bytes memory encoded = MessageV2Lib.formatMessage(
            sourceDomain, destinationDomain, sender, recipient, destinationCaller, minFinalityThreshold, messageBody
        );
        bytes32 hash = MessageV2Lib.messageHash(
            sourceDomain, destinationDomain, sender, recipient, destinationCaller, minFinalityThreshold, messageBody
        );
        assertEq(hash, keccak256(encoded));
    }

    function test_formatMessage_differentInputs_differentHashes() public pure {
        bytes memory body = hex"00";
        bytes32 h1 = MessageV2Lib.messageHash(1, 2, bytes32(uint256(1)), bytes32(uint256(2)), bytes32(0), 0, body);
        bytes32 h2 = MessageV2Lib.messageHash(1, 3, bytes32(uint256(1)), bytes32(uint256(2)), bytes32(0), 0, body);
        assertTrue(h1 != h2);
    }

    function test_formatMessage_senderAffectsHash() public pure {
        bytes memory body = hex"00";
        bytes32 h1 = MessageV2Lib.messageHash(1, 2, bytes32(uint256(0xAA)), bytes32(uint256(2)), bytes32(0), 0, body);
        bytes32 h2 = MessageV2Lib.messageHash(1, 2, bytes32(uint256(0xBB)), bytes32(uint256(2)), bytes32(0), 0, body);
        assertTrue(h1 != h2);
    }

    function test_formatMessage_bodyAffectsHash() public pure {
        bytes32 h1 = MessageV2Lib.messageHash(1, 2, bytes32(uint256(1)), bytes32(uint256(2)), bytes32(0), 0, hex"aa");
        bytes32 h2 = MessageV2Lib.messageHash(1, 2, bytes32(uint256(1)), bytes32(uint256(2)), bytes32(0), 0, hex"bb");
        assertTrue(h1 != h2);
    }
}
