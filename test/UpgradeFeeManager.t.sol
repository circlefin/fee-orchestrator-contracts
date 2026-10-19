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
import {Salts} from "../script/deploy/Salts.sol";
import {UpgradeFeeManager, UpgradeFeeManagerImplConfig} from "../script/deploy/UpgradeFeeManager.s.sol";
import {Create3Factory} from "../src/contracts/Create3Factory.sol";
import {FeeManager} from "../src/contracts/FeeManager.sol";
import {ANVIL_DEFAULT_PK} from "./TestConstants.sol";
import {Test} from "forge-std/Test.sol";

string constant UPGRADE_FM_DEFAULT_SALT = "fee-orchestrator-v1";

contract UpgradeFeeManagerTest is Test {
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal deployer;
    address internal feeTakerAddr;
    address internal usdcAddr;
    Create3Factory internal factory;
    DeployFeeManager internal deployScript;
    FeeManager internal fm;

    /// @dev Sets the impl salt env var and immediately caches it into a config struct.
    function _upgradeImplConfigForSalt(string memory implSalt) internal returns (UpgradeFeeManagerImplConfig memory) {
        vm.setEnv("FEE_MANAGER_IMPLEMENTATION_SALT", string.concat(implSalt, ".fm.impl"));
        return UpgradeFeeManagerImplConfig({
            factory: factory, implSalt: Salts.feeManagerImpl(), feeTaker: feeTakerAddr, usdc: usdcAddr
        });
    }

    function setUp() public {
        deployer = vm.addr(ANVIL_DEFAULT_PK);
        feeTakerAddr = makeAddr("feeTaker");
        usdcAddr = makeAddr("usdcBlacklist");

        vm.prank(deployer);
        factory = new Create3Factory(deployer);

        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(ANVIL_DEFAULT_PK));
        vm.setEnv("CREATE3_FACTORY_ADDRESS", vm.toString(address(factory)));
        vm.setEnv("FEE_MANAGER_PROXY_SALT", string.concat(UPGRADE_FM_DEFAULT_SALT, ".fm.proxy"));
        vm.setEnv("FEE_MANAGER_IMPLEMENTATION_SALT", string.concat(UPGRADE_FM_DEFAULT_SALT, ".fm.impl"));
        vm.setEnv("TOKEN_MESSENGER_WITH_FEES_PROXY_SALT", string.concat(UPGRADE_FM_DEFAULT_SALT, ".tmwf.proxy"));
        vm.setEnv("TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT", string.concat(UPGRADE_FM_DEFAULT_SALT, ".tmwf.impl"));

        // Cache salt-derived values before deploying.
        bytes32 fmImplSalt = Salts.feeManagerImpl();
        bytes32 fmProxySalt = Salts.feeManagerProxy();
        address predictedTmwfProxy = factory.getAddress(Salts.tokenMessengerWithFeesProxy());

        address[] memory callers = new address[](1);
        callers[0] = predictedTmwfProxy;

        deployScript = new DeployFeeManager();
        deployScript.runWithConfig(
            DeployFeeManagerConfig({
                factory: factory,
                implSalt: fmImplSalt,
                proxySalt: fmProxySalt,
                owner: address(0),
                feeTaker: feeTakerAddr,
                usdc: usdcAddr,
                callerAdmin: address(0),
                signerAdmin: address(0),
                trustedSigner: address(0),
                pauser: address(0),
                feeCollectionAdmin: address(0),
                feeCollectionAddress: payable(address(0)),
                allowedCallers: callers
            })
        );
        fm = deployScript.feeManager();

        vm.prank(deployer);
        fm.acceptOwnership();
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }

    function test_run_deploysNewImplAndUpdatesSlot() public {
        address oldImpl = _implOf(address(fm));
        UpgradeFeeManagerImplConfig memory config = _upgradeImplConfigForSalt("fee-orchestrator-v2");

        UpgradeFeeManager up = new UpgradeFeeManager();
        up.runWithConfig(config, address(fm));

        address newImpl = _implOf(address(fm));
        assertTrue(newImpl != oldImpl);
        assertEq(newImpl, up.implementation());
        assertEq(fm.owner(), deployer);
        assertEq(fm.feeTaker(), feeTakerAddr);
    }

    function test_deployImplementationOnly_doesNotChangeProxySlot() public {
        address oldImpl = _implOf(address(fm));
        UpgradeFeeManagerImplConfig memory config = _upgradeImplConfigForSalt("fee-orchestrator-v2");

        UpgradeFeeManager up = new UpgradeFeeManager();
        up.deployImplementationOnlyWithConfig(config);

        assertEq(_implOf(address(fm)), oldImpl);
        assertTrue(up.implementation() != address(0));
        assertTrue(up.implementation() != oldImpl);
    }

    function test_upgradeProxyOnly_updatesSlotToEnvImpl() public {
        UpgradeFeeManagerImplConfig memory config = _upgradeImplConfigForSalt("fee-orchestrator-v2");

        UpgradeFeeManager deployImpl = new UpgradeFeeManager();
        deployImpl.deployImplementationOnlyWithConfig(config);
        address newImpl = deployImpl.implementation();

        UpgradeFeeManager up = new UpgradeFeeManager();
        up.upgradeProxyOnlyWithConfig(address(fm), newImpl);

        assertEq(_implOf(address(fm)), newImpl);
    }

    function test_deployImplementationOnly_twiceSameSalt_reverts() public {
        UpgradeFeeManagerImplConfig memory config = _upgradeImplConfigForSalt("fee-orchestrator-v2");

        UpgradeFeeManager up = new UpgradeFeeManager();
        up.deployImplementationOnlyWithConfig(config);

        UpgradeFeeManager up2 = new UpgradeFeeManager();
        vm.expectRevert();
        up2.deployImplementationOnlyWithConfig(config);
    }
}
