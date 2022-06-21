// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, ILoanLike, IPoolCoverManagerLike, IPoolLike, IPoolManagerLike } from "./interfaces/Interfaces.sol";

import { DateLinkedList } from "./DateLinkedList.sol";
import { DefaultHandler } from "./DefaultHandler.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

// How much is claimed
// Rate domain start
// Loan issuance rate
// From this, we can do the following:
// Calculate the amount of funds that we've been expecting from this loan since freeAssets got updated last

/// @dev Lucas' implementation, using balance and oustanding interest for FA
/// @dev Uses nextPaymentDueDate for endingTimestamp, calculates IR based on balance + principalOut + other loans
contract PB_ST_05 is DateLinkedList, DefaultHandler {

    address public immutable poolManager;

    uint256 public immutable poolPrecision;

    uint256 public rateDomainEnd;

    uint256 public lastClaim;  // TODO: Probably can use lastUpdated when moving RDT accounting into here

    uint256 outstandingInterestSnapshot;
    uint256 lastUpdated;
    // TODO: Need an IM IR

    mapping (address => uint256) investmentIds;  // TODO: Figure out a better way to structure this

    mapping (uint256 => InvestmentVehicle) public investments;

    struct InvestmentVehicle {
        address investmentAddress;
        uint256 lastPrincipal;
        uint256 paymentDomainEnd;
        uint256 paymentDomainStart;
        uint256 paymentIssuanceRate;
    }

    constructor(address pool_) DefaultHandler(pool_) {
        fundsAsset = IPoolLike(pool_).asset();

        address poolManagerCache = poolManager = IPoolLike(pool_).manager();

        poolPrecision = IPoolManagerLike(poolManagerCache).precision();

        pool = pool_;
    }

    function _getUnaccruedInterest() internal view returns (uint256 unaccruedInterest_) {
        uint256 nodeId = head;

        while (nodeId != 0) {
            ILoanLike loan = ILoanLike(investments[nodeId].investmentAddress);

            unaccruedInterest_ += loan.claimableFunds();

            uint256 paymentDueDate    = loan.nextPaymentDueDate();
            uint256 paymentInterval   = loan.paymentInterval();
            uint256 startingTimestamp = paymentDueDate - paymentInterval;
            uint256 endTimestamp      = _min(block.timestamp, paymentDueDate);

            nodeId = list[nodeId].nextId;

            // No unaccrued interest for the next interval
            if (endTimestamp <= startingTimestamp) continue;

            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            unaccruedInterest_ += nextInterestAmount * (endTimestamp - startingTimestamp) / paymentInterval;
        }
    }

    function claim(address investment_)
        external returns (
            uint256 principalOut_,
            uint256 freeAssets_,
            uint256 issuanceRate_,
            uint256 vestingPeriodFinish_
        )
    {
        uint256 nodeId = investmentIds[investment_];
        ILoanLike loan = ILoanLike(investment_);

        InvestmentVehicle memory cachedInvestment = investments[nodeId];

        // Get state of the loan
        uint256 currentPrincipal = loan.principal();

        uint256 principalPaid = cachedInvestment.lastPrincipal - currentPrincipal;
        uint256 totalInterest = loan.claimableFunds() - principalPaid;

        address poolCoverManager = IPoolManagerLike(poolManager).poolCoverManager();

        if (poolCoverManager != address(0)) {
            uint256 poolCoverInterest = totalInterest / 5;  // 20%
            totalInterest = totalInterest * 4 / 5;          // 80%

            loan.claimFunds(poolCoverInterest, poolCoverManager);
            IPoolCoverManagerLike(poolCoverManager).allocateLiquidity();
        }

        // Claim funds from the loan, transferring to pool
        loan.claimFunds(loan.claimableFunds(), pool);

        // Reduce oustanding principal by amount claimed from loan
        principalOut_ = IPoolManagerLike(poolManager).principalOut() - (cachedInvestment.lastPrincipal - currentPrincipal);

        // NOTE: This model can only use its own issuance rate, not the pools, temporary implementation
        // uint256 outstandingInterest = lastClaim == 0 ? 0 : (IPoolManagerLike(poolManager).issuanceRate() - investment.paymentIssuanceRate) * (block.timestamp - lastUpdated) / poolPrecision + outstandingInterestSnapshot;

        uint256 unaccruedInterest = _getUnaccruedInterest();

        // Set the freeAssets of the pool to the cash balance plus outstanding principal after claim, plus current outstanding interest
        freeAssets_ = IERC20Like(fundsAsset).balanceOf(address(pool)) + principalOut_ + unaccruedInterest;

        // Remove investment from sorted list
        remove(nodeId);

        // Delete investment object
        delete investments[nodeId];

        if (loan.nextPaymentDueDate() != 0) {
            // Update investment state
            investments[nodeId].lastPrincipal = currentPrincipal;

            ( , uint256 nextInterestAmount ) = loan.getNextPaymentBreakdown();

            // Calculate the new issuance rate of loan
            uint256 newPaymentIssuanceRate = nextInterestAmount * poolPrecision / loan.paymentInterval();

            // Update investment position in ordered list
            uint256 endingTimestamp = loan.nextPaymentDueDate();

            uint256 indexInList = insert(endingTimestamp, positionPreceeding(endingTimestamp));

            // Add new loan to investments mapping and array
            investments[indexInList] = InvestmentVehicle({
                investmentAddress:   address(loan),
                lastPrincipal:       currentPrincipal,
                paymentDomainEnd:    endingTimestamp,
                paymentDomainStart:  cachedInvestment.paymentDomainEnd,
                paymentIssuanceRate: newPaymentIssuanceRate
            });

            investmentIds[address(loan)] = indexInList;

            // Update issuanceRate_ for pool
            issuanceRate_ = IPoolManagerLike(poolManager).issuanceRate() + newPaymentIssuanceRate - cachedInvestment.paymentIssuanceRate;

            // Update rateDomainEnd and vestingPeriodFinish_ to be new shortest timestamp
            rateDomainEnd = vestingPeriodFinish_ = list[head].date;  // TODO: Change this, TODO: Make work with mistimed claims
        } else {
            // Calculate new issuance rate
            issuanceRate_ = IPoolManagerLike(poolManager).issuanceRate() - cachedInvestment.paymentIssuanceRate;

            rateDomainEnd = vestingPeriodFinish_ = totalItems == 0 ? cachedInvestment.paymentDomainEnd : list[head].date;
        }
    }

    function fund(address investment_) external returns (
        uint256 principalOut_,
        uint256 freeAssets_,
        uint256 issuanceRate_,
        uint256 vestingPeriodFinish_
    ) {
        require(msg.sender == poolManager, "IV:F:NOT_ADMIN");

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
        investments[indexInList] = InvestmentVehicle({
            investmentAddress:   investment_,
            lastPrincipal:       principal,
            paymentDomainEnd:    endingTimestamp,
            paymentDomainStart:  block.timestamp,
            paymentIssuanceRate: paymentIssuanceRate
        });

        investmentIds[investment_] = indexInList;

        // Calculate the new issuance Rate's domain
        rateDomainEnd = vestingPeriodFinish_ = list[head].date;  // Get earliest timestamp from linked list

        outstandingInterestSnapshot += IPoolManagerLike(poolManager).issuanceRate() * (block.timestamp - lastUpdated) / poolPrecision;
        lastUpdated                  = block.timestamp;

        // Calculate the new issuance rate
        issuanceRate_ = IPoolManagerLike(poolManager).issuanceRate() + paymentIssuanceRate;

        principalOut_ = IPoolManagerLike(poolManager).principalOut() + principal;  // TODO: Make more robust

        uint256 unaccruedInterest = _getUnaccruedInterest();

        // Set the freeAssets of the pool to the cash balance plus outstanding principal after claim, plus current outstanding interest
        freeAssets_ = IERC20Like(fundsAsset).balanceOf(address(pool)) + principalOut_ + unaccruedInterest;
    }

    function _min(uint256 firstVal_, uint256 secondVal_) internal pure returns (uint256 minVal_) {
        minVal_ = firstVal_ > secondVal_ ? secondVal_ : firstVal_;
    }

}
