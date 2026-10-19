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

import {Roles} from "../../src/constants/Roles.sol";
import {Create3Factory} from "../../src/contracts/Create3Factory.sol";
import {FeeManager} from "../../src/contracts/FeeManager.sol";
import {IWithFeeCollectionAddress} from "../../src/interfaces/IWithFeeCollectionAddress.sol";
import {IWithTrustedQuoteSigners} from "../../src/interfaces/IWithTrustedQuoteSigners.sol";
import {Addresses} from "./Addresses.sol";
import {Broadcaster} from "./Broadcaster.sol";
import {Salts} from "./Salts.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script, console} from "forge-std/Script.sol";

struct DeployFeeManagerConfig {
    Create3Factory factory;
    bytes32 implSalt;
    bytes32 proxySalt;
    address owner;
    address feeTaker;
    address usdc;
    address callerAdmin;
    address signerAdmin;
    address trustedSigner;
    address pauser;
    address feeCollectionAdmin;
    address payable feeCollectionAddress;
    address[] allowedCallers;
}

/// @title DeployFeeManager
/// @notice Deploys FeeManager implementation and UUPS proxy via
///         Create3Factory for deterministic, bytecode-independent addresses.
///         Configures roles atomically via deployAndMultiCall and initiates
///         a two-step ownership transfer to the configured owner.
///         The owner must call acceptOwnership() separately after deployment.
///         Optionally sets an initial trusted quote signer.
///         Pre-registers the predicted TokenMessengerWithFees proxy address
///         as an allowed caller (always included). Additional allowed callers
///         can be supplied via FEE_MANAGER_ALLOWED_CALLERS.
///
/// Required env vars (one of):
///   DEPLOYER_PRIVATE_KEY        – private key used to broadcast transactions
///   DEPLOYER_ADDRESS            – address for unlocked-account mode (Anvil)
///
///   CREATE3_FACTORY_ADDRESS        – address of the pre-deployed Create3Factory
///   FEE_MANAGER_PROXY_SALT         – proxy CREATE3 salt (stable across impl upgrades)
///   FEE_MANAGER_IMPLEMENTATION_SALT – impl CREATE3 salt (bump per new impl)
///   TOKEN_MESSENGER_WITH_FEES_PROXY_SALT – needed to predict the TokenMessengerWithFees proxy for the allowed caller list
///   FEE_TAKER_ADDRESS           – address of the deployed FeeTaker proxy on the target chain
///   USDC_ADDRESS                – USDC token contract (same as FeeTaker's `usdc`); used for `FeeManager.isDenylisted`
///
/// Optional env vars:
///   FEE_MANAGER_OWNER                – final owner address; defaults to the deployer if unset
///   FEE_MANAGER_CALLER_ADMIN         – if set and non-zero, granted CALLER_ADMIN_ROLE (omit for minimal privilege; owner grants later)
///   FEE_MANAGER_SIGNER_ADMIN         – if set and non-zero, granted SIGNER_ADMIN_ROLE (omit for minimal privilege; owner grants later)
///   FEE_MANAGER_FEE_COLLECTION_ADMIN – if set and non-zero, granted FEE_COLLECTION_ADMIN_ROLE (omit for minimal privilege; owner grants later)
///   FEE_MANAGER_TRUSTED_SIGNER       – if set and non-zero, registered as a trusted signer during deploy
///   FEE_MANAGER_PAUSER               – if set and non-zero, granted PAUSER_ROLE during deploy
///   FEE_MANAGER_ALLOWED_CALLERS      – comma-separated addresses granted ALLOWED_CALLER_ROLE (in addition to TMWF proxy)
///   FEE_MANAGER_FEE_COLLECTION_ADDRESS – if set and non-zero, the proxy's `feeCollectionAddress` is set to this value
///                                        atomically during deploy via a temporary FEE_COLLECTION_ADMIN_ROLE grant to the
///                                        Create3Factory (grant → setFeeCollectionAddress → revoke, all within the
///                                        deployAndMultiCall). Omit to leave the proxy's `feeCollectionAddress` unset
///                                        (default address(0)) so the owner/feeCollectionAdmin can set it later off-chain.
contract DeployFeeManager is Script {
    FeeManager public feeManager;
    address public implementation;

    DeployFeeManagerConfig private _config;

    /// @dev Reads deployment config from env vars. Called automatically by `forge script`.
    function setUp() external {
        _config = _loadConfigFromEnv();
    }

    /// @notice Deploy using config loaded from env vars (for `forge script`).
    function run() public {
        _run(_config);
    }

    /// @notice Deploy using an explicit config struct (for tests — avoids vm.setEnv races).
    function runWithConfig(DeployFeeManagerConfig memory config) public {
        _run(config);
    }

    function _run(DeployFeeManagerConfig memory c) private {
        address deployer = Broadcaster.startBroadcast();

        if (c.owner == address(0)) {
            c.owner = deployer;
        }

        implementation = c.factory
            .deploy(c.implSalt, abi.encodePacked(type(FeeManager).creationCode, abi.encode(c.feeTaker, c.usdc)));

        bytes memory initData = abi.encodeCall(FeeManager.initialize, (address(c.factory)));
        bytes memory proxyBytecode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData));

        address proxy = c.factory.deployAndMultiCall(c.proxySalt, proxyBytecode, _buildProxyCalls(c));
        feeManager = FeeManager(payable(proxy));

        vm.stopBroadcast();

        _logDeployment(c);
        console.log("\nPost-deploy: owner must call acceptOwnership() on proxy", address(feeManager));
    }

    function _loadConfigFromEnv() private view returns (DeployFeeManagerConfig memory c) {
        c.factory = Create3Factory(vm.envAddress("CREATE3_FACTORY_ADDRESS"));
        c.implSalt = Salts.feeManagerImpl();
        c.proxySalt = Salts.feeManagerProxy();
        c.owner = vm.envOr("FEE_MANAGER_OWNER", address(0));
        c.callerAdmin = vm.envOr("FEE_MANAGER_CALLER_ADMIN", address(0));
        c.signerAdmin = vm.envOr("FEE_MANAGER_SIGNER_ADMIN", address(0));
        c.trustedSigner = vm.envOr("FEE_MANAGER_TRUSTED_SIGNER", address(0));
        c.pauser = vm.envOr("FEE_MANAGER_PAUSER", address(0));
        c.feeCollectionAdmin = vm.envOr("FEE_MANAGER_FEE_COLLECTION_ADMIN", address(0));
        c.feeCollectionAddress = payable(vm.envOr("FEE_MANAGER_FEE_COLLECTION_ADDRESS", address(0)));
        c.feeTaker = vm.envAddress("FEE_TAKER_ADDRESS");
        c.usdc = vm.envAddress("USDC_ADDRESS");

        string memory extraCallersRaw = vm.envOr("FEE_MANAGER_ALLOWED_CALLERS", string(""));
        address[] memory extraCallers;
        if (bytes(extraCallersRaw).length > 0) {
            extraCallers = vm.envAddress("FEE_MANAGER_ALLOWED_CALLERS", ",");
        } else {
            extraCallers = new address[](0);
        }
        c.allowedCallers = new address[](extraCallers.length + 1);
        c.allowedCallers[0] = Addresses.tokenMessengerWithFeesProxy();
        for (uint256 i = 0; i < extraCallers.length; ++i) {
            c.allowedCallers[i + 1] = extraCallers[i];
        }
    }

    function _logDeployment(DeployFeeManagerConfig memory c) private view {
        console.log("FeeManager implementation:", implementation);
        console.log("FeeManager proxy:", address(feeManager));
        console.log("FeeTaker:", feeManager.feeTaker());
        console.log("USDC:", feeManager.usdcBlacklist());
        console.log("Pending owner:", c.owner);
        console.log(
            "CALLER_ADMIN_ROLE:", c.callerAdmin == address(0) ? "none (grant via owner)" : vm.toString(c.callerAdmin)
        );
        console.log(
            "SIGNER_ADMIN_ROLE:", c.signerAdmin == address(0) ? "none (grant via owner)" : vm.toString(c.signerAdmin)
        );
        for (uint256 i = 0; i < c.allowedCallers.length; ++i) {
            console.log("ALLOWED_CALLER_ROLE:", c.allowedCallers[i]);
        }
        console.log("PAUSER_ROLE:", c.pauser == address(0) ? "none" : vm.toString(c.pauser));
        console.log(
            "FEE_COLLECTION_ADMIN_ROLE:",
            c.feeCollectionAdmin == address(0) ? "none (grant via owner)" : vm.toString(c.feeCollectionAdmin)
        );
        console.log(
            "feeCollectionAddress:",
            c.feeCollectionAddress == address(0) ? "unset (default address(0))" : vm.toString(c.feeCollectionAddress)
        );
        console.log("Trusted signer:", c.trustedSigner == address(0) ? "none" : vm.toString(c.trustedSigner));
    }

    /// @dev Builds the multicall array for proxy role configuration.
    function _buildProxyCalls(DeployFeeManagerConfig memory c) private pure returns (bytes[] memory calls) {
        address factoryAddr = address(c.factory);
        uint256 callCount = 5 + c.allowedCallers.length;
        if (c.callerAdmin != address(0)) ++callCount;
        if (c.signerAdmin != address(0)) ++callCount;
        if (c.trustedSigner != address(0)) ++callCount;
        if (c.pauser != address(0)) ++callCount;
        if (c.feeCollectionAdmin != address(0)) ++callCount;
        if (c.feeCollectionAddress != address(0)) callCount += 3;

        calls = new bytes[](callCount);
        uint256 idx = 0;

        calls[idx] = abi.encodeCall(IAccessControl.grantRole, (Roles.CALLER_ADMIN_ROLE, factoryAddr));
        calls[++idx] = abi.encodeCall(IAccessControl.grantRole, (Roles.SIGNER_ADMIN_ROLE, factoryAddr));
        for (uint256 i = 0; i < c.allowedCallers.length; ++i) {
            calls[++idx] = abi.encodeCall(IAccessControl.grantRole, (Roles.ALLOWED_CALLER_ROLE, c.allowedCallers[i]));
        }

        if (c.callerAdmin != address(0)) {
            calls[++idx] = abi.encodeCall(IAccessControl.grantRole, (Roles.CALLER_ADMIN_ROLE, c.callerAdmin));
        }
        if (c.signerAdmin != address(0)) {
            calls[++idx] = abi.encodeCall(IAccessControl.grantRole, (Roles.SIGNER_ADMIN_ROLE, c.signerAdmin));
        }
        if (c.trustedSigner != address(0)) {
            calls[++idx] = abi.encodeCall(IWithTrustedQuoteSigners.setTrustedQuoteSigner, (c.trustedSigner, true));
        }
        if (c.pauser != address(0)) {
            calls[++idx] = abi.encodeCall(IAccessControl.grantRole, (Roles.PAUSER_ROLE, c.pauser));
        }
        if (c.feeCollectionAdmin != address(0)) {
            calls[++idx] =
                abi.encodeCall(IAccessControl.grantRole, (Roles.FEE_COLLECTION_ADMIN_ROLE, c.feeCollectionAdmin));
        }
        if (c.feeCollectionAddress != address(0)) {
            idx = _appendSetFeeCollectionAddressCalls(calls, idx, factoryAddr, c.feeCollectionAddress);
        }

        calls[++idx] = abi.encodeCall(IAccessControl.revokeRole, (Roles.CALLER_ADMIN_ROLE, factoryAddr));
        calls[++idx] = abi.encodeCall(IAccessControl.revokeRole, (Roles.SIGNER_ADMIN_ROLE, factoryAddr));
        calls[++idx] = abi.encodeCall(Ownable.transferOwnership, (c.owner));
    }

    /// @dev Appends a temp-grant / setFeeCollectionAddress / revoke sequence to the multicall.
    ///      Mirrors the same temp-grant / use / revoke pattern used for CALLER_ADMIN_ROLE +
    ///      SIGNER_ADMIN_ROLE in `_buildProxyCalls`, but kept local since setFeeCollectionAddress
    ///      is the only call needing FEE_COLLECTION_ADMIN_ROLE and the factory must retain no
    ///      residual permission beyond this multicall. `idx` parameter is the last-written index
    ///      coming in; returns the new last-written index after the 3 appends.
    function _appendSetFeeCollectionAddressCalls(
        bytes[] memory calls,
        uint256 idx,
        address factoryAddr,
        address payable feeCollectionAddress
    ) private pure returns (uint256 newIdx) {
        calls[++idx] = abi.encodeCall(IAccessControl.grantRole, (Roles.FEE_COLLECTION_ADMIN_ROLE, factoryAddr));
        calls[++idx] = abi.encodeCall(IWithFeeCollectionAddress.setFeeCollectionAddress, (feeCollectionAddress));
        calls[++idx] = abi.encodeCall(IAccessControl.revokeRole, (Roles.FEE_COLLECTION_ADMIN_ROLE, factoryAddr));
        return idx;
    }
}
