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

import {DeployCreate3FactoryViaCreate2} from "../script/deploy/DeployCreate3FactoryViaCreate2.s.sol";
import {ICreate2Factory} from "../script/deploy/interfaces/ICreate2Factory.sol";
import {Create3Factory} from "../src/contracts/Create3Factory.sol";

import {ANVIL_DEFAULT_PK} from "./TestConstants.sol";
import {MockCreate2Factory} from "./mocks/MockCreate2Factory.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Test} from "forge-std/Test.sol";

contract DeployCreate3FactoryViaCreate2Test is Test {
    /// @dev Any address; stands in for the post-handoff Create3Factory owner.
    address internal constant DEPLOYER = address(0xdeadBEef);
    string internal constant CREATE3_FACTORY_SALT_STRING = "fee-orchestrator::v1::create3-factory";

    MockCreate2Factory internal create2Factory;
    DeployCreate3FactoryViaCreate2 internal script;

    function setUp() public {
        address create2Owner = vm.addr(ANVIL_DEFAULT_PK);
        create2Factory = new MockCreate2Factory(create2Owner);

        vm.setEnv("CREATE2_FACTORY_CONTRACT_ADDRESS", vm.toString(address(create2Factory)));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(DEPLOYER));
        vm.setEnv("CREATE3_FACTORY_SALT", CREATE3_FACTORY_SALT_STRING);

        script = new DeployCreate3FactoryViaCreate2();
    }

    function test_deployedAddressMatchesCreate2Prediction() public {
        bytes memory expectedBytecode =
            abi.encodePacked(type(Create3Factory).creationCode, abi.encode(address(create2Factory)));
        bytes32 expectedSalt = keccak256(abi.encodePacked(CREATE3_FACTORY_SALT_STRING));
        address predicted = vm.computeCreate2Address(expectedSalt, keccak256(expectedBytecode), address(create2Factory));

        script.run();

        assertEq(address(script.factory()), predicted, "Create3Factory address mismatch");
    }

    function test_pendingOwnerIsDeployer_factoryStillOwnedByCreate2() public {
        script.run();
        Create3Factory factory = script.factory();

        assertEq(factory.pendingOwner(), DEPLOYER, "pendingOwner != DEPLOYER");
        assertEq(factory.owner(), address(create2Factory), "owner should still be create2Factory");
    }

    function test_acceptOwnershipCompletesHandoff() public {
        script.run();
        Create3Factory factory = script.factory();

        vm.prank(DEPLOYER);
        factory.acceptOwnership();

        assertEq(factory.owner(), DEPLOYER, "owner did not transfer to DEPLOYER");
        assertEq(factory.pendingOwner(), address(0), "pendingOwner should clear after accept");
    }

    function test_create3FactoryAddressMatchesGetAddressOracle() public {
        script.run();
        Create3Factory factory = script.factory();

        bytes32 sampleSalt = keccak256("fee-orchestrator::sample");
        address onChainPrediction = factory.getAddress(sampleSalt);

        // Off-chain CREATE3 derivation mirroring solady:
        //   proxy = CREATE2(factory, salt, keccak256(SOLADY_PROXY_INITCODE))
        //   addr  = CREATE(proxy, nonce=1)
        bytes memory soladyProxyInitcode = hex"67363d3d37363d34f03d5260086018f3";
        address proxy = vm.computeCreate2Address(sampleSalt, keccak256(soladyProxyInitcode), address(factory));
        address offChainPrediction = vm.computeCreateAddress(proxy, 1);

        assertEq(offChainPrediction, onChainPrediction, "CREATE3 prediction mismatch");
    }
}

/// @notice Fork-based verification: prove that the
///         deployed Create3Factory address matches off-chain prediction when
///         we deploy against the REAL Create2Factory on prod chains. Forks
///         mainnet; impersonates the chain's actual create2FactoryOwner;
///         calls deployAndMultiCall on the real prod Create2Factory binary.
///         The only thing under our control is the salt + Create3Factory
///         bytecode — everything else is exactly what will run on deploy day.
///
/// RPC URLs:
///   MAINNET_RPC_URL (default: https://ethereum-rpc.publicnode.com)
///   The mainnet test never skips: it retries a fork pinned behind the chain
///   head and fails if no attempt succeeds. See `_selectForkBehindHead`.
contract DeployCreate3FactoryViaCreate2AtForkedProdFactoriesTest is Test {
    address internal constant PROD_CREATE2_FACTORY = 0xe7b84D8846c96Bb83155Da5537625c75e42d6E42;

    address internal constant DEPLOYER = address(0xdeadBEef);
    string internal constant CREATE3_FACTORY_SALT_STRING = "fee-orchestrator::v1::create3-factory";

    /// @dev Blocks behind head to pin the fork at. Comfortably inside the ~128 blocks of
    ///      state a pruned node retains, and far enough back that every node behind a load
    ///      balancer has it. See `_selectForkBehindHead`.
    uint256 internal constant HEAD_LAG = 64;

    /// @dev Attempts before failing. A retry lands on a different pool member, which is what
    ///      clears a transient `block not found` or a reset connection.
    uint256 internal constant FORK_ATTEMPTS = 3;

    // Under production optimizer settings (`via_ir = true`), running this fork
    // test produces 0x23F6e947132Db95B8282362abA3fc1E3650f26eB (mainnet). We
    // don't assertEq against that literal here because `forge coverage` compiles without
    // the IR optimizer, producing different creationCode → different addresses.

    function test_deployedAtMainnetCreate2Factory_matchesPrediction() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        _runForkVerification(rpcUrl, PROD_CREATE2_FACTORY);
    }

    /// @dev Selects a fork `HEAD_LAG` blocks behind the chain head, retrying on RPC
    ///      errors. Never skips: exhausting the retries fails the test.
    ///
    ///      Forking `latest` is what made this flaky. A load-balanced endpoint can
    ///      answer `eth_blockNumber` from a node ahead of the one that serves the
    ///      follow-up state reads, which surfaces as `block not found` for a block
    ///      the fork was just pinned to. Backing off puts the fork block inside
    ///      every pool member's history while staying well within a pruned node's
    ///      state window, so this still needs no archive node.
    function _selectForkBehindHead(string memory rpcUrl) private {
        string memory lastError = "no attempt made";

        for (uint256 attempt; attempt < FORK_ATTEMPTS; ++attempt) {
            try this.exposedSelectForkBehindHead(rpcUrl) {
                return;
            } catch Error(string memory reason) {
                lastError = reason;
            } catch {
                lastError = "select fork behind head failed";
            }
        }

        emit log_named_string("last RPC error", lastError);
        emit log_named_string("rpc url", rpcUrl);
        revert(string.concat("fork RPC unreachable after retries; rpc url: ", rpcUrl));
    }

    /// @dev External so `_selectForkBehindHead` can `try`/`catch` the cheatcodes. The first
    ///      fork only reads the block header, so it survives the race described above; the
    ///      state reads against the second one are what did not.
    function exposedSelectForkBehindHead(string calldata rpcUrl) external {
        vm.createSelectFork(rpcUrl);

        uint256 head = vm.getBlockNumber();
        uint256 target = head > HEAD_LAG ? head - HEAD_LAG : head;

        vm.createSelectFork(rpcUrl, target);
    }

    /// @dev Fork the given RPC, impersonate the real create2FactoryOwner, call
    ///      deployAndMultiCall on the actual prod Create2Factory binary, and
    ///      verify the resulting Create3Factory address equals what off-chain
    ///      CREATE2 derivation predicts.
    function _runForkVerification(string memory rpcUrl, address create2FactoryAddr)
        internal
        returns (address deployed)
    {
        _selectForkBehindHead(rpcUrl);

        // Sanity-check that the canonical Create2Factory exists on this fork.
        require(create2FactoryAddr.code.length > 0, "Create2Factory not deployed on this fork");

        // Off-chain prediction.
        bytes memory bytecode = abi.encodePacked(type(Create3Factory).creationCode, abi.encode(create2FactoryAddr));
        bytes32 salt = keccak256(abi.encodePacked(CREATE3_FACTORY_SALT_STRING));
        address predicted = vm.computeCreate2Address(salt, keccak256(bytecode), create2FactoryAddr);

        // Once the Create3Factory has shipped to prod, a fresh fork already has it
        // live at the predicted address, so redeploying reverts with CreateCollision.
        // That collision only happens because real-deployed == predicted, which is
        // exactly the invariant under test — so treat an occupied slot as success
        // after sanity-checking the live contract behaves like a Create3Factory.
        // (Under `forge coverage`, no-IR creationCode yields a different, unoccupied
        // address, so the full deploy path below still runs.)
        if (predicted.code.length > 0) {
            _assertLiveCreate3Factory(predicted);
            return predicted;
        }

        // Resolve the real owner from on-chain state and fund it for gas.
        address realOwner = ICreate2Factory(create2FactoryAddr).owner();
        vm.deal(realOwner, 1 ether);

        // Build the same multicall payload the production script does.
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Ownable2Step.transferOwnership, (DEPLOYER));

        // Impersonate the real create2FactoryOwner and call deployAndMultiCall
        // on the actual prod Create2Factory contract.
        vm.startPrank(realOwner);
        deployed = ICreate2Factory(create2FactoryAddr).deployAndMultiCall(0, salt, bytecode, calls);
        vm.stopPrank();

        assertEq(deployed, predicted, "Real-prod-factory deploy does not match off-chain prediction");

        // Confirm Ownable2Step handoff worked: pendingOwner is the deployer,
        // owner is still the Create2Factory itself (constructor arg).
        Create3Factory factory = Create3Factory(deployed);
        assertEq(factory.pendingOwner(), DEPLOYER, "pendingOwner != DEPLOYER");
        assertEq(factory.owner(), create2FactoryAddr, "initial owner should be Create2Factory");
    }

    /// @dev Sanity-checks that the contract already live at the predicted address is a
    ///      functioning Create3Factory, by confirming its on-chain CREATE3 address oracle
    ///      matches the off-chain solady derivation. Ownership state is intentionally not
    ///      asserted here: a prod-deployed factory may have already completed its
    ///      Ownable2Step handoff, so `owner`/`pendingOwner` need not match the post-deploy
    ///      values checked on the fresh-deploy path.
    function _assertLiveCreate3Factory(address factoryAddr) private view {
        Create3Factory factory = Create3Factory(factoryAddr);
        bytes32 sampleSalt = keccak256("fee-orchestrator::sample");
        address onChainPrediction = factory.getAddress(sampleSalt);

        bytes memory soladyProxyInitcode = hex"67363d3d37363d34f03d5260086018f3";
        address proxy = vm.computeCreate2Address(sampleSalt, keccak256(soladyProxyInitcode), factoryAddr);
        address offChainPrediction = vm.computeCreateAddress(proxy, 1);

        assertEq(offChainPrediction, onChainPrediction, "live Create3Factory CREATE3 oracle mismatch");
    }
}
