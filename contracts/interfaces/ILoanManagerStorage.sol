// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface ILoanManagerStorage {

    function fundsAsset() external view returns (address fundsAsset_);

    function pool() external view returns (address pool_);

    function poolManager() external view returns (address poolManager_);

    function accountedInterest() external view returns (uint256 accountedInterest_);

    function domainStart() external view returns (uint256 domainStart_);

    function domainEnd() external view returns (uint256 domainEnd_);

    function issuanceRate() external view returns (uint256 issuanceRate_);

    function loanCounter() external view returns (uint256 loanCounter_);

    function loanWithEarliestPaymentDueDate() external view returns (uint256 loanWithEarliestPaymentDueDate_);

    function principalOut() external view returns (uint256 principalOut_);

    function unrealizedLosses() external view returns (uint256 unrealizedLosses_);

    function loanIdOf(address loan_) external view returns (uint256 loanId_);

    function allowedSlippageFor(address collateralAsset_) external view returns (uint256 allowedSlippage_);

    function minRatioFor(address collateralAsset_) external view returns (uint256 minRatio_);

    function liquidationInfo(address loan_) external view returns (
        uint256 principal,
        uint256 interest,
        uint256 platformFees,
        address liquidator,
        bool    triggeredByGovernor
    );

    function loans(uint256 loanId_) external view returns (
        uint256 previous,
        uint256 next,
        uint256 incomingNetInterest,
        uint256 refinanceInterest,
        uint256 issuanceRate,
        uint256 startDate,
        uint256 paymentDueDate,
        uint256 platformManagementFeeRate,
        uint256 delegateManagementFeeRate
    );

}
