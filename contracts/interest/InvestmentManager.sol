// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { console } from "../../modules/contract-test-utils/contracts/log.sol";

import { IERC20Like, ILoanLike, IPoolLike, IPoolManagerLike } from "../interfaces/Interfaces.sol";

import { DefaultHandler }    from "./DefaultHandler.sol";
import { SortedInvestments } from "./SortedInvestments.sol";

// TODO: Rename to LoanManager, all instances of `investment` to `loan`
contract InvestmentManager is SortedInvestments, DefaultHandler {

    uint256 constant PRECISION  = 1e30;
    uint256 constant SCALED_ONE = 1e18;

    address public poolManager;

    uint256 public accountedInterest;
    uint256 public issuanceRate;
    uint256 public lastUpdated;
    uint256 public principalOut;
    uint256 public vestingPeriodFinish;

    mapping(address => uint256) public principalOf;

    constructor(address pool_, address poolManager_) DefaultHandler(pool_) {
        poolManager      = poolManager_;
    }

    /**************************/
    /*** External Functions ***/
    /**************************/

    // TODO: Test situation where multiple payment intervals pass between claims of a single loan

    function claim(address investmentAddress_) external returns (uint256 coverPortion_, uint256 managementPortion_) {
        // Update initial accounting
        // TODO: Think we need to update issuanceRate here
        accountedInterest = _getAccruedInterest();
        lastUpdated       = block.timestamp;

        uint256 principalPaid   = 0;
        uint256 netInterestPaid = 0;

        // Claim investment and get principal and interest portion of claimable.
        ( principalPaid, netInterestPaid, coverPortion_, managementPortion_ ) = _claimInvestment(investmentAddress_);

        principalOut -= principalPaid;

        // Remove investment from sorted list and get relevant previous parameters.
        ( , uint256 previousPaymentDueDate, uint256 previousRate ) = _removeInvestment(investmentAddress_);

        // Get relevant next parameters.
        ( , uint256 incomingNetInterest, uint256 nextPaymentDueDate ) = _getNextPaymentOf(investmentAddress_);

        uint256 newRate = 0;

        // If there is a next payment for this investment.
        if (nextPaymentDueDate != 0) {

            // The next rate will be over the course of the remaining time, or the payment interval, whichever is longer.
            // In other words, if the previous payment was early, then the next payment will start accruing from now,
            // but if the previous payment was late, then we should have been accruing the next payment from the moment the previous payment was due.
            uint256 nextStartDate = _minimumOf(block.timestamp, previousPaymentDueDate);

            ( uint256 coverFee_, uint256 managementFee_ ) = IPoolManagerLike(poolManager).getFees();

            // Add the investment to the sorted list, making sure to take the effective start date (and not the current block timestamp).
            _addInvestment(Investment({
                // Previous and next will be overriden within _addInvestment function
                previous:            0,
                next:                0,
                incomingNetInterest: incomingNetInterest,
                startDate:           nextStartDate,
                paymentDueDate:      nextPaymentDueDate,
                coverFee:            coverFee_,
                managementFee:       managementFee_,
                vehicle:             investmentAddress_
            }));

            newRate = (incomingNetInterest * PRECISION) / (nextPaymentDueDate - nextStartDate);
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
        accountedInterest = netInterestPaid > accountedInterest ? 0 : accountedInterest - netInterestPaid;
    }

    function fund(address investmentAddress_) external {
        require(msg.sender == poolManager, "IM:F:NOT_ADMIN");

        ILoanLike(investmentAddress_).fundLoan(address(this), 0);

        uint256 principal = principalOf[investmentAddress_] = ILoanLike(investmentAddress_).principal();

        ( , uint256 nextInterest, uint256 nextPaymentDueDate ) = _getNextPaymentOf(investmentAddress_);

        ( uint256 coverFee_, uint256 managementFee_ ) = IPoolManagerLike(poolManager).getFees();

        _addInvestment(Investment({
            previous:            0,
            next:                0,
            incomingNetInterest: nextInterest,
            startDate:           block.timestamp,
            paymentDueDate:      nextPaymentDueDate,
            coverFee:            coverFee_,
            managementFee:       managementFee_,
            vehicle:             investmentAddress_
        }));

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

    function _claimInvestment(address investment_) internal returns (uint256 principalPortion_, uint256 interestPortion_, uint256 coverPortion_, uint256 managementPortion_) {
        ILoanLike loan           = ILoanLike(investment_);
        principalPortion_        = principalOf[investment_] - loan.principal();
        interestPortion_         = loan.claimableFunds() - principalPortion_;
        principalOf[investment_] = loan.principal();

        uint256 id_ = investmentIdOf[investment_];

        coverPortion_      = interestPortion_ * investments[id_].coverFee      / SCALED_ONE;
        managementPortion_ = interestPortion_ * investments[id_].managementFee / SCALED_ONE;

        uint256 portionsSum_ = coverPortion_ + managementPortion_;

        if (portionsSum_ != 0) {
            loan.claimFunds(portionsSum_, address(poolManager));
            interestPortion_ -= portionsSum_;
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

        ( uint256 coverFee_, uint256 managementFee_ ) = IPoolManagerLike(poolManager).getFees();

        nextInterest_ = nextInterest_ * (SCALED_ONE - (coverFee_ + managementFee_)) / SCALED_ONE;
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

}
