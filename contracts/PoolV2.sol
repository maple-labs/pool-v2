// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.7;

import { IPoolV2 } from "./interfaces/IPoolV2.sol";

import { ERC20, RevenueDistributionToken } from "../modules/revenue-distribution-token/contracts/RevenueDistributionToken.sol";

contract PoolV2 is IPoolV2, RevenueDistributionToken {

    constructor(string memory name_, string memory symbol_, address owner_, address asset_, uint256 precision_)
        RevenueDistributionToken(name_, symbol_, owner_, asset_, precision_) { }

    
 }
