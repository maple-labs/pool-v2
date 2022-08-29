// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface ILoanManagerStorage {

    function accountedInterest() external view returns (uint112 accountedInterest_);

    function allowedSlippageFor(address collateralAsset_) external view returns (uint256 allowedSlippage_);

    function domainEnd() external view returns (uint48 domainEnd_);

    function domainStart() external view returns (uint48 domainStart_);

    function fundsAsset() external view returns (address fundsAsset_);

    function issuanceRate() external view returns (uint256 issuanceRate_);

    function liquidationInfo(address loan_) external view returns (
        bool    triggeredByGovernor,
        uint128 principal,
        uint120 interest,
        uint256 lateInterest,  // TODO: Optimize
        uint96  platformFees,
        address liquidator
    );

    function minRatioFor(address collateralAsset_) external view returns (uint256 minRatio_);

    function paymentCounter() external view returns (uint24 paymentCounter_);

    function paymentIdOf(address loan_) external view returns (uint24 paymentId_);

    function payments(uint256 paymentId_) external view returns (
        uint24  platformManagementFeeRate,
        uint24  delegateManagementFeeRate,
        uint48  startDate,
        uint48  paymentDueDate,
        uint128 incomingNetInterest,
        uint128 refinanceInterest,
        uint256 issuanceRate
    );

    function paymentWithEarliestDueDate() external view returns (uint24 paymentWithEarliestDueDate_);

    function pool() external view returns (address pool_);

    function poolManager() external view returns (address poolManager_);

    function principalOut() external view returns (uint128 principalOut_);

    function sortedPayments(uint256 paymentId_) external view returns (
        uint24 previous,
        uint24 next,
        uint48 paymentDueDate
    );

    function unrealizedLosses() external view returns (uint128 unrealizedLosses_);

}
