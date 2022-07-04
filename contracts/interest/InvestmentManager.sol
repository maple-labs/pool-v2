// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { console } from "../../modules/contract-test-utils/contracts/log.sol";

import { IERC20Like, ILoanLike, IPoolCoverManagerLike, IPoolLike } from "../interfaces/Interfaces.sol";

import { DefaultHandler }    from "./DefaultHandler.sol";
import { SortedInvestments } from "./SortedInvestments.sol";

// TODO: Rename to LoanManager, all instances of `investment` to `loan`
contract InvestmentManager is SortedInvestments, DefaultHandler {

    uint256 constant PRECISION = 1e30;

    address public poolCoverManager;  // TODO: Remove PCM from storage and query PM for fees
    address public poolManager;

    uint256 public accountedInterest;
    uint256 public issuanceRate;
    uint256 public lastUpdated;
    uint256 public principalOut;
    uint256 public vestingPeriodFinish;

    mapping(address => uint256) public principalOf;

    constructor(address pool_, address poolManager_, address poolCoverManager_) DefaultHandler(pool_) {
        poolManager      = poolManager_;
        poolCoverManager = poolCoverManager_;
    }

    /**************************/
    /*** External Functions ***/
    /**************************/

    // TODO: Test situation where multiple payment intervals pass between claims of a single loan

    function claim(address investment_) external {
        // Update initial accounting
        // TODO: Think we need to update issuanceRate here
        accountedInterest = _getAccruedInterest();
        lastUpdated       = block.timestamp;

        // Claim investment and get principal amd interest portion of claimable.
        ( uint256 principalRecovered, uint256 interestPortion ) = _claimInvestment(investment_);

        principalOut -= principalRecovered;

        // Remove investment from sorted list and get relevant previous parameters.
        ( uint256 previousStartDate, uint256 previousPaymentDueDate, uint256 previousRate ) = _removeInvestment(investment_);

        // Get relevant next parameters.
        ( , uint256 nextInterest, uint256 nextPaymentDueDate ) = _getNextPaymentOf(investment_);

        // The next rate will be over the course of the remaining time, or the payment interval, whichever is longer.
        // In other words, if the previous payment was early, then the next payment will start accruing from now,
        // but if the previous payment was late, then we should have been accruing the next payment from the moment the previous payment was due.
        uint256 nextStartDate = _minimumOf(block.timestamp, previousPaymentDueDate);

        uint256 newRate = 0;

        // If there is a next payment for this investment.
        if (nextPaymentDueDate != 0) {
            // Add the investment to the sorted list, making sure to take the effective start date (and not the current block timestamp).
            _addInvestment(nextInterest, nextStartDate, nextPaymentDueDate, investment_);

            newRate = (nextInterest * PRECISION) / (nextPaymentDueDate - nextStartDate);
        }

        // If there even is a new rate, and the next payment should have already been accruing, then accrue it.
        if (newRate != 0 && block.timestamp > previousPaymentDueDate) {
            accountedInterest += (block.timestamp - previousPaymentDueDate) * newRate / PRECISION;
        }

        // The new vesting period finish is the maximum of the current earliest, if it does not exist set to current timestamp to end vesting.
        // TODO: Should we make this paymentDueDate + gracePeriod?
        vestingPeriodFinish = _maximumOf(investments[investmentWithEarliestPaymentDueDate].paymentDueDate, block.timestamp);

        // Update the vesting state an then set the new issuance rate take into account the cessation of the previous rate
        // and the commencement of the new rate for this investment.
        issuanceRate = issuanceRate + newRate - previousRate;

        // If the amount of interest claimed is greater than the amount accounted for, set to zero.
        // Discrepancy between accounted and actual is always captured by balance change in the pool from the claimed interest.
        accountedInterest = interestPortion > accountedInterest ? 0 : accountedInterest - interestPortion;
    }

    function fund(address investment_) external {
        require(msg.sender == poolManager, "IM:F:NOT_ADMIN");

        ILoanLike(investment_).fundLoan(address(this), 0);

        uint256 principal = principalOf[investment_] = ILoanLike(investment_).principal();

        ( , uint256 nextInterest, uint256 nextPaymentDueDate ) = _getNextPaymentOf(investment_);

        _addInvestment(nextInterest, block.timestamp, nextPaymentDueDate, investment_);

        uint256 issuanceRateIncrease = (nextInterest * PRECISION) / (nextPaymentDueDate - block.timestamp);

        principalOut        += principal;
        accountedInterest    = _getAccruedInterest();
        issuanceRate        += issuanceRateIncrease;
        vestingPeriodFinish  = investments[investmentWithEarliestPaymentDueDate].paymentDueDate;
        lastUpdated          = block.timestamp;
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _claimInvestment(address investment_) internal returns (uint256 principalPortion_, uint256 interestPortion_) {
        ILoanLike loan           = ILoanLike(investment_);
        principalPortion_        = principalOf[investment_] - loan.principal();
        interestPortion_         = loan.claimableFunds() - principalPortion_;
        principalOf[investment_] = loan.principal();

        // TODO: Query PM for information about disbursment.
        // Route a portion of the interest to the pool cover manager (if there is any pool cover).
        if (poolCoverManager != address(0)) {
            uint256 coverPortion = interestPortion_ / 5;  // 20%
            interestPortion_    -= coverPortion;          // 80% (+dust)

            loan.claimFunds(coverPortion, poolCoverManager);
            IPoolCoverManagerLike(poolCoverManager).allocateLiquidity();
        }

        loan.claimFunds(loan.claimableFunds(), pool);
    }

    function _removeInvestment(address investment_) internal returns (uint256 previousStartDate_, uint256 previousPaymentDueDate_, uint256 previousRate_) {
        uint256 previousInterest;

        ( previousInterest, previousStartDate_, previousPaymentDueDate_ ) = _removeInvestment(investmentIdOf[investment_]);  // TODO: Change name

        previousRate_ = (previousInterest * PRECISION) / (previousPaymentDueDate_ - previousStartDate_);
    }

    function _minimumVestingPeriodFinishOf(uint256 a_, uint256 b_) internal view returns (uint256 realMinimum_) {
        if (a_ == 0 && b_ == 0) return block.timestamp;

        if (a_ == 0) return b_;

        if (b_ == 0) return a_;

        return _minimumOf(a_, b_);
    }

    function _getNextPaymentOf(address loan_) internal view returns (uint256 nextPrincipal_, uint256 nextInterest_, uint256 nextPaymentDueDate_) {
        nextPaymentDueDate_ = ILoanLike(loan_).nextPaymentDueDate();
        ( nextPrincipal_, nextInterest_ ) = nextPaymentDueDate_ == 0
            ? (0, 0)
            : ILoanLike(loan_).getNextPaymentBreakdown();

        // TODO: Query PM for information about disbursment
        // Reduce interest by 20% to account for interest being routed to pool cover manager.
        if (address(poolCoverManager) != address(0)) {
            nextInterest_ -= nextInterest_ / 5;
        }
    }

    function _maximumOf(uint256 a_, uint256 b_) internal pure returns (uint256 maximum_) {
        return a_ > b_ ? a_ : b_;
    }

    function _minimumOf(uint256 a_, uint256 b_) internal pure returns (uint256 minimum_) {
        return a_ < b_ ? a_ : b_;
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function _getAccruedInterest() internal view returns (uint256 accruedInterest_) {
        uint256 issuanceRate_ = issuanceRate;

        if (issuanceRate_ == 0) return accountedInterest;

        uint256 vestingPeriodFinish_ = vestingPeriodFinish;
        uint256 lastUpdated_         = lastUpdated;

        uint256 vestingTimePassed = block.timestamp > vestingPeriodFinish_
            ? vestingPeriodFinish_ - lastUpdated_
            : block.timestamp - lastUpdated_;

        accruedInterest_ = issuanceRate_ * vestingTimePassed / PRECISION;
    }

    // TODO: Add bool flag for optionally including unrecognized losses.
    function assetsUnderManagement() public view virtual returns (uint256 assetsUnderManagement_) {
        // TODO: Figure out better approach for this
        uint256 accruedInterest = lastUpdated == block.timestamp ? 0 : _getAccruedInterest();

        return principalOut + accountedInterest + accruedInterest;
    }

    // function finishCoverLiquidation(address poolCoverReserve_) external {
    //     IPoolCoverManagerLike(poolCoverManager).finishLiquidation
    // }

}
