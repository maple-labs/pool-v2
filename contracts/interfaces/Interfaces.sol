// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface IERC20Like {

    function approve(address spender_, uint256 amount_) external;

    function transfer(address destination_, uint256 amount_) external;
    
}

interface IInvestmentManagerLike {

    function claim(address investment_) external returns (uint256 principal_, uint256 interestAdded_, uint256 interestReturned_, uint256 periodEnd__);

    function closeInvestment(address investment_) external returns (uint256 expectedPrincipal_, uint256 principal_, uint256 interest_);
    
    function expectedInterest(address investment_) external view returns (uint256 interest_);
    
    function fund(address investment_) external returns (uint256 interestAdded_, uint256 periodEnd_);

}

interface IInvestmentVehicleLike {

    function claim() external returns (uint256 principal_, uint256 interestAdded_, uint256 interestReturned_, uint256 periodEnd__);

    function close() external returns (uint256 expectedPrincipal_, uint256 principal_, uint256 interest_);
    
    function expectedInterest() external view returns (uint256 interest_);
    
    function fund() external returns (uint256 interestAdded_, uint256 periodEnd_);

}

interface IPoolCoverManagerLike {

    function distributeAssets() external returns (address[] memory recipients_, uint256[] memory assets_);

}

interface ILoanLike {

    function claimableFunds() external view returns (uint256 claimableFunds_);

    function claimFunds(uint256 amount_, address destination_) external; 

    function fundLoan(address lender_, uint256 amount_) external returns (uint256 fundsLent_);

    function getNextPaymentBreakdown() external view returns (uint256 principal_, uint256 interest_);

    function nextPaymentDueDate() external view returns (uint256 nextPaymentDueDate_);

    function principal() external view returns (uint256 principal_);

    function principalRequested() external view returns (uint256 principalRequested_);
    
}
