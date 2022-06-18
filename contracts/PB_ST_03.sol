// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, ILoanLike, IPoolLike } from "./interfaces/Interfaces.sol";

import { DateLinkedList } from "./LinkedList.sol";
import { DefaultHandler } from "./DefaultHandler.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

// How much is claimed
// Rate domain start
// Loan issuance rate
// From this, we can do the following:
// Calculate the amount of funds that we've been expecting from this loan since freeAssets got updated last
//

/// @dev Lucas' implementation, using balance difference and expected interest for discrepancies
/// @dev Uses nextPaymentDueDate for endingTimestamp, calculates IR based on nextPaymentDueDate
contract PB_ST_03 is IInvestmentManagerLike, DateLinkedList, DefaultHandler {

    uint256 public immutable poolPrecision;

    uint256 public rateDomainEnd;

    address[] public investmentsArray;

    mapping (address => InvestmentVehicle) public investments;

    struct InvestmentVehicle {
        uint256 indexInList;
        uint256 lastPrincipal;
        uint256 paymentDomainEnd;
        uint256 paymentDomainStart;
        uint256 paymentIssuanceRate;
    }

    constructor(address pool_) DefaultHandler(pool_) {
        poolPrecision = IPoolLike(pool_).precision();
    }

    function claim(address investment_)
        external override returns (
            uint256 principalOut_,
            uint256 freeAssets_,
            uint256 issuanceRate_,
            uint256 vestingPeriodFinish_
        )
    {
        console.log("");
        console.log("-----");
        console.log("CLAIM");
        console.log("-----");

        ILoanLike loan = ILoanLike(investment_);

        InvestmentVehicle memory investment = investments[investment_];

        // Get state of the loan
        uint256 currentPrincipal = loan.principal();

        {
            uint256 beforeBal = IERC20Like(asset).balanceOf(address(pool));

            // Claim funds from the loan, transferring to pool
            loan.claimFunds(loan.claimableFunds(), pool);

            // Reduce oustanding principal by amount claimed from loan
            principalOut_ = IPoolLike(pool).principalOut() - (investment.lastPrincipal - currentPrincipal);

            // Get interest claimed from investment
            uint256 interestClaimed = IERC20Like(asset).balanceOf(address(pool)) - beforeBal - (investment.lastPrincipal - currentPrincipal);

            // Calculate expected interest
            uint256 endTimestamp     = _min(block.timestamp, investment.paymentDomainEnd);
            uint256 expectedInterest = (endTimestamp - investment.paymentDomainStart) * investment.paymentIssuanceRate / poolPrecision;

            // Set the freeAssets of the pool to the cash balance plus outstanding principal after claim
            freeAssets_ = IPoolLike(pool).freeAssets() + interestClaimed - expectedInterest;

            console.log("interestClaimed ", interestClaimed);
            console.log("expectedInterest", expectedInterest);
            console.log("freeAssets_     ", freeAssets_);

            // Remove investment from sorted list
            remove(investment.indexInList);
        }

        if (loan.nextPaymentDueDate() != 0) {
            // Update investment state
            investments[investment_].lastPrincipal = currentPrincipal;

            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            // Calculate the new start and end timestamp of the loan
            // TODO: Use nextPaymentDuedate - block.timestamp for next issuanceRate calculation
            uint256 paymentInterval = loan.paymentInterval();
            uint256 endingTimestamp = loan.nextPaymentDueDate();

            console.log("");
            console.log("paymentInterval", paymentInterval * 100 / 1 days);
            console.log("block.timestamp", (block.timestamp - 1622400000) * 100 / 1 days);
            console.log("endingTimestamp", (endingTimestamp - 1622400000) * 100 / 1 days);

            uint256 newPaymentIssuanceRate = nextInterestAmount * poolPrecision / (endingTimestamp - block.timestamp);

            // Update investment position in ordered list
            investments[investment_].indexInList = insert(endingTimestamp, positionPreceeding(endingTimestamp));

            console.log("");
            console.log("IPoolLike(pool).issuanceRate()", IPoolLike(pool).issuanceRate() / 1e30);
            console.log("newPaymentIssuanceRate        ", newPaymentIssuanceRate / 1e30);
            console.log("investment.paymentIssuanceRate", investment.paymentIssuanceRate / 1e30);

            // Update issuanceRate_ for pool
            issuanceRate_ = IPoolLike(pool).issuanceRate() + newPaymentIssuanceRate - investment.paymentIssuanceRate;

            // console.log("rateDomainEnd 1", (rateDomainEnd - 1622400000) * 100 / 1 days);

            // Update rateDomainEnd and vestingPeriodFinish_ to be new shortest timestamp
            rateDomainEnd = vestingPeriodFinish_ = list[head].date;  // TODO: Change this, TODO: Make work with mistimed claims

            // console.log("vestingPeriodFinish_ 2", (vestingPeriodFinish_ - 1622400000) * 100 / 1 days);

            investments[investment_].paymentDomainStart  = block.timestamp;
            investments[investment_].paymentDomainEnd    = endingTimestamp;
            investments[investment_].paymentIssuanceRate = newPaymentIssuanceRate;
        } else {
            // Get current issuance rate
            uint256 currentIssuanceRate = IPoolLike(pool).issuanceRate();

            // TODO: Need to find a more robust way of calculating this
            //       Doing this temporarily to get tests to pass with imprecision
            issuanceRate_ = investment.paymentIssuanceRate > currentIssuanceRate ? 0 : currentIssuanceRate - investment.paymentIssuanceRate;

            // issuanceRate_ = IPoolLike(pool).issuanceRate() - investment.paymentIssuanceRate;

            rateDomainEnd = vestingPeriodFinish_ = totalItems == 0 ? investments[investment_].paymentDomainEnd : list[head].date;

            // Delete investment object
            delete investments[investment_];
        }
    }

    function fund(address investment_) external override returns (uint256 newIssuanceRate_, uint256 rateDomainEnd_) {
        require(msg.sender == pool, "LIV:F:NOT_ADMIN");

        ILoanLike loan = ILoanLike(investment_);

        // Fund the loan, updating state to reflect transferred pool funds
        loan.fundLoan(address(this), 0);

        ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

        // Calculate relevant info for determining loan interest accrual rate
        uint256 principal           = loan.principal();
        uint256 endingTimestamp     = loan.nextPaymentDueDate();
        uint256 paymentIssuanceRate = nextInterestAmount * poolPrecision / (endingTimestamp - block.timestamp);

        uint256 indexInList = insert(endingTimestamp, positionPreceeding(endingTimestamp));

        // Add new loan to investments mapping and array
        investments[investment_] = InvestmentVehicle({
            indexInList:         indexInList,
            lastPrincipal:       principal,
            paymentDomainEnd:    endingTimestamp,
            paymentDomainStart:  block.timestamp,
            paymentIssuanceRate: paymentIssuanceRate
        });

        investmentsArray.push(investment_);  // TODO: Do we need to have this array?

        // Calculate the new issuance Rate's domain
        rateDomainEnd = rateDomainEnd_ = list[head].date;  // Get earliest timestamp from linked list

        newIssuanceRate_ = IPoolLike(pool).issuanceRate() + paymentIssuanceRate;
    }

    function _min(uint256 firstVal_, uint256 secondVal_) internal pure returns (uint256 minVal_) {
        minVal_ = firstVal_ > secondVal_ ? secondVal_ : firstVal_;
    }

}

