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

import {IUSDCBlacklist} from "../../src/interfaces/IUSDCBlacklist.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Burn-token stand-in that rejects `transferFrom` when `from` is blocked on the same
///      blacklist oracle `FeeManager.isDenylisted` uses (defense-in-depth for the EOA path).
contract MockUsdcAwareBurnToken is ERC20 {
    IUSDCBlacklist public immutable USDC_BLACKLIST;

    constructor(address usdcBlacklist_) ERC20("MockUSDC", "USDC") {
        USDC_BLACKLIST = IUSDCBlacklist(usdcBlacklist_);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (USDC_BLACKLIST.isBlacklisted(from)) {
            revert("MockUsdcAwareBurnToken: blacklisted sender");
        }
        return super.transferFrom(from, to, amount);
    }
}
