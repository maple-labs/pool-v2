// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IHybridPool }        from "../interfaces/IHybridPool.sol";
import { IInvestmentManager } from "../interfaces/IInvestmentManager.sol";
import { IMapleLoan }         from "../interfaces/IMapleLoan.sol";

contract PaymentBasedInvestmentManager is IInvestmentManager {

    IHybridPool internal immutable POOL;

    constructor(address pool_) {
        POOL = IHybridPool(pool_);
    }

    function updateAccounting(address investment_, uint256 claimedAssets_) external override { }

    function totalAssets() external view override returns (uint256 totalAssets_) { }

}
