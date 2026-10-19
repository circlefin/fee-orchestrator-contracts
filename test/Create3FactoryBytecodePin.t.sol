// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Create3Factory} from "../src/contracts/Create3Factory.sol";
import {Test} from "forge-std/Test.sol";

/// @title Create3FactoryBytecodePin
/// @notice Hard pin on the keccak256 of `type(Create3Factory).creationCode`
///         under the production compile profile (`[profile.default]` in
///         `foundry.toml`).
///
///         Create3Factory is the root of this repo's CREATE3 deployment tree:
///           - The factory itself is deployed via CREATE2 by an external
///             Create2Factory. Its address is a pure function of
///             (create2Factory, salt, keccak256(creationCode || abi.encode(initialOwner))),
///             so it IS sensitive to its own creation bytecode.
///           - Every other contract in the tree is deployed by calling
///             `Create3Factory.deploy(salt, ...)`. CREATE3 addresses depend
///             only on (Create3Factory address, salt) — they are NOT sensitive
///             to the deployed contract's bytecode, but they ARE transitively
///             sensitive to Create3Factory's bytecode (via its address).
///
///         Net effect: shifting Create3Factory's creation bytecode by even
///         one byte shifts its own CREATE2 address, which in turn shifts the
///         CREATE3 address of every contract subsequently deployed through it.
///         Predicted addresses already shared with downstream consumers
///         (e.g. pre-signed transactions targeting those addresses) are
///         silently invalidated.
///
///         Concretely, changing ANY of the following will fail this test:
///           - `Create3Factory.sol` source (or any of its imports — Ownable, etc.)
///           - `solc_version` / `auto_detect_solc` in foundry.toml
///           - `optimizer`, `optimizer_runs`, `via_ir` in foundry.toml
///           - `evm_version` in foundry.toml (changes CBOR metadata trailer)
///           - the default `bytecodeHash` setting (changes CBOR metadata trailer)
///           - any source-file relocation that alters `compilationTarget` paths
///
///         If the change is intentional:
///           1. Recompute the new hash (`cast keccak $(jq -r .bytecode.object
///              out/Create3Factory.sol/Create3Factory.json)`)
///           2. Update `EXPECTED_CREATION_CODE_HASH` below
///           3. Coordinate a republish of the predicted addresses with all
///              downstream consumers BEFORE merging — any address previously
///              derived from the old bytecode will no longer be reproducible.
///
/// @dev Excluded from `forge coverage` via `--no-match-test '_pinnedBytecode'`
///      in package.json's coverage script: forge coverage compiles without
///      `via_ir`, producing different bytecode that would always fail this pin.
contract Create3FactoryBytecodePinTest is Test {
    /// Hash of the prod-compiled Create3Factory creation bytecode (1839 bytes).
    /// Matches what `DeployCreate3FactoryViaCreate2.s.sol` reads at deploy time
    /// via `type(Create3Factory).creationCode`.
    bytes32 internal constant EXPECTED_CREATION_CODE_HASH =
        0x0de7451b9011c389def842a10bcf9d81fb28abba2ae58dbc85436b7d194748a0;

    function test_create3FactoryCreationCodeHash_matchesPin_pinnedBytecode() public pure {
        bytes32 actual = keccak256(type(Create3Factory).creationCode);
        assertEq(
            actual,
            EXPECTED_CREATION_CODE_HASH,
            "Create3Factory creation bytecode hash drifted. Any predicted addresses already "
            "shared with downstream consumers are no longer reproducible. See test header for "
            "the update + republish procedure."
        );
    }

    /// @dev Sibling pin: the creation-code length. Catches accidental
    ///      regeneration of the constant without actually rebuilding (e.g.
    ///      someone copies a hash from a stale artifact).
    function test_create3FactoryCreationCodeLength_matchesPin_pinnedBytecode() public pure {
        assertEq(
            type(Create3Factory).creationCode.length,
            1839,
            "Create3Factory creation code length changed; bytecode pin almost certainly stale"
        );
    }
}
