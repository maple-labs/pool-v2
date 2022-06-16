
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, ILoanLike, IPoolLike } from "./interfaces/Interfaces.sol";

import { DateLinkedList } from "./LinkedList.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

// How much is claimed
// Rate domain start
// Loan issuance rate
// From this, we can do the following:
// Calculate the amount of funds that we've been expecting from this loan since freeAssets got updated last
//

/// @dev Lucas' implementation, using balance and oustanding interest for FA
/// @dev Uses nextPaymentDueDate for endingTimestamp, calculates IR based on balance + principalOut + other loans
contract PB_ST_05 is IInvestmentManagerLike, DateLinkedList {

    address public immutable asset;
    address public immutable pool;

    uint256 public immutable poolPrecision;

    uint256 public rateDomainEnd;

    uint256 public lastClaim;  // TODO: Probably can use lastUpdated when moving RDT accounting into here

    address[] public investmentsArray;

    uint256 outstandingInterestSnapshot;
    uint256 lastUpdated;
    // TODO: Need an IM IR

    mapping (address => InvestmentVehicle) public investments;

    struct InvestmentVehicle {
        uint256 indexInList;
        uint256 lastPrincipal;
        uint256 paymentDomainEnd;
        uint256 paymentDomainStart;
        uint256 paymentIssuanceRate;
    }

    constructor(address pool_) {
        asset         = IPoolLike(pool_).asset();
        pool          = pool_;
        poolPrecision = IPoolLike(pool_).precision();
    }

    // function _getUnaccruedInterest() internal view returns (uint256 unaccruedInterest_) {
    //     for (uint256 i; i < investmentsArray.length; ++i) {
    //         InvestmentVehicle memory investment = investments[investmentsArray[i]];

    //         uint256 endTimestamp = _min(block.timestamp, investment.paymentDomainEnd);

    //         unaccruedInterest_ += (endTimestamp - investment.paymentDomainStart) * investment.paymentIssuanceRate / poolPrecision;
    //     }
    // }

    function _getUnaccruedInterest() internal view returns (uint256 unaccruedInterest_) {
        for (uint256 i; i < investmentsArray.length; ++i) {
            ILoanLike loan = ILoanLike(investmentsArray[i]);

            unaccruedInterest_ += loan.claimableFunds();

            uint256 paymentDueDate    = loan.nextPaymentDueDate();
            uint256 paymentInterval   = loan.paymentInterval();
            uint256 startingTimestamp = paymentDueDate - paymentInterval;
            uint256 endTimestamp      = _min(block.timestamp, paymentDueDate);

            // console.log("Loan", i + 1);
            // console.log("loan.claimableFunds()", loan.claimableFunds() / 1e4);

            // No unaccrued interest for the next interval
            if (endTimestamp <= startingTimestamp) return unaccruedInterest_;

            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            // console.log("paymentDueDate   ", (paymentDueDate    - 1622400000) * 100 / 1 days);
            // console.log("paymentInterval  ", paymentInterval * 100 / 1 days);
            // console.log("startingTimestamp", (startingTimestamp - 1622400000) * 100 / 1 days);
            // console.log("endTimestamp     ", (endTimestamp - 1622400000) * 100 / 1 days);

            // console.log("if block", nextInterestAmount * (endTimestamp - startingTimestamp) / paymentInterval / 1e4);

            unaccruedInterest_ += nextInterestAmount * (endTimestamp - startingTimestamp) / paymentInterval;
        }
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

        console.log("Pre-Claim Asset Balance", IERC20Like(asset).balanceOf(address(pool)));

        // Claim funds from the loan, transferring to pool
        loan.claimFunds(loan.claimableFunds(), pool);

        // Reduce oustanding principal by amount claimed from loan
        principalOut_ = IPoolLike(pool).principalOut() - (investment.lastPrincipal - currentPrincipal);

        // NOTE: This model can only use its own issuance rate, not the pools, temporary implementation
        // uint256 outstandingInterest = lastClaim == 0 ? 0 : (IPoolLike(pool).issuanceRate() - investment.paymentIssuanceRate) * (block.timestamp - lastUpdated) / poolPrecision + outstandingInterestSnapshot;

        // Set the freeAssets of the pool to the cash balance plus outstanding principal after claim, plus current outstanding interest
        freeAssets_ = IERC20Like(asset).balanceOf(address(pool)) + principalOut_ + _getUnaccruedInterest();

        console.log("");
        console.log("BEFORE");
        console.log("IPoolLike(pool).freeAssets()  ", IPoolLike(pool).freeAssets());
        console.log("IPoolLike(pool).totalAssets() ", IPoolLike(pool).totalAssets());
        console.log("IPoolLike(pool).principalOut()", IPoolLike(pool).principalOut());
        console.log("RESULT");
        console.log("Asset Balance                 ", IERC20Like(asset).balanceOf(address(pool)));
        console.log("principalOut_                 ", principalOut_);
        console.log("_getUnaccruedInterest()       ", _getUnaccruedInterest());
        console.log("freeAssets_                   ", freeAssets_);

        // Remove investment from sorted list
        // TODO: Remove?
        remove(investment.indexInList);

        if (loan.nextPaymentDueDate() != 0) {
            // Update investment state
            investments[investment_].lastPrincipal = currentPrincipal;

            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            // Calculate the new issuance rate of loan
            uint256 newPaymentIssuanceRate = nextInterestAmount * poolPrecision / loan.paymentInterval();

            // Update investment position in ordered list
            uint256 endingTimestamp = loan.nextPaymentDueDate();
            investments[investment_].indexInList = insert(endingTimestamp, positionPreceeding(endingTimestamp));

            // Update issuanceRate_ for pool
            issuanceRate_ = IPoolLike(pool).issuanceRate() + newPaymentIssuanceRate - investment.paymentIssuanceRate;

            // Update rateDomainEnd and vestingPeriodFinish_ to be new shortest timestamp
            rateDomainEnd = vestingPeriodFinish_ = list[head].date;  // TODO: Change this, TODO: Make work with mistimed claims

            // Update investment state
            investments[investment_].paymentDomainStart  = investments[investment_].paymentDomainEnd;
            investments[investment_].paymentDomainEnd    = endingTimestamp;
            investments[investment_].paymentIssuanceRate = newPaymentIssuanceRate;
        } else {
            // Calculate new issuance rate
            issuanceRate_ = IPoolLike(pool).issuanceRate() - investment.paymentIssuanceRate;

            rateDomainEnd = vestingPeriodFinish_ = totalItems == 0 ? investments[investment_].paymentDomainEnd : list[head].date;

            // Delete investment object
            delete investments[investment_];
        }

        lastUpdated = block.timestamp;
        // console.log("");
        // console.log("outstandingInterestSnapshot  ", outstandingInterestSnapshot);
        // console.log("outstandingInterest          ", outstandingInterest);
        // console.log("claimedFunds                 ", claimedFunds);
        // outstandingInterestSnapshot = outstandingInterestSnapshot + outstandingInterest - claimedFunds;
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

        outstandingInterestSnapshot += IPoolLike(pool).issuanceRate() * (block.timestamp - lastUpdated) / poolPrecision;
        lastUpdated                  = block.timestamp;

        // Calculate the new issuance rate
        newIssuanceRate_ = IPoolLike(pool).issuanceRate() + paymentIssuanceRate;

        console.log("FUND");
        console.log("IPoolLike(pool).issuanceRate()", IPoolLike(pool).issuanceRate() / 1e30);
        console.log("paymentIssuanceRate           ", paymentIssuanceRate / 1e30);
        console.log("newIssuanceRate_              ", newIssuanceRate_ / 1e30);
    }

    function _min(uint256 firstVal_, uint256 secondVal_) internal pure returns (uint256 minVal_) {
        minVal_ = firstVal_ > secondVal_ ? secondVal_ : firstVal_;
    }

}

