// SDPX-License-Identifier: AGLP-3.0-only
pragma solidity ^0.8.7;

import { Address, console } from "../../modules/contract-test-utils/contracts/test.sol";

import { LoanManager } from "../../contracts/LoanManager.sol";

contract LoanManagerHarness is LoanManager {

    function addPaymentToList(uint48 paymentDueDate_) external returns (uint256 paymentId_) {
        paymentId_ = _addPaymentToList(paymentDueDate_);
    }

    function removePaymentFromList(uint256 paymentId_) external {
        _removePaymentFromList(paymentId_);
    }

    function __setUnrealizedLosses(uint256 unrealizedLosses_) external {
        unrealizedLosses = _uint128(unrealizedLosses_);
    }

    function __queueNextPayment(address loan_, uint256 startDate_, uint256 nextPaymentDueDate_) external returns (uint256 newRate_) {
        newRate_ = _queueNextPayment(loan_, startDate_, nextPaymentDueDate_);
    }

}
