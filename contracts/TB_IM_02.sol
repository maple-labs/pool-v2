// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, ILoanLike } from "./interfaces/Interfaces.sol";
import { IPoolV2 }                                       from "./interfaces/IPoolV2.sol";

import { DateLinkedList } from "./LinkedList.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

/// @dev A loan wrapper for pools that can manage multiple loans.
contract TB_IM_02 is IInvestmentManagerLike {

    address public immutable asset;
    address public immutable pool;

    uint256 public immutable poolPrecision;

    uint256 public rateDomainEnd;

    address[] public investmentsArray;

    mapping (address => InvestmentVehicle) public investments;

    struct InvestmentVehicle {
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
            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            // Update investment state
            investments[investment_].lastPrincipal = currentPrincipal;
            investments[investment_].nextInterest  = nextInterestAmount;

        } else {
            // If we're closing the loan before the end timestamp but in the last payment period, need to add discretely the remaining interest. 
            // TODO: Will likely break with amortized loans and need to change to recalculate issuanceRate at each payment
            if (block.timestamp < investment.endDate && !_earlyClosing(investment_)) {
                freeAssets_ += investment.loanIssuanceRate * (investment.endDate - block.timestamp) / poolPrecision;
            }

            // TODO: Need to find a more robust way of calculating this
            //       Doing this temporarily to get tests to pass with imprecision   
            issuanceRate_ = investment.loanIssuanceRate > issuanceRate_ ? 0 : issuanceRate_ - investment.loanIssuanceRate;
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

        uint256 loanIssuanceRate = totalInterest * poolPrecision / totalTerm;

        // Add new loan to investments mapping and array
        investments[investment_] = InvestmentVehicle({
            paymentInterval:  paymentInterval,
            lastPrincipal:    principal,
            loanIssuanceRate: loanIssuanceRate,
            nextInterest:     nextInterestAmount,
            endDate:          endingTimestamp
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
