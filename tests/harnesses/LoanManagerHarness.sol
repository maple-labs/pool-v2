// SDPX-License-Identifier: AGLP-3.0-only
pragma solidity ^0.8.7;

import { LoanManager } from "../../contracts/LoanManager.sol";

contract LoanManagerHarness is LoanManager {

    function addLoan(LoanInfo memory loan_) external returns (uint256 loanId_) {
        loanId_ = _addLoan(loan_);
    }

    function deleteLoan(address vehicle_) external returns (uint256 loanAccruedInterest_, uint256 paymentDueDate_, uint256 issuanceRate_) {
        ( loanAccruedInterest_, paymentDueDate_, issuanceRate_ ) = _deleteLoan(vehicle_);
    }

    function loan(uint256 loanId_) external view returns (LoanInfo memory loan_) {
        loan_ = loans[loanId_];
    }

}
