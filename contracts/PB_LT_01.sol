// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.7;

import { IMapleLoan } from "./interfaces/IMapleLoan.sol";

import { PoolV2 as Pool } from "./PoolV2.sol";

import { DefaultHandler } from "./DefaultHandler.sol";

contract PB_LT_01 is DefaultHandler {

    uint256 public immutable poolPrecision;

    mapping(address => LoanState) internal _states;

    struct LoanState {
        uint256 totalPrincipal;
        uint256 expectedPrincipal;
        uint256 expectedInterest;
        uint256 closingPrincipal;
        uint256 closingInterest;
        uint256 paymentInterval;
        uint256 expectedAt;
        uint256 issuanceRate;
        uint256 lateFeeRate;
    }

    constructor(address pool_) DefaultHandler(pool_) {
        poolPrecision = Pool(pool_).precision();
    }

    function claim(address loan_) external
        returns (
            uint256 principalOut_,
            uint256 freeAssets_,
            uint256 issuanceRate_,
            uint256 vestingPeriodFinish_
        )
    {
        IMapleLoan loan = IMapleLoan(loan_);

        uint256 claimableAssets = loan.claimableFunds();
        loan.claimFunds(claimableAssets, address(pool));

        ( principalOut_, freeAssets_, issuanceRate_, vestingPeriodFinish_ ) = _refresh(loan_, claimableAssets);
    }

    function fund(address loan_) external returns (uint256 issuanceRate_, uint256 vestingPeriodFinish_) {
        IMapleLoan loan = IMapleLoan(loan_);

        loan.fundLoan(address(this), 0);

        ( , , issuanceRate_, vestingPeriodFinish_ ) = _refresh(loan_, 0);
    }

    /*********************/
    /* Utility Functions */
    /*********************/

    function _refresh(address loan_, uint256 claimedAssets_) internal
        returns (
            uint256 principalOut_,
            uint256 freeAssets_,
            uint256 issuanceRate_,
            uint256 vestingPeriodFinish_
        )
    {
        LoanState storage state = _states[loan_];
        IMapleLoan loan = IMapleLoan(loan_);

        // Assuming the loan was funded.
        if (state.expectedAt == 0) {
            state.totalPrincipal = loan.principal();
            ( state.expectedPrincipal, state.expectedInterest ) = loan.getNextPaymentBreakdown();
            ( state.closingPrincipal, state.closingInterest ) = loan.getClosingPaymentBreakdown();
            state.paymentInterval = loan.paymentInterval();
            state.expectedAt = loan.nextPaymentDueDate();
            state.issuanceRate = state.expectedInterest * poolPrecision / state.paymentInterval;
            state.lateFeeRate = loan.lateFeeRate();

            // Update the issuance rate, and increase the vesting period by up to the payment interval.
            return _refresh(0, 0, int256(state.issuanceRate), state.paymentInterval);
        }

        // Assuming the loan was closed.
        if (claimedAssets_ == state.closingPrincipal + state.closingInterest) {
            // Calculate the amount of interest that has been already vested in advance.
            uint256 timeElapsed = state.paymentInterval - (state.expectedAt - block.timestamp);
            uint256 falseInterest = state.issuanceRate * timeElapsed / poolPrecision;

            // Add the closing fee and retroactively remove part of the expected interest that was vested so far.
            return _refresh(state.closingPrincipal, int256(state.closingInterest) - int256(falseInterest), -int256(state.issuanceRate), 0);
        }

        uint256 principalReturned = state.expectedPrincipal;
        int256  adjustment        = 0;
        int256  acceleration      = 0;
        uint256 duration          = 0;

        // Assuming an early payment was made.
        if (block.timestamp <= state.expectedAt) {
            // Immediately adjust to account for the payment arriving early.
            adjustment   += int256(state.issuanceRate * (state.expectedAt - block.timestamp) / poolPrecision);
            acceleration -= int256(state.issuanceRate);
        }

        // Assuming a late payment was made.
        else {
            // Calculate how much extra time has elapsed for the late payment.
            uint256 extraTime = block.timestamp - state.expectedAt;

            // Ignore any time after the vesting period finish due to issuance rate becoming zero.
            if (block.timestamp > Pool(pool).vestingPeriodFinish()) {
                // Ignore the time only if the vesting period finish was not reduced due to another IM which uses shortest timestamps.
                if (state.expectedAt <= Pool(pool).vestingPeriodFinish()) {
                    extraTime -= block.timestamp - Pool(pool).vestingPeriodFinish();
                }
            }

            // Calculate the amount that was already vested by accident.
            uint256 alreadyVested = state.issuanceRate * extraTime / poolPrecision;

            // Calculate the late payment fee received.
            uint256 latePaymentFee = claimedAssets_ - state.expectedPrincipal - state.expectedInterest;

            // Add the late payment fee and remove any interest vested accidentally in advance.
            adjustment   += int256(latePaymentFee) - int256(alreadyVested);
            acceleration -= int256(state.issuanceRate);
        }

        // If there are remaining payments.
        if (loan.paymentsRemaining() != 0) {
            state.totalPrincipal = loan.principal();
            ( state.expectedPrincipal, state.expectedInterest ) = loan.getNextPaymentBreakdown();
            ( state.closingPrincipal, state.closingInterest ) = loan.getClosingPaymentBreakdown();
            state.paymentInterval = loan.paymentInterval();

            // If an early payment was made, extend the payment interval to account for the time that is yet to elapse.
            if (block.timestamp < state.expectedAt) {
                state.paymentInterval += state.expectedAt - block.timestamp;
            }

            // If a late payment was made, shorten the payment interval to account for the time that has already elapsed.
            if (block.timestamp > state.expectedAt) {
                state.paymentInterval = loan.nextPaymentDueDate() - block.timestamp;
            }

            state.expectedAt = loan.nextPaymentDueDate();
            state.issuanceRate = state.expectedInterest * poolPrecision / state.paymentInterval;
            state.lateFeeRate = loan.lateFeeRate();

            acceleration += int256(state.issuanceRate);
            duration     += state.paymentInterval;
        }

        return _refresh(principalReturned, adjustment, acceleration, duration);
    }

    function _refresh(uint256 principalReturned_, int256 adjustment_, int256 acceleration_, uint256 duration_) internal view
        returns (
            uint256 principalOut_,
            uint256 freeAssets_,
            uint256 issuanceRate_,
            uint256 vestingPeriodFinish_
        )
    {
        principalOut_        = Pool(pool).principalOut() - principalReturned_;
        freeAssets_          = uint256(int256(Pool(pool).freeAssets()) + adjustment_);
        issuanceRate_        = uint256(int256(Pool(pool).issuanceRate()) + acceleration_);
        vestingPeriodFinish_ = Pool(pool).vestingPeriodFinish();

        if (block.timestamp + duration_ > vestingPeriodFinish_) {
            vestingPeriodFinish_ = block.timestamp + duration_;
        }
    }

}
