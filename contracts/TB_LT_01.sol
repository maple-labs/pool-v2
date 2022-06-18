// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, ILoanLike } from "./interfaces/Interfaces.sol";
import { IPoolV2 }                                       from "./interfaces/IPoolV2.sol";

import { DateLinkedList } from "./LinkedList.sol";
import { DefaultHandler } from "./DefaultHandler.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

/// @dev JG's implementation, uses Loan IRs to manage overall IR
contract TB_LT_01 is IInvestmentManagerLike, DefaultHandler {

    uint256 public immutable poolPrecision;

    uint256 public rateDomainEnd;

    address[] public investmentsArray;

    mapping (address => InvestmentVehicle) public investments;

    struct InvestmentVehicle {
        uint256 paymentInterval;
        uint256 lastPrincipal;
        uint256 loanIssuanceRate;
        uint256 nextInterest;
        uint256 paymentTarget;
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
        {
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
        }

        if (loan.nextPaymentDueDate() != 0) {
            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            uint256 newLoanRate = nextInterestAmount * poolPrecision / investment.paymentInterval;
            if (newLoanRate != investment.loanIssuanceRate) {
                // There's a difference on the interest paid per period
                uint256 oldIssuance = issuanceRate_;
                issuanceRate_ = issuanceRate_ + newLoanRate - investment.loanIssuanceRate;

                if (block.timestamp != investment.paymentTarget) {
                    uint256 diff = block.timestamp > investment.paymentTarget ? 
                        block.timestamp - investment.paymentTarget : 
                        investment.paymentTarget - block.timestamp;

                    uint256 added = 0;
                    uint256 removed = 0;

                    if (block.timestamp < investment.paymentTarget) {
                        // Early
                        added   = oldIssuance * diff / poolPrecision;
                        removed = issuanceRate_ * diff / poolPrecision; 
                    } else {
                        added = issuanceRate_ * diff / poolPrecision;
                        removed = oldIssuance * diff / poolPrecision;
                    }

                    freeAssets_ = freeAssets_ + added - removed;
                }
            }

            // Update investment state
            investments[investment_].loanIssuanceRate = newLoanRate;
            investments[investment_].lastPrincipal    = currentPrincipal;
            investments[investment_].nextInterest     = nextInterestAmount;
            investments[investment_].paymentTarget    = loan.nextPaymentDueDate(); 

        } else {
            uint256 oldIssuanceRate = issuanceRate_;
            // TODO: Need to find a more robust way of calculating this
            //       Doing this temporarily to get tests to pass with imprecision
            issuanceRate_ = investment.loanIssuanceRate > issuanceRate_ ? 0 : issuanceRate_ - investment.loanIssuanceRate;

            // If we're closing the loan before the end timestamp but in the last payment period, need to add discretely the remaining interest.
            // TODO: Will likely break with amortized loans and need to change to recalculate issuanceRate at each payment
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
                    freeAssets_ = freeAssets_ + added - removed;
                }
            }

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

        ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

        uint256 loanIssuanceRate = nextInterestAmount * poolPrecision / paymentInterval;

        // Add new loan to investments mapping and array
        investments[investment_] = InvestmentVehicle({
            paymentInterval:  paymentInterval,
            lastPrincipal:    principal,
            loanIssuanceRate: loanIssuanceRate,
            nextInterest:     nextInterestAmount,
            endDate:          endingTimestamp,
            paymentTarget:    loan.nextPaymentDueDate()
        });

        investmentsArray.push(investment_);  // TODO: Do we need to have this array?

        // Calculate the new issuance Rate's domain
        rateDomainEnd = rateDomainEnd_ = endingTimestamp > rateDomainEnd ? endingTimestamp : rateDomainEnd;

        newIssuanceRate_ = IPoolV2(pool).issuanceRate() + loanIssuanceRate;
    }

    function _earlyClosing(address investment_) internal view returns (bool) {
        InvestmentVehicle memory investment = investments[investment_];

        return block.timestamp <= investment.endDate - investment.paymentInterval;
    }

}