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

import {BurnMessageV2Lib} from "../src/libraries/BurnMessageV2Lib.sol";
import {MessageV2Lib} from "../src/libraries/MessageV2Lib.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Test vectors derived from the same Base mainnet transaction used
///      in MessageV2Lib.t.sol:
///      https://basescan.org/tx/0x52b96e0f5a0459a830c590a31f8b057847356ff4d7b54a45f3394a5d684ba2c4
contract BurnMessageV2LibTest is Test {
    uint32 internal constant VERSION = 1;
    bytes32 internal constant BURN_TOKEN = bytes32(uint256(uint160(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)));
    bytes32 internal constant MINT_RECIPIENT = bytes32(uint256(uint160(0xC01f5E3dcdE4f1E8F1dC8Cf1232123DAEB917b8D)));
    uint256 internal constant AMOUNT = 30_061_721;
    bytes32 internal constant MESSAGE_SENDER = bytes32(uint256(uint160(0xC01f5E3dcdE4f1E8F1dC8Cf1232123DAEB917b8D)));

    /// @dev Full BurnMessageV2 body from the real transaction (relay format: trailing fee fields zero).
    function _expectedRawBody() internal pure returns (bytes memory) {
        return hex"00000001" hex"000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913"
            hex"000000000000000000000000c01f5e3dcde4f1e8f1dc8cf1232123daeb917b8d"
            hex"0000000000000000000000000000000000000000000000000000000001cab499"
            hex"000000000000000000000000c01f5e3dcde4f1e8f1dc8cf1232123daeb917b8d"
            hex"0000000000000000000000000000000000000000000000000000000000000000" // maxFee
            hex"0000000000000000000000000000000000000000000000000000000000000000" // feeExecuted
            hex"0000000000000000000000000000000000000000000000000000000000000000"; // expirationBlock
    }

    // ───────────────────── real transaction verification ─────────────────────

    function test_formatMessage_matchesRealTransaction() public pure {
        bytes memory encoded =
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, "");
        assertEq(keccak256(encoded), keccak256(_expectedRawBody()));
    }

    // ───────────────────── encoding properties ─────────────────────

    function test_formatMessage_length() public pure {
        bytes memory encoded =
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, "");
        assertEq(encoded.length, 228);
    }

    function test_formatMessageWithHook_length() public pure {
        bytes memory hookData = hex"deadbeef";
        bytes memory encoded =
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, hookData);
        assertEq(encoded.length, 228 + hookData.length);
    }

    function test_formatMessage_emptyHookData_length228() public pure {
        bytes memory withoutHook =
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, "");
        bytes memory withEmptyHook =
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, "");
        assertEq(keccak256(withoutHook), keccak256(withEmptyHook));
    }

    function test_formatMessageWithHook_appendsHookData() public pure {
        bytes memory hookData = hex"cafebabe";
        bytes memory encoded =
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, hookData);
        bytes memory expected = _expectedRawBody();

        // First 228 bytes match the base message (including zero maxFee / feeExecuted / expirationBlock)
        bytes memory prefix = new bytes(228);
        for (uint256 i = 0; i < 228; i++) {
            prefix[i] = encoded[i];
        }
        assertEq(keccak256(prefix), keccak256(expected));

        // Trailing bytes match hookData
        bytes memory suffix = new bytes(hookData.length);
        for (uint256 i = 0; i < hookData.length; i++) {
            suffix[i] = encoded[228 + i];
        }
        assertEq(keccak256(suffix), keccak256(hookData));
    }

    // ───────────────────── field sensitivity ─────────────────────

    function test_versionAffectsHash() public pure {
        bytes32 h1 =
            keccak256(BurnMessageV2Lib.formatMessage(1, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, ""));
        bytes32 h2 =
            keccak256(BurnMessageV2Lib.formatMessage(2, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, ""));
        assertTrue(h1 != h2);
    }

    function test_burnTokenAffectsHash() public pure {
        bytes32 h1 = keccak256(
            BurnMessageV2Lib.formatMessage(VERSION, bytes32(uint256(1)), MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, "")
        );
        bytes32 h2 = keccak256(
            BurnMessageV2Lib.formatMessage(VERSION, bytes32(uint256(2)), MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, "")
        );
        assertTrue(h1 != h2);
    }

    function test_mintRecipientAffectsHash() public pure {
        bytes32 h1 = keccak256(
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, bytes32(uint256(1)), AMOUNT, MESSAGE_SENDER, "")
        );
        bytes32 h2 = keccak256(
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, bytes32(uint256(2)), AMOUNT, MESSAGE_SENDER, "")
        );
        assertTrue(h1 != h2);
    }

    function test_amountAffectsHash() public pure {
        bytes32 h1 =
            keccak256(BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, 100, MESSAGE_SENDER, ""));
        bytes32 h2 =
            keccak256(BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, 200, MESSAGE_SENDER, ""));
        assertTrue(h1 != h2);
    }

    function test_messageSenderAffectsHash() public pure {
        bytes32 h1 = keccak256(
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, bytes32(uint256(1)), "")
        );
        bytes32 h2 = keccak256(
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, bytes32(uint256(2)), "")
        );
        assertTrue(h1 != h2);
    }

    function test_hookDataAffectsHash() public pure {
        bytes32 h1 = keccak256(
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, hex"aa")
        );
        bytes32 h2 = keccak256(
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, hex"bb")
        );
        assertTrue(h1 != h2);
    }

    // ───────────────────── fuzz ─────────────────────

    function testFuzz_formatMessage_emptyHookData_length228(
        uint32 version,
        bytes32 burnToken,
        bytes32 mintRecipient,
        uint256 amount,
        bytes32 messageSender
    ) public pure {
        bytes memory encoded = BurnMessageV2Lib.formatMessage(
            version, burnToken, mintRecipient, amount, messageSender, ""
        );
        assertEq(encoded.length, 228);
    }

    function testFuzz_formatMessage_length(
        uint32 version,
        bytes32 burnToken,
        bytes32 mintRecipient,
        uint256 amount,
        bytes32 messageSender,
        bytes memory hookData
    ) public pure {
        bytes memory encoded = BurnMessageV2Lib.formatMessage(
            version, burnToken, mintRecipient, amount, messageSender, hookData
        );
        assertEq(encoded.length, 228 + hookData.length);
    }

    // ───────────────────── cross-library: correlation hash ─────────────────────

    /// @dev `expectedHash` = `keccak256(abi.decode(messageSentLogData, (bytes)))`.
    ///      `messageSentLogData` is the raw `data` field from `MessageSent` on Base:
    ///      https://basescan.org/tx/0x52b96e0f5a0459a830c590a31f8b057847356ff4d7b54a45f3394a5d684ba2c4
    ///      (MessageTransmitter `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64`, log index 1045).
    ///      Extract with `cast receipt <txHash> --rpc-url https://mainnet.base.org logs`.
    function test_correlationHash_matchesKnownTransaction() public pure {
        bytes memory messageSentLogData = hex"0000000000000000000000000000000000000000000000000000000000000020"
            hex"0000000000000000000000000000000000000000000000000000000000000178"
            hex"0000000100000006000000020000000000000000000000000000000000000000"
            hex"00000000000000000000000000000000000000000000000028b5a0e9c621a5ba"
            hex"daa536219b3a228c8168cf5d00000000000000000000000028b5a0e9c621a5ba"
            hex"daa536219b3a228c8168cf5d0000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000010000000000000000"
            hex"00000000833589fcd6edb6e08f4c7c32d4f71b54bda029130000000000000000"
            hex"00000000c01f5e3dcde4f1e8f1dc8cf1232123daeb917b8d0000000000000000"
            hex"000000000000000000000000000000000000000001cab4990000000000000000"
            hex"00000000c01f5e3dcde4f1e8f1dc8cf1232123daeb917b8d0000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000000";

        bytes memory decodedMessageSentBytes = abi.decode(messageSentLogData, (bytes));
        bytes32 expectedHash = keccak256(decodedMessageSentBytes);

        bytes memory body =
            BurnMessageV2Lib.formatMessage(VERSION, BURN_TOKEN, MINT_RECIPIENT, AMOUNT, MESSAGE_SENDER, "");

        bytes32 hash = MessageV2Lib.messageHash(
            6, // sourceDomain (Base)
            2, // destinationDomain
            bytes32(uint256(uint160(0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d))), // sender
            bytes32(uint256(uint160(0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d))), // recipient
            bytes32(0), // destinationCaller
            0, // minFinalityThreshold
            body
        );

        assertEq(hash, expectedHash);
    }
}
