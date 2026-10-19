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

/// @title HookDataLib
/// @notice Utilities for parsing CCTP v2 hook data.
/// @dev    Hook data may contain one or more chained hooks. Each hook has:
///
///         Offset  Bytes  Type      Field
///         0       24     bytes24   Hook name (e.g. "cctp-forward", right-padded)
///         24      4      uint32    Version
///         28      4      uint32    Length of Circle hook data that follows
///         32      var    bytes     Circle hook data (length from above)
///
///         The next hook (if any) starts immediately after the Circle data.
///         This layout is backwards-compatible with a single-hook payload.
///
///         Reference: https://developers.circle.com/cctp/concepts/forwarding-service#hook-format
library HookDataLib {
    /// @dev Per-hook header size: 24 (name) + 4 (version) + 4 (circle data length).
    uint256 private constant HOOK_HEADER_LENGTH = 32;

    // forge-lint: disable-next-line(unsafe-typecast)
    bytes24 internal constant FORWARD_MAGIC = bytes24("cctp-forward");

    struct Hook {
        bytes24 name;
        uint32 version;
        bytes circleData;
    }

    /// @notice Returns a minimal `cctp-forward` hook (version 0, no Circle data).
    function defaultForwardHookData() internal pure returns (bytes memory) {
        return abi.encodePacked(FORWARD_MAGIC, uint32(0), uint32(0));
    }

    /// @notice Searches `hookData` for a `cctp-forward` hook.
    /// @param hookData Raw hook data from a CCTP burn call.
    /// @return hook  The parsed hook (zero-valued when not found).
    /// @return found `true` if a forwarding hook was found.
    function getForwardHook(bytes calldata hookData) internal pure returns (Hook memory hook, bool found) {
        return _findHook(hookData, FORWARD_MAGIC);
    }

    /// @dev Iterates through chained hooks looking for one whose name matches
    ///      `target`. Returns on the first match. If the remaining bytes are
    ///      too short for a valid header or the declared circle-data length
    ///      overflows the remaining data, iteration stops and `found` is false.
    // slither-disable-next-line assembly
    function _findHook(bytes calldata hookData, bytes24 target) private pure returns (Hook memory hook, bool found) {
        uint256 offset = 0;
        while (offset + HOOK_HEADER_LENGTH <= hookData.length) {
            bytes24 name;
            uint32 version;
            uint32 circleDataLen;

            // Single calldataload reads the entire 32-byte header at once,
            // avoiding per-slice bounds checks the compiler would otherwise
            // emit (the while condition already guarantees 32 bytes available).
            //   word layout: [name: 24 bytes (bits 255..64)] [version: 4 bytes (bits 63..32)] [circleDataLen: 4 bytes (bits 31..0)]
            assembly {
                let word := calldataload(add(hookData.offset, offset))
                name := and(word, shl(64, not(0)))
                version := and(shr(32, word), 0xFFFFFFFF)
                circleDataLen := and(word, 0xFFFFFFFF)
            }

            uint256 dataEnd = offset + HOOK_HEADER_LENGTH + circleDataLen;
            if (dataEnd > hookData.length) break;

            if (name == target) {
                hook.name = name;
                hook.version = version;
                hook.circleData = hookData[offset + HOOK_HEADER_LENGTH:dataEnd];
                return (hook, true);
            }

            offset = dataEnd;
        }
    }
}
