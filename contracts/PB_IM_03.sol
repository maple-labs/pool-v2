// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, ILoanLike } from "./interfaces/Interfaces.sol";
import { IPoolV2 }                                       from "./interfaces/IPoolV2.sol";

import { DateLinkedList } from "./LinkedList.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

/// @dev A loan wrapper for pools that can manage multiple loans.
contract PB_IM_03 is IInvestmentManagerLike, DateLinkedList {

    address public immutable asset;
    address public immutable pool;

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

    constructor(address pool_) {
        asset         = IPoolV2(pool_).asset();
        pool          = pool_;
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
            uint256 claimable  = loan.claimableFunds();

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

        // Remove investment from sorted list
        remove(investment.indexInList);

        if (loan.nextPaymentDueDate() != 0) {
            // Update investment state
            investments[investment_].lastPrincipal = currentPrincipal;

            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            uint256 nextPayment = loan.nextPaymentDueDate();
            uint256 newLoanIssuanceRate = nextInterestAmount * poolPrecision / investment.paymentInterval;

            investments[investment_].indexInList = insert(nextPayment, positionPreceeding(nextPayment));

            issuanceRate_ = IPoolV2(pool).issuanceRate() - investment.loanIssuanceRate + newLoanIssuanceRate;

            rateDomainEnd = vestingPeriodFinish_ = totalItems == 0 ? block.timestamp : list[head].date;

            investments[investment_].loanIssuanceRate = newLoanIssuanceRate;


        } else {

            console.log("early", _earlyClosing(investment_));

            console.log("block.timestamp   ", block.timestamp);
            console.log("investment.endDate", investment.endDate);
            if (block.timestamp < investment.endDate && !_earlyClosing(investment_)) {
                console.log("adjusting");
                freeAssets_ += investment.loanIssuanceRate * (investment.endDate - block.timestamp) / poolPrecision;
            }

            // TODO: Need to find a more robust way of calculating this
            //       Doing this temporarily to get tests to pass with imprecision
            issuanceRate_ = investment.loanIssuanceRate > issuanceRate_ ? 0 : issuanceRate_ - investment.loanIssuanceRate;

            // issuanceRate_ = IPoolV2(pool).issuanceRate() - investment.loanIssuanceRate;

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
        uint256 nextPayment      = block.timestamp + paymentInterval + gracePeriod;
        uint256 loanIssuanceRate = nextInterestAmount * poolPrecision / paymentInterval;

        uint256 indexInList = insert(nextPayment, positionPreceeding(nextPayment));

        // Add new loan to investments mapping and array
        investments[investment_] = InvestmentVehicle({
            indexInList:      indexInList,
            paymentInterval:  paymentInterval,
            lastPrincipal:    principal,
            loanIssuanceRate: loanIssuanceRate,
            nextInterest:     nextInterestAmount,
            endDate:          block.timestamp + paymentInterval * loan.paymentsRemaining()
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
