// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, ILoanLike, IPoolLike } from "./interfaces/Interfaces.sol";

import { DateLinkedList } from "./LinkedList.sol";
import { DefaultHandler } from "./DefaultHandler.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

/// @dev Lucas' implementation, using balance and oustanding interest for FA
/// @dev Uses term end date for endingTimestamp, calculates IR based on balance + principalOut + other loans
contract TB_ST_04 is IInvestmentManagerLike, DateLinkedList, DefaultHandler {
    
    uint256 public immutable poolPrecision;

    uint256 public rateDomainEnd;

    uint256 public lastClaim;  // TODO: Probably can use lastUpdated when moving RDT accounting into here

    address[] public investmentsArray;

    mapping (address => InvestmentVehicle) public investments;

    struct InvestmentVehicle {
        uint256 indexInList;
        uint256 lastPrincipal;
        uint256 loanIssuanceRate;
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
        ILoanLike loan = ILoanLike(investment_);

        InvestmentVehicle memory investment = investments[investment_];

        // Get state of the loan
        uint256 currentPrincipal = loan.principal();

        // Claim funds from the loan, transferring to pool
        loan.claimFunds(loan.claimableFunds(), pool);

        // Reduce oustanding principal by amount claimed from loan
        principalOut_ = IPoolLike(pool).principalOut() - (investment.lastPrincipal - currentPrincipal);

        // NOTE: This model can only use its own issuance rate, not the pools, temporary implementation
        uint256 outstandingInterest = (IPoolLike(pool).issuanceRate() - investment.loanIssuanceRate) * (block.timestamp - lastClaim) / poolPrecision;

        // Set the freeAssets of the pool to the cash balance plus outstanding principal after claim, plus current outstanding interest
        freeAssets_ = IERC20Like(asset).balanceOf(address(pool)) + principalOut_ + outstandingInterest;

        if (loan.nextPaymentDueDate() != 0) {
            // Add return variables for middle payments
            issuanceRate_        = IPoolLike(pool).issuanceRate();
            vestingPeriodFinish_ = rateDomainEnd;

            // Update investment state
            investments[investment_].lastPrincipal = currentPrincipal;
        } else {
            // Remove invesment from sorted list
            remove(investment.indexInList);

            // Calculate new issuance rate
            issuanceRate_ = IPoolLike(pool).issuanceRate() - investment.loanIssuanceRate;

            // If no items in list, use block.timestamp for vestingPeriodFinish
            rateDomainEnd = vestingPeriodFinish_ = totalItems == 0 ? block.timestamp : list[head].date;

            // Delete investment object
            delete investments[investment_];
        }

        lastClaim = block.timestamp;
    }

    function fund(address investment_) external override returns (uint256 newIssuanceRate_, uint256 rateDomainEnd_) {
        require(msg.sender == pool, "LIV:F:NOT_ADMIN");

        ILoanLike loan = ILoanLike(investment_);

        // Fund the loan, updating state to reflect transferred pool funds
        loan.fundLoan(address(this), 0);

        // Calculate relevant info for determining loan interest accrual rate
        uint256 principal        = loan.principal();
        uint256 totalTerm        = loan.paymentInterval() * loan.paymentsRemaining();
        uint256 totalInterest    = principal * loan.interestRate() * totalTerm / 365 days / 1e18;
        uint256 endingTimestamp  = block.timestamp + totalTerm;
        uint256 loanIssuanceRate = totalInterest * poolPrecision / totalTerm;

        // Add new loan to investments mapping and array
        investments[investment_] = InvestmentVehicle({
            indexInList:        insert(endingTimestamp, positionPreceeding(endingTimestamp)),
            lastPrincipal:      principal,
            loanIssuanceRate:   loanIssuanceRate
        });

        investmentsArray.push(investment_);  // TODO: Do we need to have this array?

        // Calculate the new issuance Rate's domain
        rateDomainEnd = rateDomainEnd_ = list[head].date;  // Get earliest timestamp from linked list

        newIssuanceRate_ = IPoolLike(pool).issuanceRate() + loanIssuanceRate;

        lastClaim = block.timestamp;
    }

}
