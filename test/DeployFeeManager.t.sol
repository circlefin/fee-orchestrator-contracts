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
import {Roles} from "../src/constants/Roles.sol";
import {Create3Factory} from "../src/contracts/Create3Factory.sol";
import {FeeManager} from "../src/contracts/FeeManager.sol";
import {ANVIL_DEFAULT_PK} from "./TestConstants.sol";
import {Test} from "forge-std/Test.sol";

string constant DEFAULT_DEPLOYMENT_SALT = "fee-orchestrator-v1";

contract DeployFeeManagerTest is Test {
    DeployFeeManager internal script;
    FeeManager internal fm;
    Create3Factory internal factory;
    address internal deployer;
    address internal feeTakerAddr;
    address internal usdcBlacklistAddr;
    address internal predictedTmwfProxy;

    /// @dev Sets deployment salt env vars and immediately caches all salt-derived
    ///      values into a config struct. This eliminates the race window between
    ///      setting salts and reading them via Salts/Addresses libraries.
    function _configForSalt(string memory salt) internal returns (DeployFeeManagerConfig memory config) {
        vm.setEnv("FEE_MANAGER_PROXY_SALT", string.concat(salt, ".fm.proxy"));
        vm.setEnv("FEE_MANAGER_IMPLEMENTATION_SALT", string.concat(salt, ".fm.impl"));
        vm.setEnv("TOKEN_MESSENGER_WITH_FEES_PROXY_SALT", string.concat(salt, ".tmwf.proxy"));
        vm.setEnv("TOKEN_MESSENGER_WITH_FEES_IMPLEMENTATION_SALT", string.concat(salt, ".tmwf.impl"));

        bytes32 implSalt = Salts.feeManagerImpl();
        bytes32 proxySalt = Salts.feeManagerProxy();
        address tmwfProxy = factory.getAddress(Salts.tokenMessengerWithFeesProxy());

        address[] memory callers = new address[](1);
        callers[0] = tmwfProxy;
        config = DeployFeeManagerConfig({
            factory: factory,
            implSalt: implSalt,
            proxySalt: proxySalt,
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

    function setUp() public {
        deployer = vm.addr(ANVIL_DEFAULT_PK);
        feeTakerAddr = makeAddr("feeTaker");
        usdcBlacklistAddr = makeAddr("usdcBlacklist");

        vm.prank(deployer);
        factory = new Create3Factory(deployer);

        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(ANVIL_DEFAULT_PK));
        vm.setEnv("CREATE3_FACTORY_ADDRESS", vm.toString(address(factory)));

        DeployFeeManagerConfig memory config = _configForSalt(DEFAULT_DEPLOYMENT_SALT);
        predictedTmwfProxy = config.allowedCallers[0];

        script = new DeployFeeManager();
        script.runWithConfig(config);
        fm = script.feeManager();
    }

    function test_deploy_setsPendingOwnerToDeployer() public view {
        assertEq(fm.pendingOwner(), deployer);
    }

    function test_deploy_factoryRemainsOwnerUntilAcceptance() public view {
        assertEq(fm.owner(), address(factory));
    }

    function test_deploy_defaultAdminRoleStaysWithFactory() public view {
        assertTrue(fm.hasRole(fm.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertFalse(fm.hasRole(fm.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function test_deploy_doesNotRegisterDeployerAsAllowedCaller() public view {
        assertFalse(fm.hasRole(Roles.ALLOWED_CALLER_ROLE, deployer));
    }

    function test_deploy_setsFeeTaker() public view {
        assertEq(fm.feeTaker(), feeTakerAddr);
    }

    function test_deploy_setsUsdcBlacklist() public view {
        assertEq(fm.usdcBlacklist(), usdcBlacklistAddr);
    }

    function test_deploy_doesNotGrantCallerAdminWhenUnset() public view {
        assertFalse(fm.hasRole(Roles.CALLER_ADMIN_ROLE, deployer));
    }

    function test_deploy_doesNotGrantSignerAdminWhenUnset() public view {
        assertFalse(fm.hasRole(Roles.SIGNER_ADMIN_ROLE, deployer));
    }

    function test_deploy_doesNotGrantFeeCollectionAdminWhenUnset() public view {
        assertFalse(fm.hasRole(Roles.FEE_COLLECTION_ADMIN_ROLE, deployer));
        assertFalse(fm.hasRole(Roles.FEE_COLLECTION_ADMIN_ROLE, address(factory)));
    }

    function test_deploy_feeCollectionAddressUnsetByDefault() public view {
        assertEq(fm.feeCollectionAddress(), address(0));
    }

    function test_deploy_grantsFeeCollectionAdminWhenSet() public {
        address feeCollectionAdminAddr = makeAddr("explicitFeeCollectionAdmin");

        DeployFeeManagerConfig memory config = _configForSalt("test-explicit-fee-collection-admin");
        config.feeCollectionAdmin = feeCollectionAdminAddr;

        DeployFeeManager s = new DeployFeeManager();
        s.runWithConfig(config);
        FeeManager fm2 = s.feeManager();

        assertTrue(fm2.hasRole(Roles.FEE_COLLECTION_ADMIN_ROLE, feeCollectionAdminAddr));
        assertFalse(fm2.hasRole(Roles.FEE_COLLECTION_ADMIN_ROLE, address(factory)));
        assertEq(fm2.feeCollectionAddress(), address(0));
    }

    function test_deploy_setsFeeCollectionAddressWhenSet() public {
        address payable feeCollectionAddr = payable(makeAddr("explicitFeeCollectionAddress"));

        DeployFeeManagerConfig memory config = _configForSalt("test-explicit-fee-collection-address");
        config.feeCollectionAddress = feeCollectionAddr;

        DeployFeeManager s = new DeployFeeManager();
        s.runWithConfig(config);
        FeeManager fm2 = s.feeManager();

        assertEq(fm2.feeCollectionAddress(), feeCollectionAddr);
        // Temp FEE_COLLECTION_ADMIN_ROLE grant to the factory must be revoked at the
        // end of the multicall — factory should NOT retain the role post-deploy.
        assertFalse(fm2.hasRole(Roles.FEE_COLLECTION_ADMIN_ROLE, address(factory)));
        // The new 3-call sub-sequence must not disturb DEFAULT_ADMIN_ROLE state:
        // factory retains DEFAULT_ADMIN_ROLE (pending-owner pattern; transferred on acceptance);
        // deployer was never granted DEFAULT_ADMIN_ROLE. Validates the minimal-config callCount
        // calculation and that the new conditional block is correctly fenced from the
        // CALLER_ADMIN/SIGNER_ADMIN revoke + transferOwnership tail.
        assertTrue(fm2.hasRole(fm2.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertFalse(fm2.hasRole(fm2.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function test_deploy_setsFeeCollectionAddressWithExplicitAdmin() public {
        // Combined case: both a non-zero feeCollectionAdmin AND a non-zero
        // feeCollectionAddress. Verifies the admin keeps the role and the address
        // is set, with no factory residual role.
        address feeCollectionAdminAddr = makeAddr("explicitFeeCollectionAdminCombined");
        address payable feeCollectionAddr = payable(makeAddr("explicitFeeCollectionAddressCombined"));

        DeployFeeManagerConfig memory config = _configForSalt("test-fca-and-address");
        config.feeCollectionAdmin = feeCollectionAdminAddr;
        config.feeCollectionAddress = feeCollectionAddr;

        DeployFeeManager s = new DeployFeeManager();
        s.runWithConfig(config);
        FeeManager fm2 = s.feeManager();

        assertTrue(fm2.hasRole(Roles.FEE_COLLECTION_ADMIN_ROLE, feeCollectionAdminAddr));
        assertFalse(fm2.hasRole(Roles.FEE_COLLECTION_ADMIN_ROLE, address(factory)));
        assertEq(fm2.feeCollectionAddress(), feeCollectionAddr);
    }

    function test_deploy_grantsCallerAndSignerAdminWhenSet() public {
        address callerAdminAddr = makeAddr("explicitCallerAdmin");
        address signerAdminAddr = makeAddr("explicitSignerAdmin");

        DeployFeeManagerConfig memory config = _configForSalt("test-explicit-caller-signer-admin");
        config.callerAdmin = callerAdminAddr;
        config.signerAdmin = signerAdminAddr;

        DeployFeeManager s = new DeployFeeManager();
        s.runWithConfig(config);
        FeeManager fm2 = s.feeManager();

        assertTrue(fm2.hasRole(Roles.CALLER_ADMIN_ROLE, callerAdminAddr));
        assertTrue(fm2.hasRole(Roles.SIGNER_ADMIN_ROLE, signerAdminAddr));
        assertFalse(fm2.hasRole(Roles.CALLER_ADMIN_ROLE, deployer));
        assertFalse(fm2.hasRole(Roles.SIGNER_ADMIN_ROLE, deployer));
    }

    function test_deploy_withoutTrustedSigner_noSignerTrusted() public view {
        assertFalse(fm.isTrustedQuoteSigner(deployer));
    }

    function test_deploy_withTrustedSigner_registersSigner() public {
        address signer = makeAddr("trustedSigner");

        DeployFeeManagerConfig memory config = _configForSalt("test-with-trusted-signer");
        config.trustedSigner = signer;

        DeployFeeManager s = new DeployFeeManager();
        s.runWithConfig(config);
        FeeManager fm2 = s.feeManager();

        assertTrue(fm2.isTrustedQuoteSigner(signer));
    }

    function test_deploy_withDifferentSignerAdmin_grantsCorrectRole() public {
        address otherSignerAdmin = makeAddr("otherSignerAdmin");
        address signer = makeAddr("envTrustedSigner");

        DeployFeeManagerConfig memory config = _configForSalt("test-signer-admin-handoff");
        config.signerAdmin = otherSignerAdmin;
        config.trustedSigner = signer;

        DeployFeeManager s = new DeployFeeManager();
        s.runWithConfig(config);
        FeeManager fm2 = s.feeManager();

        assertTrue(fm2.hasRole(Roles.SIGNER_ADMIN_ROLE, otherSignerAdmin));
        assertEq(fm2.pendingOwner(), deployer);
        assertTrue(fm2.isTrustedQuoteSigner(signer));

        vm.prank(otherSignerAdmin);
        fm2.setTrustedQuoteSigner(signer, false);
        assertFalse(fm2.isTrustedQuoteSigner(signer));
    }

    function test_deploy_proxyPointsToImplementation() public view {
        assertTrue(script.implementation() != address(0));
        assertEq(address(fm), address(script.feeManager()));
        assertTrue(script.implementation() != address(fm));
    }

    function test_deploy_ownershipTransferInitiated() public view {
        assertEq(fm.owner(), address(factory));
        assertEq(fm.pendingOwner(), deployer);
    }

    function test_deploy_preRegistersPredictedTmwfProxyAsAllowedCaller() public view {
        assertTrue(fm.hasRole(Roles.ALLOWED_CALLER_ROLE, predictedTmwfProxy));
    }

    function test_deploy_defaultPauserIsNotGranted() public view {
        assertFalse(fm.hasRole(Roles.PAUSER_ROLE, deployer));
    }

    function test_deploy_factoryRetainsOnlyOwnerRole() public view {
        assertTrue(fm.hasRole(fm.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertFalse(fm.hasRole(Roles.CALLER_ADMIN_ROLE, address(factory)));
        assertFalse(fm.hasRole(Roles.SIGNER_ADMIN_ROLE, address(factory)));
        assertFalse(fm.hasRole(Roles.ALLOWED_CALLER_ROLE, address(factory)));
        assertFalse(fm.hasRole(Roles.PAUSER_ROLE, address(factory)));
        assertFalse(fm.hasRole(Roles.FEE_COLLECTION_ADMIN_ROLE, address(factory)));
    }

    function test_deploy_withPauser_grantsPauserRole() public {
        address pauserAddr = makeAddr("pauser");

        DeployFeeManagerConfig memory config = _configForSalt("test-with-pauser");
        config.pauser = pauserAddr;

        DeployFeeManager s = new DeployFeeManager();
        s.runWithConfig(config);
        FeeManager fm2 = s.feeManager();

        assertTrue(fm2.hasRole(Roles.PAUSER_ROLE, pauserAddr));
    }

    function test_deploy_multipleAllowedCallers_grantsAll() public {
        address extraCaller1 = makeAddr("extraCaller1");
        address extraCaller2 = makeAddr("extraCaller2");

        DeployFeeManagerConfig memory config = _configForSalt("test-multi-callers");
        address tmwfProxy = config.allowedCallers[0];

        address[] memory callers = new address[](3);
        callers[0] = tmwfProxy;
        callers[1] = extraCaller1;
        callers[2] = extraCaller2;
        config.allowedCallers = callers;

        DeployFeeManager s = new DeployFeeManager();
        s.runWithConfig(config);
        FeeManager fm2 = s.feeManager();

        assertTrue(fm2.hasRole(Roles.ALLOWED_CALLER_ROLE, tmwfProxy));
        assertTrue(fm2.hasRole(Roles.ALLOWED_CALLER_ROLE, extraCaller1));
        assertTrue(fm2.hasRole(Roles.ALLOWED_CALLER_ROLE, extraCaller2));
        assertFalse(fm2.hasRole(Roles.ALLOWED_CALLER_ROLE, deployer));
    }

    function test_deploy_withExplicitOwner_setsPendingOwner() public {
        address explicitOwner = makeAddr("explicitOwner");

        DeployFeeManagerConfig memory config = _configForSalt("test-explicit-owner");
        config.owner = explicitOwner;

        DeployFeeManager s = new DeployFeeManager();
        s.runWithConfig(config);
        FeeManager fm2 = s.feeManager();

        assertEq(fm2.pendingOwner(), explicitOwner);
        assertEq(fm2.owner(), address(factory));
    }

    function test_deploy_multipleAllowedCallers_withAllOptionalRoles() public {
        address callerAdminAddr = makeAddr("callerAdmin");
        address signerAdminAddr = makeAddr("signerAdmin");
        address signer = makeAddr("signer");
        address pauserAddr = makeAddr("pauser");
        address extraCaller = makeAddr("extraCaller");

        DeployFeeManagerConfig memory config = _configForSalt("test-multi-callers-full");
        address tmwfProxy = config.allowedCallers[0];

        address[] memory callers = new address[](2);
        callers[0] = tmwfProxy;
        callers[1] = extraCaller;
        config.callerAdmin = callerAdminAddr;
        config.signerAdmin = signerAdminAddr;
        config.trustedSigner = signer;
        config.pauser = pauserAddr;
        config.allowedCallers = callers;

        DeployFeeManager s = new DeployFeeManager();
        s.runWithConfig(config);
        FeeManager fm2 = s.feeManager();

        assertTrue(fm2.hasRole(Roles.CALLER_ADMIN_ROLE, callerAdminAddr));
        assertTrue(fm2.hasRole(Roles.SIGNER_ADMIN_ROLE, signerAdminAddr));
        assertTrue(fm2.isTrustedQuoteSigner(signer));
        assertTrue(fm2.hasRole(Roles.PAUSER_ROLE, pauserAddr));
        assertTrue(fm2.hasRole(Roles.ALLOWED_CALLER_ROLE, tmwfProxy));
        assertTrue(fm2.hasRole(Roles.ALLOWED_CALLER_ROLE, extraCaller));
    }
}
