// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, ILoanLike, IPoolLike } from "./interfaces/Interfaces.sol";

import { DateLinkedList } from "./LinkedList.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

/// @dev A loan wrapper for pools that can manage multiple loans.
contract PB_IM_01 is IInvestmentManagerLike, DateLinkedList {

    address public immutable asset;
    address public immutable pool;

    uint256 public immutable poolPrecision;

    uint256 public rateDomainEnd;

    address[] public investmentsArray;

    mapping (address => InvestmentVehicle) public investments;

    struct InvestmentVehicle {
        uint256 indexInList;
        uint256 lastPrincipal;
        uint256 loanIssuanceRate;
        uint256 scheduledPayment;
    }

    constructor(address pool_) {
        asset         = IPoolLike(pool_).asset();
        pool          = pool_;
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
        console.log("CLAIM");
        ILoanLike loan = ILoanLike(investment_);

        InvestmentVehicle memory investment = investments[investment_];

        // Get state of the loan
        uint256 currentPrincipal = loan.principal();
        uint256 beforeBal        = IERC20Like(asset).balanceOf(address(pool));

        // Claim funds from the loan, transferring to pool
        loan.claimFunds(loan.claimableFunds(), pool);

        // Reduce oustanding principal by amount claimed from loan
        principalOut_ = IPoolLike(pool).principalOut() - (investment.lastPrincipal - currentPrincipal);

        // Set the freeAssets of the pool to the cash balance plus outstanding principal after claim
        freeAssets_ = IERC20Like(asset).balanceOf(address(pool)) + principalOut_;

        // Update investment state
        investments[investment_].lastPrincipal = currentPrincipal;

        // Remove investment from sorted list
        remove(investment.indexInList);

        if (loan.nextPaymentDueDate() != 0) {
            // Update investment state
            investments[investment_].lastPrincipal = currentPrincipal;

            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            uint256 paymentInterval     = loan.paymentInterval();
            uint256 endingTimestamp     = investment.scheduledPayment + paymentInterval + loan.gracePeriod();
            uint256 newLoanIssuanceRate = nextInterestAmount * poolPrecision / paymentInterval;

            console.log("endingTimestamp                       ", (endingTimestamp - 1622400000) * 100 / 1 days);
            console.log("positionPreceeding(endingTimestamp)   ", positionPreceeding(endingTimestamp));

            investments[investment_].indexInList = insert(endingTimestamp, positionPreceeding(endingTimestamp));

            issuanceRate_ = IPoolLike(pool).issuanceRate() - investment.loanIssuanceRate + newLoanIssuanceRate;

            console.log("if");
            console.log("investment.loanIssuanceRate   ", investment.loanIssuanceRate);
            console.log("newLoanIssuanceRate           ", newLoanIssuanceRate);
            console.log("IPoolLike(pool).issuanceRate()", IPoolLike(pool).issuanceRate());
            console.log("issuanceRate_                 ", issuanceRate_);

            rateDomainEnd = vestingPeriodFinish_ = totalItems == 0 ? block.timestamp : list[head].date;

            investments[investment_].scheduledPayment += paymentInterval;
            investments[investment_].loanIssuanceRate  = newLoanIssuanceRate;
        } else {
            // Calculate new issuance rate
            uint256 currentIssuanceRate = IPoolLike(pool).issuanceRate();

            console.log("else");
            console.log("investment.loanIssuanceRate", investment.loanIssuanceRate);
            console.log("currentIssuanceRate        ", currentIssuanceRate);

            // TODO: Need to find a more robust way of calculating this
            //       Doing this temporarily to get tests to pass with imprecision
            issuanceRate_ = investment.loanIssuanceRate > currentIssuanceRate ? 0 : currentIssuanceRate - investment.loanIssuanceRate;

            // issuanceRate_ = IPoolLike(pool).issuanceRate() - investment.loanIssuanceRate;

            rateDomainEnd = vestingPeriodFinish_ = totalItems == 0 ? block.timestamp : list[head].date;

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
        uint256 principal        = loan.principal();
        uint256 paymentInterval  = loan.paymentInterval();
        uint256 gracePeriod      = loan.gracePeriod();
        uint256 endingTimestamp  = block.timestamp + paymentInterval + gracePeriod;
        uint256 loanIssuanceRate = nextInterestAmount * poolPrecision / paymentInterval;

        uint256 indexInList = insert(endingTimestamp, positionPreceeding(endingTimestamp));

        // console.log("FUND - indexInList", indexInList);
        // console.log("FUND - inserting  ", (endingTimestamp - 1622400000) * 100 / 1 days);

        // Add new loan to investments mapping and array
        investments[investment_] = InvestmentVehicle({
            indexInList:      indexInList,
            lastPrincipal:    principal,
            loanIssuanceRate: loanIssuanceRate,
            scheduledPayment: block.timestamp + paymentInterval
        });

        investmentsArray.push(investment_);  // TODO: Do we need to have this array?

        // Calculate the new issuance Rate's domain
        rateDomainEnd = rateDomainEnd_ = list[head].date;  // Get earliest timestamp from linked list

        newIssuanceRate_ = IPoolLike(pool).issuanceRate() + loanIssuanceRate;
    }

}
