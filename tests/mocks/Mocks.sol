// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { MockERC20 } from "../../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { IAuctioneerLike, ILiquidatorLike } from "../../contracts/interfaces/Interfaces.sol";

contract MockLiquidationStrategy {

    address auctioneer;

    constructor(address auctioneer_) {
        auctioneer = auctioneer_;
    }

    function flashBorrowLiquidation(address lender_, uint256 swapAmount_, address collateralAsset_, address fundsAsset_) external {
        uint256 repaymentAmount = IAuctioneerLike(auctioneer).getExpectedAmount(swapAmount_);

        MockERC20(fundsAsset_).approve(lender_, repaymentAmount);

        ILiquidatorLike(lender_).liquidatePortion(
            swapAmount_,
            type(uint256).max,
            abi.encodeWithSelector(this.swap.selector, collateralAsset_, fundsAsset_, swapAmount_, repaymentAmount)
        );
    }

    function swap(address collateralAsset_, address fundsAsset_, uint256 swapAmount_, uint256 repaymentAmount_) external {
        MockERC20(fundsAsset_).mint(address(this), repaymentAmount_);
        MockERC20(collateralAsset_).burn(address(this), swapAmount_);
    }

}

contract MockLoan {

    address public fundsAsset;
    address public collateralAsset;

    uint256 public collateral;
    uint256 public principal;

    constructor(address fundsAsset_, address collateralAsset_, uint256 principalRequested_, uint256 collateralRequired_) {
        fundsAsset      = fundsAsset_;
        collateralAsset = collateralAsset_;
        principal       = principalRequested_;
        collateral      = collateralRequired_;
    }

    function claimableFunds() external view returns(uint256 claimable_) {
        claimable_ = 0;
    }

    function drawdownFunds(uint256 amount_, address destination_) external {
        MockERC20(fundsAsset).transfer(destination_, amount_);
    }

    function fundLoan(address , uint256 ) external returns (uint256 fundsLent_){
        // Do nothing
    }

    function getNextPaymentBreakdown() external returns (uint256 principal_, uint256 interest_) { }

    function nextPaymentDueDate() external view returns (uint256 nextPaymentDueDate_) {
        return block.timestamp + 30 days;
    }

    function paymentInterval() external view returns (uint256 paymentInterval_) {
        return 30 days;
    }

    function repossess(address destination_) external returns (uint256 collateralRepossessed_, uint256 fundsRepossessed_) {
        collateralRepossessed_ = collateral;
        MockERC20(collateralAsset).transfer(destination_, collateral);
    }

}

contract MockPoolCoverManager {

    function triggerCoverLiquidation(uint256 remainingLosses_) external { }

}
