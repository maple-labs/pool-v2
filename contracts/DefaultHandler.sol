// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, ILoanLike } from "./interfaces/Interfaces.sol";
import { IPoolV2 }               from "./interfaces/IPoolV2.sol";

import { Liquidator } from "../modules/liquidator/contracts/Liquidator.sol";

import { ERC20Helper } from "../modules/revenue-distribution-token/modules/erc20-helper/src/ERC20Helper.sol";

/// @dev Contract that handles defaults and collateral liquidations. To be inherited by investment managers
contract DefaultHandler {

    // TODO ACL
    address public asset;
    address public pool;

    mapping (address => Details) public details; // Mapping from address -> liquidation details

    struct Details {
        uint256 principalToCover;
        address liquidator;
    }

    constructor(address pool_) {
        asset  = IPoolV2(pool_).asset();
        pool   = pool_;
    }

    /*************************/
    /*** Default Functions ***/
    /*************************/

    function finishLiquidation(address loan_) external {
        require(!_isLiquidationActive(loan_), "DH:FL:LIQ_STILL_ACTIVE");

        uint256 recoveredFunds = IERC20Like(asset).balanceOf(address(this));
        uint256 principalToCover = details[loan_].principalToCover;

        // TODO decide on how the pool will handle the accounting
        require(ERC20Helper.transfer(asset, pool, recoveredFunds));

        uint256 remainingPrincipal = 0;

        IPoolV2(pool).decreaseUnrealizedLosses(recoveredFunds > principalToCover ? principalToCover : recoveredFunds);

        if (recoveredFunds >= principalToCover) {
            details[loan_].principalToCover = recoveredFunds;
        } else {
            remainingPrincipal = principalToCover - recoveredFunds;
        }

        if (remainingPrincipal > 0) {
            // TODO: Trigger PCM
        }
    }

    /// @dev Trigger Default on a loan
    function triggerDefault(address loan_) external {
        // TODO: The loan is not able to handle defaults while there are claimable funds
        ILoanLike loan = ILoanLike(loan_);

        require(
            (loan.claimableFunds() == uint256(0)),
            "DH:TD:NEED_TO_CLAIM"
        );

        uint256 principal = loan.principal();

        (uint256 collateralAssetAmount, uint256 fundsAssetAmount) = loan.repossess(address(this));

        address collateralAsset = loan.collateralAsset();
        address liquidator;

        if (collateralAsset != asset && collateralAssetAmount != uint256(0)) {
            liquidator = address(new Liquidator(address(this), collateralAsset, asset, address(this), address(this)));
            require(
                ERC20Helper.transfer(
                    collateralAsset,
                    liquidator,
                    collateralAssetAmount
                ),
                "DL:TD:TRANSFER"
            );
        }

        IPoolV2(pool).increaseUnrealizedLosses(principal);
        details[loan_] = Details(principal, liquidator);

        // TODO: Temove issuance rate from loan, but it's dependant on how the IM does that
    }

    /****************************/
    /*** Auctioneer Functions ***/
    /****************************/

    function getExpectedAmount(uint256 swapAmount_) external view returns (uint256 returnAmount_) {
        // NOTE: Mock value for now as we don't have oracles reference yet
        returnAmount_ = swapAmount_ * 1e6;
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _isLiquidationActive(address loan_) internal view returns (bool isActive_) {
        address liquidatorAddress = details[loan_].liquidator;

        return (liquidatorAddress != address(0)) && (IERC20Like(ILoanLike(loan_).collateralAsset()).balanceOf(liquidatorAddress) != uint256(0));
    }

}
