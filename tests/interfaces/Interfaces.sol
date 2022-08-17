// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { LoanManager } from "../../contracts/LoanManager.sol";

interface ILoanManagerLike {

    function loans(uint256 loanId_) external view returns (LoanManager.LoanInfo memory loanInfo_);  // Used to avoid stack too deep issues.

    function liquidationInfo(address loan_) external view returns (LoanManager.LiquidationInfo memory liquidationInfo_);  // Used to avoid stack too deep issues.

    function triggerDefaultWarningInfo(uint256 loanId_) external view returns (LoanManager.TriggerDefaultWarningInfo memory triggerDefaultWarningInfo_);

}