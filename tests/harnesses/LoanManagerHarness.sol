// SDPX-License-Identifier: AGLP-3.0-only
pragma solidity ^0.8.7;

import { LoanManager } from "../../contracts/interest/LoanManager.sol";

contract LoanManagerHarness is LoanManager {

    constructor(address pool_, address poolManager_) LoanManager(pool_, poolManager_) { }

    function addLoan(LoanInfo memory loan_) external returns (uint256 loanId_) {
        loanId_ = _addLoan(loan_);
    }

    function removeLoan(address vehicle_) external returns (uint256 payment_, uint256 startDate_, uint256 paymentDueDate_, uint256 issuanceRate_) {
        ( payment_, startDate_, paymentDueDate_, issuanceRate_ ) = _removeLoan(vehicle_);
    }

    function loan(uint256 loanId_) external view returns (LoanInfo memory loan_) {
        loan_ = loans[loanId_];
    }

}
