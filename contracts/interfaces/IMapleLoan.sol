// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface IMapleLoan {

    function borrower() external view returns (address borrower_);

    function claimableFunds() external view returns (uint256 claimableFunds_);

    function closingRate() external view returns (uint256 closingRate_);

    function collateral() external view returns (uint256 collateral_);

    function collateralAsset() external view returns (address collateralAsset_);

    function collateralRequired() external view returns (uint256 collateralRequired_);

    function drawableFunds() external view returns (uint256 drawableFunds_);

    function endingPrincipal() external view returns (uint256 endingPrincipal_);

    function fundsAsset() external view returns (address fundsAsset_);

    function gracePeriod() external view returns (uint256 gracePeriod_);

    function interestRate() external view returns (uint256 interestRate_);

    function lateFeeRate() external view returns (uint256 lateFeeRate_);

    function lateInterestPremium() external view returns (uint256 lateInterestPremium_);

    function lender() external view returns (address lender_);

    function nextPaymentDueDate() external view returns (uint256 nextPaymentDueDate_);

    function paymentInterval() external view returns (uint256 paymentInterval_);

    function paymentsRemaining() external view returns (uint256 paymentsRemaining_);

    function principal() external view returns (uint256 principal_);

    function principalRequested() external view returns (uint256 principalRequested_);

    function refinanceInterest() external view returns (uint256 refinanceInterest_);

    function claimFunds(uint256 amount_, address destination_) external;

    function fundLoan(address lender_, uint256 amount_) external returns (uint256 fundsLent_);

}
