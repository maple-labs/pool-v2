// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, ILoanLike } from "./interfaces/Interfaces.sol";
import { IPoolV2 }                                       from "./interfaces/IPoolV2.sol";

import { DateLinkedList } from "./LinkedList.sol";
import { DefaultHandler } from "./DefaultHandler.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

/// @dev JG's implementation, uses expected interest and uses shortest timestamp.
contract TB_ST_03 is IInvestmentManagerLike, DateLinkedList, DefaultHandler {

    uint256 public immutable poolPrecision;

    uint256 public rateDomainEnd;

    address[] public investmentsArray;

    mapping (address => InvestmentVehicle) public investments;

    struct InvestmentVehicle {
        uint256 indexInList;
        uint256 paymentInterval;
        uint256 lastPrincipal;
        uint256 loanIssuanceRate;
        uint256 nextInterest;
        uint256 endDate;
    }

    constructor(address pool_) DefaultHandler(pool_) {
        poolPrecision = IPoolV2(pool_).precision();
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
        uint256 claimable        = loan.claimableFunds();

        // Claim funds from the loan, transferring to pool
        loan.claimFunds(claimable, pool);

        uint256 principalPaid     = investment.lastPrincipal - currentPrincipal;
        uint256 interestReceived  = claimable - principalPaid;

        // Setting return values
        principalOut_        = IPoolV2(pool).principalOut() - principalPaid;
        freeAssets_          = IPoolV2(pool).freeAssets();
        issuanceRate_        = IPoolV2(pool).issuanceRate();
        vestingPeriodFinish_ = rateDomainEnd;

        // TODO this calculation will need to change for amortized loans.
        if (interestReceived > investment.nextInterest) {
            freeAssets_ += interestReceived - investment.nextInterest;
        }

        if (loan.nextPaymentDueDate() != 0) {
            console.log("More");
            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            // Update investment state
            investments[investment_].lastPrincipal = currentPrincipal;
            investments[investment_].nextInterest  = nextInterestAmount;

        } else {

            console.log("early", _earlyClosing(investment_));
            // Remove invesment from sorted list
            remove(investment.indexInList);

            uint256 oldIssuanceRate = issuanceRate_;

            // TODO: Need to find a more robust way of calculating this
            //       Doing this temporarily to get tests to pass with imprecision
            issuanceRate_ = investment.loanIssuanceRate > issuanceRate_ ? 0 : issuanceRate_ - investment.loanIssuanceRate;

            // if (block.timestamp < investment.endDate && !_earlyClosing(investment_)) {
            //     console.log("adjusting");
            //     freeAssets_ += investment.loanIssuanceRate * (investment.endDate - block.timestamp) / poolPrecision;
            // }

            console.log("oldIssuanceRate", oldIssuanceRate);
            console.log("issuanceRate_  ", issuanceRate_);
            console.log("rate domain end", rateDomainEnd);
            console.log("investment. end", investment.endDate);
            console.log("timestampo     ", block.timestamp);

            // If no items in list, use block.timestamp for vestingPeriodFinish
            rateDomainEnd = vestingPeriodFinish_ = totalItems == 0 ? block.timestamp : list[head].date;

            if (block.timestamp != investment.endDate && !_earlyClosing(investment_)) {

                if (block.timestamp < investment.endDate) {
                    // Adjust free assets by the time passed(or that will pass) using the wrong issuance rate
                    uint256 added   = oldIssuanceRate * (investment.endDate - block.timestamp) / poolPrecision;
                    uint256 removed = issuanceRate_ * (investment.endDate - block.timestamp) / poolPrecision;
                    freeAssets_ = freeAssets_ + added - removed;

                } else if (block.timestamp > investment.endDate ) {
                    // Adjust free assets by the time passed(or that will pass) using the wrong issuance rate
                    uint256 removed = oldIssuanceRate * (block.timestamp - investment.endDate) / poolPrecision;
                    uint256 added   = (issuanceRate_ == 0 ? investment.loanIssuanceRate : issuanceRate_) * (block.timestamp - investment.endDate) / poolPrecision;
                    console.log("added  ", added);
                    console.log("removed", removed);
                    freeAssets_ = freeAssets_ + added - removed;
                }
            }

            console.log("rate domain end", rateDomainEnd);

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

        uint256 indexInList = insert(endingTimestamp, positionPreceeding(endingTimestamp));

        ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

        uint256 loanIssuanceRate = totalInterest * poolPrecision / totalTerm;

        // Add new loan to investments mapping and array
        investments[investment_] = InvestmentVehicle({
            indexInList:      indexInList,
            paymentInterval:  paymentInterval,
            lastPrincipal:    principal,
            loanIssuanceRate: loanIssuanceRate,
            nextInterest:     nextInterestAmount,
            endDate:          endingTimestamp
        });

        investmentsArray.push(investment_);  // TODO: Do we need to have this array?

        // Calculate the new issuance Rate's domain
        rateDomainEnd = rateDomainEnd_ = list[head].date;  // Get earliest timestamp from linked list

        newIssuanceRate_ = IPoolV2(pool).issuanceRate() + loanIssuanceRate;
    }

    function _earlyClosing(address investment_) internal view returns (bool) {
        InvestmentVehicle memory investment = investments[investment_];

        return block.timestamp <= investment.endDate - investment.paymentInterval;
    }

}
