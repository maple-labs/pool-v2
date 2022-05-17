// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, ILoanLike, IPoolLike } from "./interfaces/Interfaces.sol";

import { DateLinkedList } from "./LinkedList.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

/// @dev Lucas' implementation, uses cash + PO for FA.
contract TB_ST_02 is IInvestmentManagerLike, DateLinkedList {

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

        if (loan.nextPaymentDueDate() != 0) {
            // Add return variables for middle payments
            issuanceRate_        = IPoolLike(pool).issuanceRate();
            vestingPeriodFinish_ = rateDomainEnd;

            // Update investment state
            investments[investment_].lastPrincipal  = currentPrincipal;
        } else {
            // Remove invesment from sorted list
            remove(investment.indexInList);

            // Calculate new issuance rate
            uint256 currentIssuanceRate = IPoolLike(pool).issuanceRate();

            // TODO: Need to find a more robust way of calculating this
            //       Doing this temporarily to get tests to pass with imprecision
            issuanceRate_ = investment.loanIssuanceRate > currentIssuanceRate ? 0 : currentIssuanceRate - investment.loanIssuanceRate;

            // If no items in list, use block.timestamp for vestingPeriodFinish
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

        // Calculate relevant info for determining loan interest accrual rate
        uint256 principal       = loan.principal();
        uint256 paymentInterval = loan.paymentInterval();
        uint256 totalTerm       = paymentInterval * loan.paymentsRemaining();
        uint256 totalInterest   = principal * loan.interestRate() * totalTerm / 365 days / 1e18;
        uint256 endingTimestamp = block.timestamp + totalTerm;

        uint256 nodeId = insert(endingTimestamp, positionPreceeding(endingTimestamp));

        ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

        // Add new loan to investments mapping and array
        investments[investment_] = InvestmentVehicle({
            indexInList:        nodeId,
            lastPrincipal:      principal,
            loanIssuanceRate:   totalInterest * poolPrecision / totalTerm
        });

        investmentsArray.push(investment_);  // TODO: Do we need to have this array?

        // Calculate the new issuance Rate's domain
        rateDomainEnd = rateDomainEnd_ = list[head].date;  // Get earliest timestamp from linked list

        // Calculate new issuance rate based on newly funded loan's interest accrual rate
        uint256 domainLength          = rateDomainEnd_ - block.timestamp;
        uint256 currentDomainInterest = IPoolLike(pool).issuanceRate() * domainLength / poolPrecision;

        uint256 loanDomainInterest =
            endingTimestamp < rateDomainEnd ?
                totalInterest :
                totalInterest * domainLength / totalTerm;

        newIssuanceRate_ = (currentDomainInterest + loanDomainInterest) * poolPrecision / domainLength;
    }

}
