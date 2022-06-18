// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, ILoanLike, IPoolLike } from "./interfaces/Interfaces.sol";

import { DateLinkedList } from "./LinkedList.sol";
import { DefaultHandler } from "./DefaultHandler.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

// How much is claimed
// Rate domain start
// Loan issuance rate
// From this, we can do the following:
// Calculate the amount of funds that we've been expecting from this loan since freeAssets got updated last

/// @dev Lucas' implementation, using balance and oustanding interest for FA
/// @dev Uses nextPaymentDueDate for endingTimestamp, calculates IR based on balance + principalOut + other loans
contract PB_ST_04 is IInvestmentManagerLike, DateLinkedList, DefaultHandler {

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

        uint256 claimedFunds;

        {
            uint256 preBal = IERC20Like(asset).balanceOf(address(pool));

            // Claim funds from the loan, transferring to pool
            loan.claimFunds(loan.claimableFunds(), pool);

            claimedFunds = IERC20Like(asset).balanceOf(address(pool)) - preBal;
        }

        // Reduce oustanding principal by amount claimed from loan
        principalOut_ = IPoolLike(pool).principalOut() - (investment.lastPrincipal - currentPrincipal);

        outstandingInterestSnapshot += IPoolLike(pool).issuanceRate() * (block.timestamp - lastUpdated) / poolPrecision;
        outstandingInterestSnapshot -= investment.paymentIssuanceRate * (block.timestamp - lastUpdated) / poolPrecision;

        // NOTE: This model can only use its own issuance rate, not the pools, temporary implementation
        // uint256 outstandingInterest = lastClaim == 0 ? 0 : (IPoolLike(pool).issuanceRate() - investment.paymentIssuanceRate) * (block.timestamp - lastUpdated) / poolPrecision + outstandingInterestSnapshot;

        // Set the freeAssets of the pool to the cash balance plus outstanding principal after claim, plus current outstanding interest
        freeAssets_ = IERC20Like(asset).balanceOf(address(pool)) + principalOut_ + outstandingInterestSnapshot;

        console.log("");
        console.log("IPoolLike(pool).freeAssets()  ", IPoolLike(pool).freeAssets());
        console.log("IPoolLike(pool).totalAssets() ", IPoolLike(pool).totalAssets());
        console.log("IPoolLike(pool).principalOut()", IPoolLike(pool).principalOut());
        console.log("freeAssets_                   ", freeAssets_);
        console.log("Asset Balance                 ", IERC20Like(asset).balanceOf(address(pool)));
        console.log("outstandingInterest           ", outstandingInterestSnapshot);
        console.log("principalOut_                 ", principalOut_     );

        // Remove investment from sorted list
        remove(investment.indexInList);

        if (loan.nextPaymentDueDate() != 0) {
            // Update investment state
            investments[investment_].lastPrincipal = currentPrincipal;

            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            // Calculate the new issuance rate of loan
            uint256 endingTimestamp        = loan.nextPaymentDueDate();
            uint256 newPaymentIssuanceRate = nextInterestAmount * poolPrecision / (endingTimestamp - block.timestamp);

            // Update investment position in ordered list
            investments[investment_].indexInList = insert(endingTimestamp, positionPreceeding(endingTimestamp));

            // Update issuanceRate_ for pool
            issuanceRate_ = IPoolLike(pool).issuanceRate() + newPaymentIssuanceRate - investment.paymentIssuanceRate;

            // Update rateDomainEnd and vestingPeriodFinish_ to be new shortest timestamp
            rateDomainEnd = vestingPeriodFinish_ = list[head].date;  // TODO: Change this, TODO: Make work with mistimed claims

            // Update investment state
            investments[investment_].paymentDomainStart  = block.timestamp;
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
    }

    function _min(uint256 firstVal_, uint256 secondVal_) internal pure returns (uint256 minVal_) {
        minVal_ = firstVal_ > secondVal_ ? secondVal_ : firstVal_;
    }

}

