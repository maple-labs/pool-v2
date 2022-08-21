// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface ILoanManagerStructs {

    struct LiquidationInfo {
        uint256 principal;
        uint256 interest;
        uint256 platformFees;
        address liquidator;
        bool    triggeredByGovernor;
    }

    struct LoanInfo {
        uint256 previous;
        uint256 next;
        uint256 incomingNetInterest;
        uint256 refinanceInterest;
        uint256 issuanceRate;
        uint256 startDate;
        uint256 paymentDueDate;
        uint256 platformManagementFeeRate;
        uint256 delegateManagementFeeRate;
    }

    function liquidationInfo(address loan_) external view returns (LiquidationInfo memory liquidationInfo_);

    function loans(uint256 loanId_) external view returns (LoanInfo memory loanInfo_);

}
