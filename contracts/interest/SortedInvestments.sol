// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

contract SortedInvestments {

    uint256 internal investmentCounter;

    uint256 investmentWithEarliestPaymentDueDate;

    mapping (uint256 => Investment) investments;

    // NOTE: This is here to satisfy suboptimal Pool interface
    mapping (address => uint256) investmentIdOf;

    struct Investment {
        uint256 previous;
        uint256 next;
        uint256 incomingNetInterest;
        uint256 startDate;
        uint256 paymentDueDate;
        uint256 coverFee;
        uint256 managementFee;
        address vehicle;
    }

    // TODO Passing Memory due to stack too deep error. Investigate if efficiency is lost here
    function _addInvestment(Investment memory investment_) internal returns (uint256 investmentId_) {
        investmentId_ = investmentIdOf[investment_.vehicle] = ++investmentCounter;

        uint256 current = 0;
        uint256 next = investmentWithEarliestPaymentDueDate;

        while (next != 0 && investment_.paymentDueDate >= investments[next].paymentDueDate) {
            current = next;
            next = investments[current].next;
        }

        if (current != 0) {
            investments[current].next = investmentId_;
        } else {
            investmentWithEarliestPaymentDueDate = investmentId_;
        }

        if (next != 0) {
            investments[next].previous = investmentId_;
        }

        investment_.next     = next;
        investment_.previous = current;

        investments[investmentId_] = investment_;
    }

    function _removeInvestment(uint256 investmentId_) internal returns (uint256 payment_, uint256 startDate_, uint256 paymentDueDate_) {
        Investment memory investment = investments[investmentId_];

        uint256 previous = investment.previous;
        uint256 next = investment.next;

        payment_ = investment.incomingNetInterest;
        startDate_ = investment.startDate;
        paymentDueDate_ = investment.paymentDueDate;

        if (investmentWithEarliestPaymentDueDate == investmentId_) {
            investmentWithEarliestPaymentDueDate = next;
        }

        if (next != 0) {
            investments[next].previous = previous;
        }

        if (previous != 0) {
            investments[previous].next = next;
        }

        delete investmentIdOf[investment.vehicle];
        delete investments[investmentId_];
    }

}
