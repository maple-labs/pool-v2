// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface IAuctioneerLike {

    function getExpectedAmount(uint256 swapAmount_) external view returns (uint256 expectedAmount_);

}

interface IERC20Like {

    function approve(address spender_, uint256 amount_) external;

    function balanceOf(address account_) external view returns (uint256 balance_);

    function transfer(address destination_, uint256 amount_) external;

}

interface IInvestmentManagerLike {

    function claim(address investment_) external returns (
        uint256 principalOut_,
        uint256 freeAssets_,
        uint256 issuanceRate_,
        uint256 vestingPeriodFinish_
    );

    function fund(address investment_) external returns (uint256 newIssuanceRate_, uint256 rateDomainEnd_);

}

interface IInvestmentVehicleLike {

    function claim() external returns (uint256 principal_, uint256 interestAdded_, uint256 interestReturned_, uint256 periodEnd_);

    function close() external returns (uint256 expectedPrincipal_, uint256 principal_, uint256 interest_);

    function expectedInterest() external view returns (uint256 interest_);

    function fund() external returns (uint256 interestAdded_, uint256 periodEnd_);

}

interface ILiquidatorLike {

    function liquidatePortion(uint256 swapAmount_, uint256 maxReturnAmount_, bytes calldata data_) external;

}

interface ILoanLike {

    function claimableFunds() external view returns (uint256 claimableFunds_);

    function claimFunds(uint256 amount_, address destination_) external;

    function collateralAsset() external view returns(address asset_);

    function fundLoan(address lender_, uint256 amount_) external returns (uint256 fundsLent_);

    function getNextPaymentBreakdown() external view returns (uint256 principal_, uint256 interest_);

    function gracePeriod() external view returns (uint256 gracePeriod_);

    function interestRate() external view returns (uint256 interestRate_);

    function nextPaymentDueDate() external view returns (uint256 nextPaymentDueDate_);

    function paymentInterval() external view returns (uint256 paymentInterval_);

    function paymentsRemaining() external view returns (uint256 paymentsRemaining_);

    function principal() external view returns (uint256 principal_);

    function principalRequested() external view returns (uint256 principalRequested_);

    function repossess(address destination_) external returns (uint256 collateralRepossessed_, uint256 fundsRepossessed_);

}

interface IPoolCoverManagerLike {

    function allocateLiquidity() external;

}

interface IPoolLike {

    function asset() external view returns (address asset_);

    function freeAssets() external view returns (uint256 freeAssets_);

    function issuanceRate() external view returns (uint256 issuanceRate_);

    function precision() external view returns (uint256 precision_);

    function principalOut() external view returns (uint256 principalOut_);

    function totalAssets() external view returns (uint256 totalAssets_);

}
