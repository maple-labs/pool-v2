// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { console } from "../modules/contract-test-utils/contracts/log.sol";

import { ERC20Helper } from "../modules/erc20-helper/src/ERC20Helper.sol";
import { Liquidator }  from "../modules/liquidations/contracts/Liquidator.sol";

import { IERC20Like, ILoanLike, IPoolLike, IPoolCoverManagerLike } from "./interfaces/Interfaces.sol";

/// @dev Contract that handles defaults and collateral liquidations. To be inherited by investment managers
contract DefaultHandler {

    // TODO ACL
    address public fundsAsset;
    address public pool;

    mapping (address => LiquidationInfo) public liquidationInfo; // Mapping from address -> liquidation details

    struct LiquidationInfo {
        uint256 principalToCover;
        address liquidator;
    }

    constructor(address pool_) {
        fundsAsset = IPoolLike(pool_).asset();
        pool  = pool_;
    }

    /*************************/
    /*** Default Functions ***/
    /*************************/

    // TODO: Investigate transferring funds directly into pool from liquidator instead of accumulating in IM
    function finishCollateralLiquidation(address loan_) external returns (uint256 decreasedUnrealizedLosses_, uint256 remainingLosses_) {
        require(!_isLiquidationActive(loan_), "DH:FL:LIQ_STILL_ACTIVE");

        uint256 recoveredFunds   = IERC20Like(fundsAsset).balanceOf(address(this));
        uint256 principalToCover = liquidationInfo[loan_].principalToCover;

        // TODO decide on how the pool will handle the accounting
        require(ERC20Helper.transfer(fundsAsset, pool, recoveredFunds));

        decreasedUnrealizedLosses_ = recoveredFunds > principalToCover ? principalToCover : recoveredFunds;
        remainingLosses_           = recoveredFunds > principalToCover ? 0                : principalToCover - recoveredFunds;

        delete liquidationInfo[loan_];
    }

    /// @dev Trigger Default on a loan
    function triggerCollateralLiquidation(address loan_) external returns (uint256 increasedUnrealizedLosses_) {
        // TODO: Add ACL

        // TODO: The loan is not able to handle defaults while there are claimable funds
        ILoanLike loan = ILoanLike(loan_);

        require(loan.claimableFunds() == uint256(0), "DH:TCL:NEED_TO_CLAIM");

        uint256 principal = loan.principal();

        (uint256 collateralAssetAmount, uint256 fundsAssetAmount) = loan.repossess(address(this));

        address collateralAsset = loan.collateralAsset();
        address liquidator;

        if (collateralAsset != fundsAsset && collateralAssetAmount != uint256(0)) {
            liquidator = address(new Liquidator(address(this), collateralAsset, fundsAsset, address(this), address(this), address(this)));

            require(ERC20Helper.transfer(collateralAsset,   liquidator, collateralAssetAmount), "DL:TD:CA_TRANSFER");
            require(ERC20Helper.transfer(loan.fundsAsset(), liquidator, fundsAssetAmount),      "DL:TD:FA_TRANSFER");
        }

        increasedUnrealizedLosses_ = principal;

        liquidationInfo[loan_] = LiquidationInfo(principal, liquidator);

        // TODO: Remove issuance rate from loan, but it's dependant on how the IM does that
        // TODO: Incorporate real auctioneer and globals, currently using address(this) for all 3 liquidator actors.
    }

    /****************************/
    /*** Auctioneer Functions ***/
    /****************************/

    function getExpectedAmount(uint256 swapAmount_) external view returns (uint256 returnAmount_) {
        // NOTE: Mock value for now as we don't have oracles reference yet
        returnAmount_ = swapAmount_ * 1e6;
    }

    /******************************/
    /*** Mock Globals Functions ***/
    /******************************/

    // TODO: Remove
    function protocolPaused() external view returns (bool protocolPaused_) {
        return false;
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _isLiquidationActive(address loan_) internal view returns (bool isActive_) {
        address liquidatorAddress = liquidationInfo[loan_].liquidator;

        return (liquidatorAddress != address(0)) && (IERC20Like(ILoanLike(loan_).collateralAsset()).balanceOf(liquidatorAddress) != uint256(0));
    }

}
