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

import {DeployFeeManager, DeployFeeManagerConfig} from "../script/deploy/DeployFeeManager.s.sol";
import {
    DeployTokenMessengerWithFees,
    DeployTokenMessengerWithFeesConfig
} from "../script/deploy/DeployTokenMessengerWithFees.s.sol";
import {Salts} from "../script/deploy/Salts.sol";
import {Roles} from "../src/constants/Roles.sol";
import {Create3Factory} from "../src/contracts/Create3Factory.sol";
import {FeeManager} from "../src/contracts/FeeManager.sol";
import {TokenMessengerWithFees} from "../src/contracts/TokenMessengerWithFees.sol";
import {ANVIL_DEFAULT_PK} from "./TestConstants.sol";
import {MockMessageTransmitter} from "./mocks/MockMessageTransmitter.sol";
import {MockTokenMessenger} from "./mocks/MockTokenMessenger.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Cached salt-derived values for both FM and TMWF deployments.
struct CachedSalts {
    bytes32 fmImplSalt;
    bytes32 fmProxySalt;
    bytes32 tmwfImplSalt;
    bytes32 tmwfProxySalt;
    address predictedTmwfProxy;
}

contract DeployTokenMessengerWithFeesTest is Test {
    DeployTokenMessengerWithFees internal script;
    TokenMessengerWithFees internal tmwf;
    FeeManager internal fm;
    Create3Factory internal factory;
    address internal deployer;
    address internal mockTokenMessengerV2;
    address internal feeTakerAddr;
    address internal usdcBlacklistAddr;

    /// @dev Sets deployment salt env vars and immediately caches all salt-derived values.
    function _cacheSaltsForSalt(string memory salt) internal returns (CachedSalts memory s) {
        vm.setEnv("FEE_MANAGER_PROXY_SALT", string.concat(salt, ".fm.proxy"));
        vm.setEnv("FEE_MANAGER_IMPLEMENTATION_SALT", string.concat(salt, ".fm.impl"));
        vm.setEnv("TOKEN_MESSENGER_WITH_FEES_PROXY_SALT", string.concat(salt, ".tmwf.proxy"));
        vm.setEnv("TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT", string.concat(salt, ".tmwf.impl"));
        s.fmImplSalt = Salts.feeManagerImpl();
        s.fmProxySalt = Salts.feeManagerProxy();
        s.tmwfImplSalt = Salts.tokenMessengerWithFeesImpl();
        s.tmwfProxySalt = Salts.tokenMessengerWithFeesProxy();
        s.predictedTmwfProxy = factory.getAddress(s.tmwfProxySalt);
    }

    function _fmConfig(CachedSalts memory s) internal view returns (DeployFeeManagerConfig memory) {
        address[] memory callers = new address[](1);
        callers[0] = s.predictedTmwfProxy;
        return DeployFeeManagerConfig({
            factory: factory,
            implSalt: s.fmImplSalt,
            proxySalt: s.fmProxySalt,
            owner: address(0),
            feeTaker: feeTakerAddr,
            usdc: usdcBlacklistAddr,
            callerAdmin: address(0),
            signerAdmin: address(0),
            trustedSigner: address(0),
            pauser: address(0),
            feeCollectionAdmin: address(0),
            feeCollectionAddress: payable(address(0)),
            allowedCallers: callers
        });
    }

    function _tmwfConfig(CachedSalts memory s, address feeManagerProxy)
        internal
        view
        returns (DeployTokenMessengerWithFeesConfig memory)
    {
        return DeployTokenMessengerWithFeesConfig({
            factory: factory,
            tokenMessengerV2: mockTokenMessengerV2,
            feeManagerProxy: feeManagerProxy,
            owner: address(0),
            implSalt: s.tmwfImplSalt,
            proxySalt: s.tmwfProxySalt
        });
    }

    function setUp() public {
        deployer = vm.addr(ANVIL_DEFAULT_PK);
        feeTakerAddr = makeAddr("feeTaker");
        usdcBlacklistAddr = makeAddr("usdcBlacklist");
        MockMessageTransmitter mt = new MockMessageTransmitter(0);
        mockTokenMessengerV2 = address(new MockTokenMessenger(address(mt)));

        vm.prank(deployer);
        factory = new Create3Factory(deployer);

        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(ANVIL_DEFAULT_PK));
        vm.setEnv("CREATE3_FACTORY_ADDRESS", vm.toString(address(factory)));

        CachedSalts memory salts = _cacheSaltsForSalt("fee-orchestrator-v1");

        DeployFeeManager fmScript = new DeployFeeManager();
        fmScript.runWithConfig(_fmConfig(salts));
        fm = fmScript.feeManager();

        script = new DeployTokenMessengerWithFees();
        script.runWithConfig(_tmwfConfig(salts, address(fm)));
        tmwf = script.tokenMessengerWithFees();
    }

    function test_deploy_setsPendingOwnerToDeployer() public view {
        assertEq(tmwf.pendingOwner(), deployer);
    }

    function test_deploy_factoryRemainsOwnerUntilAcceptance() public view {
        assertEq(tmwf.owner(), address(factory));
    }

    function test_deploy_setsTokenMessenger() public view {
        assertEq(tmwf.tokenMessenger(), mockTokenMessengerV2);
    }

    function test_deploy_setsFeeManager() public view {
        assertEq(tmwf.feeManager(), address(fm));
    }

    function test_deploy_predictedProxyMatchesAllowedCaller() public view {
        assertTrue(fm.hasRole(Roles.ALLOWED_CALLER_ROLE, address(tmwf)));
    }

    function test_deploy_proxyPointsToImplementation() public view {
        assertTrue(script.implementation() != address(0));
        assertEq(address(tmwf), address(script.tokenMessengerWithFees()));
        assertTrue(script.implementation() != address(tmwf));
    }

    function test_deploy_ownershipTransferInitiated() public view {
        assertEq(tmwf.owner(), address(factory));
        assertEq(tmwf.pendingOwner(), deployer);
    }

    function test_deploy_withExplicitOwner_setsPendingOwner() public {
        address explicitOwner = makeAddr("explicitOwner");

        CachedSalts memory salts = _cacheSaltsForSalt("test-explicit-owner");

        DeployFeeManager fmScript2 = new DeployFeeManager();
        fmScript2.runWithConfig(_fmConfig(salts));

        DeployTokenMessengerWithFeesConfig memory config = _tmwfConfig(salts, address(fmScript2.feeManager()));
        config.owner = explicitOwner;

        DeployTokenMessengerWithFees s2 = new DeployTokenMessengerWithFees();
        s2.runWithConfig(config);

        assertEq(s2.tokenMessengerWithFees().pendingOwner(), explicitOwner);
        assertEq(s2.tokenMessengerWithFees().owner(), address(factory));
    }

    function test_deploy_withDifferentSalt_producesDifferentAddresses() public {
        CachedSalts memory salts = _cacheSaltsForSalt("fee-orchestrator-v2");

        DeployFeeManager fmScript2 = new DeployFeeManager();
        fmScript2.runWithConfig(_fmConfig(salts));

        DeployTokenMessengerWithFees s2 = new DeployTokenMessengerWithFees();
        s2.runWithConfig(_tmwfConfig(salts, address(fmScript2.feeManager())));

        assertTrue(address(s2.tokenMessengerWithFees()) != address(tmwf));
        assertTrue(s2.implementation() != script.implementation());
    }
}
