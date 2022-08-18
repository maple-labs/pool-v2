// SDPX-License-Identifier: AGLP-3.0-only
pragma solidity ^0.8.7;

import { Address, console } from "../../modules/contract-test-utils/contracts/test.sol";

import { LoanManager } from "../../contracts/LoanManager.sol";

contract LoanManagerHarness is LoanManager {

    function addLoanToList(address loanAddress_, LoanInfo memory loanInfo_) external {
        uint256 loanId_ = loanIdOf[loanAddress_] = ++loanCounter;

        _addLoanToList(loanId_, loanInfo_);
    }

    function recognizeLoanPayment(address loan_) external returns (uint256 issuanceRate_) {
        issuanceRate_ = _recognizeLoanPayment(loan_);
    }

    function loan(uint256 loanId_) external view returns (LoanInfo memory loanInfo_) {
        loanInfo_ = loans[loanId_];
    }

    function __setUnrealizedLosses(uint256 unrealizedLosses_) external {
        unrealizedLosses = unrealizedLosses_;
    }

    function __queueNextLoanPayment(address loan_, uint256 startDate_, uint256 nextPaymentDueDate_) external returns (uint256 newRate_) {
        newRate_ = _queueNextLoanPayment(loan_, startDate_, nextPaymentDueDate_);
    }

}
