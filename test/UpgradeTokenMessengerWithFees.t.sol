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
import {
    UpgradeTmwfImplConfig,
    UpgradeTokenMessengerWithFees
} from "../script/deploy/UpgradeTokenMessengerWithFees.s.sol";
import {Create3Factory} from "../src/contracts/Create3Factory.sol";
import {FeeManager} from "../src/contracts/FeeManager.sol";
import {TokenMessengerWithFees} from "../src/contracts/TokenMessengerWithFees.sol";
import {ANVIL_DEFAULT_PK} from "./TestConstants.sol";
import {MockMessageTransmitter} from "./mocks/MockMessageTransmitter.sol";
import {MockTokenMessenger} from "./mocks/MockTokenMessenger.sol";
import {Test} from "forge-std/Test.sol";

contract UpgradeTokenMessengerWithFeesTest is Test {
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    DeployTokenMessengerWithFees internal deployTmwfScript;
    TokenMessengerWithFees internal tmwf;
    FeeManager internal fm;
    Create3Factory internal factory;
    address internal deployer;
    address internal mockTokenMessengerV2;

    /// @dev Sets the impl salt env var and immediately caches it into a config struct.
    function _upgradeImplConfigForSalt(string memory implSalt) internal returns (UpgradeTmwfImplConfig memory) {
        return _upgradeImplConfigForSaltWith(implSalt, address(fm));
    }

    /// @dev Like _upgradeImplConfigForSalt but with a custom feeManagerProxy.
    function _upgradeImplConfigForSaltWith(string memory implSalt, address feeManagerProxy)
        internal
        returns (UpgradeTmwfImplConfig memory)
    {
        vm.setEnv("TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT", string.concat(implSalt, ".tmwf.impl"));
        return UpgradeTmwfImplConfig({
            factory: factory,
            implSalt: Salts.tokenMessengerWithFeesImpl(),
            tokenMessengerV2: mockTokenMessengerV2,
            feeManagerProxy: feeManagerProxy
        });
    }

    function setUp() public {
        deployer = vm.addr(ANVIL_DEFAULT_PK);
        MockMessageTransmitter mt = new MockMessageTransmitter(0);
        mockTokenMessengerV2 = address(new MockTokenMessenger(address(mt)));

        vm.prank(deployer);
        factory = new Create3Factory(deployer);

        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(ANVIL_DEFAULT_PK));
        vm.setEnv("CREATE3_FACTORY_ADDRESS", vm.toString(address(factory)));
        vm.setEnv("FEE_MANAGER_PROXY_SALT", "fee-orchestrator-v1.fm.proxy");
        vm.setEnv("FEE_MANAGER_IMPLEMENTATION_SALT", "fee-orchestrator-v1.fm.impl");
        vm.setEnv("TOKEN_MESSENGER_WITH_FEES_PROXY_SALT", "fee-orchestrator-v1.tmwf.proxy");
        vm.setEnv("TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT", "fee-orchestrator-v1.tmwf.impl");

        bytes32 fmImplSalt = Salts.feeManagerImpl();
        bytes32 fmProxySalt = Salts.feeManagerProxy();
        bytes32 tmwfImplSalt = Salts.tokenMessengerWithFeesImpl();
        bytes32 tmwfProxySalt = Salts.tokenMessengerWithFeesProxy();

        fm = _deployFeeManager(fmImplSalt, fmProxySalt, tmwfProxySalt);

        deployTmwfScript = new DeployTokenMessengerWithFees();
        deployTmwfScript.runWithConfig(
            DeployTokenMessengerWithFeesConfig({
                factory: factory,
                tokenMessengerV2: mockTokenMessengerV2,
                feeManagerProxy: address(fm),
                owner: address(0),
                implSalt: tmwfImplSalt,
                proxySalt: tmwfProxySalt
            })
        );
        tmwf = deployTmwfScript.tokenMessengerWithFees();

        vm.prank(deployer);
        tmwf.acceptOwnership();
    }

    function _deployFeeManager(bytes32 implSalt, bytes32 proxySalt, bytes32 tmwfProxySalt)
        private
        returns (FeeManager)
    {
        address[] memory callers = new address[](1);
        callers[0] = factory.getAddress(tmwfProxySalt);
        DeployFeeManager fmScript = new DeployFeeManager();
        fmScript.runWithConfig(
            DeployFeeManagerConfig({
                factory: factory,
                implSalt: implSalt,
                proxySalt: proxySalt,
                owner: address(0),
                feeTaker: makeAddr("feeTaker"),
                usdc: makeAddr("usdcBlacklist"),
                callerAdmin: address(0),
                signerAdmin: address(0),
                trustedSigner: address(0),
                pauser: address(0),
                feeCollectionAdmin: address(0),
                feeCollectionAddress: payable(address(0)),
                allowedCallers: callers
            })
        );
        FeeManager deployedFm = fmScript.feeManager();

        vm.prank(deployer);
        deployedFm.acceptOwnership();

        return deployedFm;
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }

    function test_run_deploysNewImplAndUpdatesSlot() public {
        address oldImpl = _implOf(address(tmwf));
        UpgradeTmwfImplConfig memory config = _upgradeImplConfigForSalt("fee-orchestrator-v2");

        UpgradeTokenMessengerWithFees up = new UpgradeTokenMessengerWithFees();
        up.runWithConfig(config, address(tmwf));

        address newImpl = _implOf(address(tmwf));
        assertTrue(newImpl != oldImpl);
        assertEq(newImpl, up.implementation());
        assertEq(tmwf.owner(), deployer);
        assertEq(tmwf.feeManager(), address(fm));
        assertEq(tmwf.tokenMessenger(), mockTokenMessengerV2);
    }

    function test_deployImplementationOnly_doesNotChangeProxySlot() public {
        address oldImpl = _implOf(address(tmwf));
        UpgradeTmwfImplConfig memory config = _upgradeImplConfigForSalt("fee-orchestrator-v2");

        UpgradeTokenMessengerWithFees up = new UpgradeTokenMessengerWithFees();
        up.deployImplementationOnlyWithConfig(config);

        assertEq(_implOf(address(tmwf)), oldImpl);
        assertTrue(up.implementation() != address(0));
        assertTrue(up.implementation() != oldImpl);
    }

    function test_upgradeProxyOnly_updatesSlotToEnvImpl() public {
        UpgradeTmwfImplConfig memory config = _upgradeImplConfigForSalt("fee-orchestrator-v2");

        UpgradeTokenMessengerWithFees deployImpl = new UpgradeTokenMessengerWithFees();
        deployImpl.deployImplementationOnlyWithConfig(config);
        address newImpl = deployImpl.implementation();

        UpgradeTokenMessengerWithFees up = new UpgradeTokenMessengerWithFees();
        up.upgradeProxyOnlyWithConfig(address(tmwf), newImpl);

        assertEq(_implOf(address(tmwf)), newImpl);
    }

    function test_deployImplementationOnly_feeManagerImmutable_matchesFeeManagerProxy() public {
        UpgradeTmwfImplConfig memory config = _upgradeImplConfigForSalt("fee-orchestrator-v2");

        UpgradeTokenMessengerWithFees up = new UpgradeTokenMessengerWithFees();
        up.deployImplementationOnlyWithConfig(config);

        assertEq(TokenMessengerWithFees(up.implementation()).feeManager(), address(fm));
    }

    function test_deployImplementationOnly_feeManagerImmutable_respectsOverride() public {
        address altFeeManager = makeAddr("altFeeManagerProxy");
        UpgradeTmwfImplConfig memory config = _upgradeImplConfigForSaltWith("fee-orchestrator-v3", altFeeManager);

        UpgradeTokenMessengerWithFees up = new UpgradeTokenMessengerWithFees();
        up.deployImplementationOnlyWithConfig(config);

        assertEq(TokenMessengerWithFees(up.implementation()).feeManager(), altFeeManager);
    }

    function test_deployImplementationOnly_twiceSameSalt_reverts() public {
        UpgradeTmwfImplConfig memory config = _upgradeImplConfigForSalt("fee-orchestrator-v2");

        UpgradeTokenMessengerWithFees up = new UpgradeTokenMessengerWithFees();
        up.deployImplementationOnlyWithConfig(config);

        UpgradeTokenMessengerWithFees up2 = new UpgradeTokenMessengerWithFees();
        vm.expectRevert();
        up2.deployImplementationOnlyWithConfig(config);
    }
}
