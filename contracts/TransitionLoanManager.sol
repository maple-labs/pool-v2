// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IMapleProxyFactory }    from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import { ITransitionLoanManager } from "./interfaces/ITransitionLoanManager.sol";
import {
    IERC20Like,
    IMapleGlobalsLike,
    ILoanLike,
    ILoanV3Like,
    IPoolLike,
    IPoolManagerLike
} from "./interfaces/Interfaces.sol";

import { LoanManagerStorage } from "./proxy/LoanManagerStorage.sol";

// Carbon copy of LM, but witht modified fund/claim to allow for bootstrapping the pool.
contract TransitionLoanManager is ITransitionLoanManager, MapleProxiedInternals, LoanManagerStorage {

    uint256 public override constant PRECISION  = 1e30;
    uint256 public override constant SCALED_ONE = 1e18;

    /***************************/
    /*** Migration Functions ***/
    /***************************/

    function migrate(address migrator_, bytes calldata arguments_) external override {
        require(msg.sender == _factory(),        "LM:M:NOT_FACTORY");
        require(_migrate(migrator_, arguments_), "LM:M:FAILED");
    }

    function setImplementation(address implementation_) external override {
        require(msg.sender == _factory(), "LM:SI:NOT_FACTORY");

        _setImplementation(implementation_);
    }

    // TODO: Investigate using migration admin here.
    function upgrade(uint256 version_, bytes calldata arguments_) external override {
        require(msg.sender == IPoolManagerLike(poolManager).poolDelegate(), "LM:U:NOT_PD");

        IMapleProxyFactory(_factory()).upgradeInstance(version_, arguments_);
    }

    // TODO: Add unit tests
    function add(address loanAddress_) external override {
        // TODO add ACL: globals.MIGRATION_ADMIN()?

        uint256 dueDate_ = ILoanLike(loanAddress_).nextPaymentDueDate();

        require(dueDate_ != 0, "LM:A:EXPIRED_LOAN");

        uint256 startDate_ = dueDate_ - ILoanLike(loanAddress_).paymentInterval();
        uint256 newRate_   = _queueNextLoanPayment(loanAddress_, startDate_, dueDate_);

        principalOut += ILoanLike(loanAddress_).principal();
        issuanceRate += newRate_;
        domainStart   = block.timestamp;
        domainEnd     = loans[loanWithEarliestPaymentDueDate].paymentDueDate;
    }

    // TODO: Add bulk removeOwnership function.
    function takeOwnership(address[] calldata loanAddress_) external override {
        // TODO add ACL: globals.MIGRATION_ADMIN()?

        for (uint256 i = 0; i < loanAddress_.length; i++) {
            ILoanLike(loanAddress_[i]).acceptLender();
        }
    }

    /***************************************/
    /*** Internal Loan Sorting Functions ***/
    /***************************************/

    function _addLoanToList(uint256 loanId_, LoanInfo memory loan_) internal {
        uint256 current = 0;
        uint256 next    = loanWithEarliestPaymentDueDate;

        while (next != 0 && loan_.paymentDueDate >= loans[next].paymentDueDate) {
            current = next;
            next    = loans[current].next;
        }

        if (current != 0) {
            loans[current].next = loanId_;
        } else {
            loanWithEarliestPaymentDueDate = loanId_;
        }

        if (next != 0) {
            loans[next].previous = loanId_;
        }

        loan_.next     = next;
        loan_.previous = current;

        loans[loanId_] = loan_;
    }

    function _removeLoanFromList(uint256 previous_, uint256 next_, uint256 loanId_) internal {
        if (loanWithEarliestPaymentDueDate == loanId_) {
            loanWithEarliestPaymentDueDate = next_;
        }

        if (next_ != 0) {
            loans[next_].previous = previous_;
        }

        if (previous_ != 0) {
            loans[previous_].next = next_;
        }
    }

    /******************************************/
    /*** Internal Loan Accounting Functions ***/
    /******************************************/

    function _queueNextLoanPayment(address loan_, uint256 startDate_, uint256 nextPaymentDueDate_) internal returns (uint256 newRate_) {
        uint256 platformManagementFeeRate_ = IMapleGlobalsLike(globals()).platformManagementFeeRate(poolManager);
        uint256 delegateManagementFeeRate_ = IPoolManagerLike(poolManager).delegateManagementFeeRate();
        uint256 managementFeeRate_         = platformManagementFeeRate_ + delegateManagementFeeRate_;

        ( , uint256 incomingNetInterest_ ) = ILoanV3Like(loan_).getNextPaymentBreakdown();

        // Some of the loans aren't upgraded to have the refinance interest and even if they did, the refinance interest doesn't matter for the transition loan manager.
        uint256 refinanceInterest_ = 0;

        // Interest used for issuance rate calculation is:
        // Net interest minus the interest accrued prior to refinance.
        incomingNetInterest_ = (incomingNetInterest_ * (SCALED_ONE - managementFeeRate_) / SCALED_ONE) - refinanceInterest_;

        newRate_ = (incomingNetInterest_ * PRECISION) / (nextPaymentDueDate_ - startDate_);

        // Add the LoanInfo to the sorted list, making sure to take the effective start date (and not the current block timestamp).
        uint256 loanId_ = loanIdOf[loan_] = ++loanCounter;

        // Add the LoanInfo to the sorted list, making sure to take the effective start date (and not the current block timestamp).
        _addLoanToList(loanId_, LoanInfo({
            // Previous and next will be overriden within _addLoan function
            previous:                  0,
            next:                      0,
            incomingNetInterest:       incomingNetInterest_,
            refinanceInterest:         refinanceInterest_,
            issuanceRate:              newRate_,
            startDate:                 startDate_,
            paymentDueDate:            nextPaymentDueDate_,
            platformManagementFeeRate: platformManagementFeeRate_,
            delegateManagementFeeRate: delegateManagementFeeRate_
        }));

        // Update the accounted interest to reflect what is present in the loan.
        accountedInterest += refinanceInterest_;

        // Discretely update accrued interest in this payment interval.
        accountedInterest += newRate_ * (block.timestamp - startDate_) / PRECISION;
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function assetsUnderManagement() public view override returns (uint256 assetsUnderManagement_) {
        return principalOut + accountedInterest + getAccruedInterest();
    }

    function factory() external view override returns (address factory_) {
        return _factory();
    }

    function getAccruedInterest() public view override returns (uint256 accruedInterest_) {
        uint256 issuanceRate_ = issuanceRate;

        if (issuanceRate_ == 0) return uint256(0);

        // If before domain end, use current timestamp.
        accruedInterest_ = issuanceRate_ * (_min(block.timestamp, domainEnd) - domainStart) / PRECISION;
    }

    function globals() public view override returns (address globals_) {
        return IPoolManagerLike(poolManager).globals();
    }

    function implementation() external view override returns (address implementation_) {
        return _implementation();
    }

    function poolDelegate() public view override returns (address poolDelegate_) {
        return IPoolManagerLike(poolManager).poolDelegate();
    }

    /*********************************/
    /*** Internal Helper Functions ***/
    /*********************************/

    function _max(uint256 a_, uint256 b_) internal pure returns (uint256 maximum_) {
        return a_ > b_ ? a_ : b_;
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256 minimum_) {
        return a_ < b_ ? a_ : b_;
    }

}
