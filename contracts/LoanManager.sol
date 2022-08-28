// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { ERC20Helper }           from "../modules/erc20-helper/src/ERC20Helper.sol";
import { Liquidator }            from "../modules/liquidations/contracts/Liquidator.sol";
import { IMapleProxyFactory }    from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import { ILoanManager } from "./interfaces/ILoanManager.sol";

import {
    IERC20Like,
    ILoanLike,
    ILiquidatorLike,
    IMapleGlobalsLike,
    IPoolManagerLike
} from "./interfaces/Interfaces.sol";

import { LoanManagerStorage } from "./proxy/LoanManagerStorage.sol";

contract LoanManager is ILoanManager, MapleProxiedInternals, LoanManagerStorage {

    uint256 public override constant PRECISION       = 1e30;
    uint256 public override constant HUNDRED_PERCENT = 1e6;  // 100.0000%

    /*****************/
    /*** Modifiers ***/
    /*****************/

    modifier nonReentrant() {
        require(_locked == 1, "P:LOCKED");

        _locked = 2;

        _;

        _locked = 1;
    }

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

    function upgrade(uint256 version_, bytes calldata arguments_) external override {
        address poolDelegate_ = IPoolManagerLike(poolManager).poolDelegate();

        require(msg.sender == poolDelegate_ || msg.sender == governor(), "LM:U:NOT_AUTHORIZED");

        IMapleGlobalsLike mapleGlobals = IMapleGlobalsLike(globals());

        if (msg.sender == poolDelegate_) {
            require(mapleGlobals.isValidScheduledCall(msg.sender, address(this), "LM:UPGRADE", msg.data), "LM:U:NOT_SCHEDULED");

            mapleGlobals.unscheduleCall(msg.sender, "LM:UPGRADE", msg.data);
        }

        IMapleProxyFactory(_factory()).upgradeInstance(version_, arguments_);
    }

    /********************************/
    /*** Administrative Functions ***/
    /********************************/

    // TODO: Add test coverage
    function setAllowedSlippage(address collateralAsset_, uint256 allowedSlippage_) external override {
        require(msg.sender == poolManager,           "LM:SAS:NOT_POOL_MANAGER");
        require(allowedSlippage_ <= HUNDRED_PERCENT, "LM:SAS:INVALID_SLIPPAGE");

        emit AllowedSlippageSet(collateralAsset_, allowedSlippageFor[collateralAsset_] = allowedSlippage_);
    }

    function setMinRatio(address collateralAsset_, uint256 minRatio_) external override {
        require(msg.sender == poolManager, "LM:SMR:NOT_POOL_MANAGER");
        emit MinRatioSet(collateralAsset_, minRatioFor[collateralAsset_] = minRatio_);
    }

    /*********************************************/
    /*** Loan and Payment Accounting Functions ***/
    /*********************************************/

    function acceptNewTerms(address loan_, address refinancer_, uint256 deadline_, bytes[] calldata calls_) external override nonReentrant {
        require(msg.sender == poolManager, "LM:ANT:NOT_ADMIN");

        _advancePaymentAccounting();

        // Remove payment from sorted list and get relevant previous parameters.
        uint256 previousRate_     = _recognizePayment(loan_);
        uint256 previousPrincipal = ILoanLike(loan_).principal();

        // Perform the refinancing, updating the loan state.
        ILoanLike(loan_).acceptNewTerms(refinancer_, deadline_, calls_);

        principalOut = principalOut + _uint128(ILoanLike(loan_).principal()) - _uint128(previousPrincipal);

        uint256 newRate_ = _queueNextPayment(loan_, block.timestamp, ILoanLike(loan_).nextPaymentDueDate());

        // The new vesting period finish is the maximum of the current earliest, if it does not exist set to
        // current timestamp to end vesting.
        // TODO: Investigate adding `_accountToEndOfPayment` logic
        domainEnd = payments[paymentWithEarliestDueDate].paymentDueDate;

        // Update the vesting state an then set the new issuance rate take into account the cessation of the previous rate
        // and the commencement of the new rate for this payment.
        issuanceRate = _uint128(issuanceRate + newRate_ - previousRate_);

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
    }

    function claim(uint256 principal_, uint256 interest_, uint256 previousPaymentDueDate_, uint256 nextPaymentDueDate_) external override nonReentrant {
        require(paymentIdOf[msg.sender] != 0, "LM:C:NOT_LOAN");

        _advancePaymentAccounting();

        // Claim loan and send funds to the pool, treasury, and pool delegate.
        _handleClaimedFunds(msg.sender, principal_, interest_);

        uint256 newRate_;
        uint256 previousRate_;

        // Check if the default warning has been triggered.
        if (liquidationInfo[msg.sender].principal != 0) {
            _recognizePaymentOfLoanInDefaultWarning(msg.sender);  // Don't set the previous rate since it will always be zero.
        } else {
            previousRate_ = _recognizePayment(msg.sender);
        }

        // The next rate will be over the course of the remaining time, or the payment interval, whichever is longer.
        // In other words, if the previous payment was early, then the next payment will start accruing from now,
        // but if the previous payment was late, then we should have been accruing the next payment
        // from the moment the previous payment was due.
        uint256 nextStartDate_ = _min(block.timestamp, previousPaymentDueDate_);

        // If there is a next payment for this loan.
        if (nextPaymentDueDate_ != 0) {
            newRate_ = _queueNextPayment(msg.sender, nextStartDate_, nextPaymentDueDate_);

            if (block.timestamp > nextPaymentDueDate_) {
                // If the current timestamp is greater than the resulting next payment due date, then the next payment must be
                // FULLY accounted for, and the payment must be removed from the sorted list.
                uint256 paymentId_ = paymentIdOf[msg.sender];

                // NOTE: Payment issuance rate is used for this calculation as the issuance has occured in isolation and entirely in the past.
                //       All interest from the aggregate issuance rate has already been accounted for.
                ( uint256 accountedInterestIncrease_, ) = _accountToEndOfPayment(paymentId_, payments[paymentId_].issuanceRate, previousPaymentDueDate_, nextPaymentDueDate_);

                accountedInterest += _uint112(accountedInterestIncrease_);

                // `newRate_` always equals `issuanceRateReduction_`
                newRate_ = 0;
            } else if (block.timestamp > previousPaymentDueDate_) {
                // If the current timestamp is greater than the previous payment due date, then the next payment must be
                // PARTIALLY accounted for, using the new payment's issuance rate and the time passed in the new interval.
                accountedInterest += _uint112((block.timestamp - previousPaymentDueDate_) * newRate_ / PRECISION);
            }
        }

        // Update domainEnd to reflect the new sorted list state.
        domainEnd = payments[paymentWithEarliestDueDate].paymentDueDate;

        // Update the vesting state an then set the new issuance rate take into account the cessation of the previous rate
        // and the commencement of the new rate for this payment.
        issuanceRate = issuanceRate + newRate_ - previousRate_;

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
    }

    function fund(address loanAddress_) external override nonReentrant {
        require(msg.sender == poolManager, "LM:F:NOT_POOL_MANAGER");

        _advancePaymentAccounting();

        ILoanLike(loanAddress_).fundLoan(address(this));

        uint256 newRate_ = _queueNextPayment(loanAddress_, block.timestamp, ILoanLike(loanAddress_).nextPaymentDueDate());

        principalOut += _uint128(ILoanLike(loanAddress_).principal());
        issuanceRate += newRate_;
        domainEnd     = payments[paymentWithEarliestDueDate].paymentDueDate;

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
    }

    /*************************/
    /*** Default Functions ***/
    /*************************/

    function removeDefaultWarning(address loan_, bool isCalledByGovernor_) external override nonReentrant {
        require(msg.sender == poolManager, "LM:RDW:NOT_PM");

        _advancePaymentAccounting();

        ILoanLike(loan_).removeDefaultWarning();

        uint24 paymentId_               = paymentIdOf[loan_];
        PaymentInfo memory paymentInfo_ = payments[paymentId_];

        // TODO: Storage is also read within _revertDefaultWarning function, so can be optimized. But the following reversion should be in this function (JG's opinion)
        require(!liquidationInfo[loan_].triggeredByGovernor || isCalledByGovernor_, "LM:RDW:NOT_AUTHORIZED");

        _revertDefaultWarning(loan_);

        delete payments[paymentId_];
        payments[paymentIdOf[loan_] = _addPaymentToList(paymentInfo_.paymentDueDate)] = paymentInfo_;

        // Discretely update missing interest as if payment was always part of the list.
        accountedInterest += _uint112(_getPaymentAccruedInterest(paymentInfo_.startDate, domainStart, paymentInfo_.issuanceRate, paymentInfo_.refinanceInterest));
        issuanceRate      += paymentInfo_.issuanceRate;

        domainEnd = payments[paymentWithEarliestDueDate].paymentDueDate;

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);
    }

    // TODO: Ensure that the default warning can not be triggered after the payment due date.
    function triggerDefaultWarning(address loan_, bool isGovernor_) external override {
        require(msg.sender == poolManager, "LM:TDW:NOT_PM");

        _advancePaymentAccounting();

        uint256 principal_              = ILoanLike(loan_).principal();
        uint256 paymentId_              = paymentIdOf[loan_];
        PaymentInfo memory paymentInfo_ = payments[paymentId_];

        ( uint256 netInterest_, , uint256 platformManagementFee_, uint256 platformServiceFee_ ) = _getLiquidationInfoAmounts(loan_, paymentInfo_, false);

        liquidationInfo[loan_] = LiquidationInfo({
            triggeredByGovernor: isGovernor_,
            principal:           _uint128(principal_),
            interest:            _uint120(netInterest_),
            lateInterest:        0,
            platformFees:        _uint96(platformManagementFee_ + platformServiceFee_),
            liquidator:          address(0)
        });

        issuanceRate     -= paymentInfo_.issuanceRate;  // TODO: Is this supposed to be here?
        unrealizedLosses += _uint128(principal_ + netInterest_);

        _removePaymentFromList(paymentId_);
        _updateDomainEnd();

        ILoanLike(loan_).triggerDefaultWarning();

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);
    }

    // TODO: Reorder functions alphabetically.
    function finishCollateralLiquidation(address loan_) external override nonReentrant returns (uint256 remainingLosses_, uint256 platformFees_) {
        require(msg.sender == poolManager,   "LM:FCL:NOT_POOL_MANAGER");
        require(!isLiquidationActive(loan_), "LM:FCL:LIQ_STILL_ACTIVE");

        // Philosophy for this function is triggerCollateralLiquidation should figure out all the details,
        // and finish should use that info and execute the liquidation and accounting updates.
        LiquidationInfo memory liquidationInfo_ = liquidationInfo[loan_];

        uint256 recoveredFunds_ = IERC20Like(fundsAsset).balanceOf(liquidationInfo_.liquidator);

        remainingLosses_ = liquidationInfo_.principal + liquidationInfo_.interest + liquidationInfo_.lateInterest;
        platformFees_    = liquidationInfo_.platformFees;

        // Realize the loss following the liquidation.
        unrealizedLosses -= _uint128(remainingLosses_);

        // Reduce principal out, since it has been accounted for in the liquidation.
        principalOut -= liquidationInfo_.principal;

        // Reduce accounted interest by the interest portion of the shortfall, as the loss has been realized, and therefore this interest has been accounted for.
        // Don't reduce by late interest, since we never account for this interest in the issuance rate, only via discrete updates.
        accountedInterest -= _uint112(liquidationInfo_.interest);

        platformFees_ = liquidationInfo_.platformFees;

        uint256 toTreasury_ = _min(recoveredFunds_, platformFees_);

        recoveredFunds_ -= toTreasury_;
        platformFees_   -= toTreasury_;

        uint256 toPool_ = _min(recoveredFunds_, remainingLosses_);

        recoveredFunds_  -= toPool_;
        remainingLosses_ -= toPool_;

        // TODO: Confirm where overflow funds go.
        if (toTreasury_     != 0) ILiquidatorLike(liquidationInfo_.liquidator).pullFunds(fundsAsset, mapleTreasury(),             toTreasury_);
        if (toPool_         != 0) ILiquidatorLike(liquidationInfo_.liquidator).pullFunds(fundsAsset, pool,                        toPool_);
        if (recoveredFunds_ != 0) ILiquidatorLike(liquidationInfo_.liquidator).pullFunds(fundsAsset, ILoanLike(loan_).borrower(), recoveredFunds_);

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);

        delete liquidationInfo[loan_];
        delete payments[paymentIdOf[loan_]];
        delete paymentIdOf[loan_];
    }

    /// @dev Trigger Default on a loan.
    function triggerCollateralLiquidation(address loan_) external override nonReentrant {
        require(msg.sender == poolManager, "LM:TCL:NOT_POOL_MANAGER");

        // Get payment info prior to advancing payment accounting, because that will set issuance rate to 0.
        uint24 paymentId_               = paymentIdOf[loan_];
        PaymentInfo memory paymentInfo_ = payments[paymentId_];

        _advancePaymentAccounting();

        address collateralAsset_ = ILoanLike(loan_).collateralAsset();
        address fundsAsset_      = fundsAsset;

        // If there's collateral to liquidate, allocate a liquidator.
        address liquidator_;

        if (IERC20Like(collateralAsset_).balanceOf(loan_) != 0 || IERC20Like(fundsAsset_).balanceOf(loan_) != 0) {
            liquidator_ = address(
                new Liquidator({
                    owner_:           address(this),
                    collateralAsset_: collateralAsset_,
                    fundsAsset_:      fundsAsset_,
                    auctioneer_:      address(this),
                    destination_:     address(this),
                    globals_:         globals()
                })
            );
        }

        // Gather collateral and cover liquidation details.
        if (!ILoanLike(loan_).isInDefaultWarning()) {
            uint256 principal_ = ILoanLike(loan_).principal();

            (
                uint256 netInterest_,
                uint256 netLateInterest_,
                uint256 platformManagementFee_,
                uint256 platformServiceFee_
            ) = _getLiquidationInfoAmounts(loan_, paymentInfo_, true);

            // Impair the pool with the default amount.
            // NOTE: Don't include fees in unrealized losses, because this is not to be passed onto the LPs. Only collateral and cover can cover the fees.
            unrealizedLosses += _uint128(principal_ + netInterest_ + netLateInterest_);

            // Loan Info is removed from actively accruing payments, because this function confirms that the payment will not be made and that it is recognized as a loss.
            _removePaymentFromList(paymentId_);

            liquidationInfo[loan_] = LiquidationInfo({
                triggeredByGovernor: false,
                principal:           _uint128(principal_),
                interest:            _uint120(netInterest_),
                lateInterest:        netLateInterest_,  // TODO: Cast
                platformFees:        _uint96(platformManagementFee_ + platformServiceFee_),
                liquidator:          liquidator_
            });
        } else {
            // Liquidation info was already set in trigger default warning.
            liquidationInfo[loan_].liquidator = liquidator_;
        }

        _updateDomainEnd();

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);

        ILoanLike(loan_).repossess(liquidator_);
    }

    /***************************************/
    /*** Internal Payment Sorting Functions ***/
    /***************************************/

    // TODO: Should domain end be set here to the end date of paymentWithEarliestDueDate.
    function _addPaymentToList(uint48 paymentDueDate_) internal returns (uint24 paymentId_) {
        paymentId_ = ++paymentCounter;

        uint24 current_ = uint24(0);
        uint24 next_    = paymentWithEarliestDueDate;

        while (next_ != 0 && paymentDueDate_ >= sortedPayments[next_].paymentDueDate) {
            current_ = next_;
            next_    = sortedPayments[current_].next;
        }

        if (current_ != 0) {
            sortedPayments[current_].next = paymentId_;
        } else {
            paymentWithEarliestDueDate = paymentId_;
        }

        if (next_ != 0) {
            sortedPayments[next_].previous = paymentId_;
        }

        sortedPayments[paymentId_] = SortedPayment({ previous: current_, next: next_, paymentDueDate: paymentDueDate_ });
    }

    function _removePaymentFromList(uint256 paymentId_) internal {
        SortedPayment memory sortedPayment_ = sortedPayments[paymentId_];

        uint24 previous_ = sortedPayment_.previous;
        uint24 next_     = sortedPayment_.next;

        if (paymentWithEarliestDueDate == paymentId_) {
            paymentWithEarliestDueDate = next_;
        }

        if (next_ != 0) {
            sortedPayments[next_].previous = previous_;
        }

        if (previous_ != 0) {
            sortedPayments[previous_].next = next_;
        }

        delete sortedPayments[paymentId_];
    }

    /*********************************************/
    /*** Internal Payment Accounting Functions ***/
    /*********************************************/

    // Advance payments in previous domains to "catch up" to current state.
    function _accountToEndOfPayment(
        uint256 paymentId_,
        uint256 issuanceRate_,
        uint256 intervalStart_,
        uint256 intervalEnd_
    )
        internal returns (uint256 accountedInterestIncrease_, uint256 issuanceRateReduction_)
    {
        PaymentInfo memory payment_ = payments[paymentId_];

        // Remove the payment from the linked list so the next payment can be used as the shortest timestamp.
        // NOTE: This keeps the payment accounting info intact so it can be accounted for when the payment is claimed.
        _removePaymentFromList(paymentId_);

        issuanceRateReduction_ = payment_.issuanceRate;

        // Update accounting between timestamps and set last updated to the domainEnd.
        // Reduce the issuanceRate for the payment.
        accountedInterestIncrease_ = (intervalEnd_ - intervalStart_) * issuanceRate_ / PRECISION;

        // Remove issuanceRate as it is deducted from global issuanceRate.
        payments[paymentId_].issuanceRate = 0;
    }

    // TODO: Gas optimize
    function _accountPreviousDomains() internal {
        uint256 domainEnd_ = domainEnd;

        if (domainEnd_ == 0 || block.timestamp <= domainEnd_) return;

        uint256 paymentId_ = paymentWithEarliestDueDate;

        // Cache variables for looping.
        uint256 accountedInterest_ = accountedInterest;
        uint256 domainStart_       = domainStart;
        uint256 issuanceRate_      = issuanceRate;

        // Advance payments in previous domains to "catch up" to current state.
        while (block.timestamp > domainEnd_) {
            uint256 next_ = sortedPayments[paymentId_].next;

            ( uint256 accountedInterestIncrease_, uint256 issuanceRateReduction_ ) = _accountToEndOfPayment(paymentId_, issuanceRate_, domainStart_, domainEnd_);
            accountedInterest_ += accountedInterestIncrease_;
            issuanceRate_      -= issuanceRateReduction_;

            domainStart_ = domainEnd_;
            domainEnd_   = payments[paymentWithEarliestDueDate].paymentDueDate;

            // If the end of the list has been reached, exit the loop.
            if ((paymentId_ = next_) == 0) break;
        }

        // Update global accounting.
        accountedInterest = _uint112(accountedInterest_);
        domainStart       = _uint48(domainStart_);
        domainEnd         = _uint48(domainEnd_);
        issuanceRate      = issuanceRate_;
    }

    function _advancePaymentAccounting() internal {
        // If VPF is in the past, account for all previous issuance domains and get to current state.
        _accountPreviousDomains();

        // Accrue interest to the current timestamp.
        accountedInterest += _uint112(getAccruedInterest());
        domainStart        = _uint48(block.timestamp);
    }

    // TODO: Change return vars after management fees are properly implemented.
    function _handleClaimedFunds(address loan_, uint256 principal_, uint256 interest_) internal {
        principalOut -= _uint128(principal_);

        uint256 paymentId_   = paymentIdOf[loan_];
        uint256 platformFee_ = interest_ * payments[paymentId_].platformManagementFeeRate / HUNDRED_PERCENT;

        uint256 delegateFee_ = IPoolManagerLike(poolManager).hasSufficientCover()
            ? interest_ * payments[paymentId_].delegateManagementFeeRate / HUNDRED_PERCENT
            : 0;

        require(ERC20Helper.transfer(fundsAsset, pool, principal_ + interest_ - platformFee_ - delegateFee_), "LM:CL:POOL_TRANSFER");
        require(ERC20Helper.transfer(fundsAsset, mapleTreasury(), platformFee_),                              "LM:CL:MT_TRANSFER");
        require(delegateFee_ == 0 || ERC20Helper.transfer(fundsAsset, poolDelegate(), delegateFee_),          "LM:CL:PD_TRANSFER");
    }

    function _getLiquidationInfoAmounts(address loan_, PaymentInfo memory paymentInfo_, bool isLate_)
        internal view returns (
            uint256 netInterest_,
            uint256 netLateInterest_,
            uint256 platformManagementFee_,
            uint256 platformServiceFee_
        )
    {
        // Calculate the accrued interest on the payment using IR to capture rounding errors.
        // Accrue the interest only up to the current time if the payment due date has not been reached yet.
        netInterest_ = _getPaymentAccruedInterest({
            startTime_:           paymentInfo_.startDate,
            endTime_:             isLate_ ? paymentInfo_.paymentDueDate : block.timestamp,
            paymentIssuanceRate_: paymentInfo_.issuanceRate,
            refinanceInterest_:   paymentInfo_.refinanceInterest
        });

        ( , uint256[3] memory grossInterest_, uint256[2] memory serviceFees_ ) = ILoanLike(loan_).getNextPaymentDetailedBreakdown();

        uint256 grossPaymentInterest_ = grossInterest_[0];
        uint256 grossLateInterest_    = grossInterest_[1];

        // Calculate the platform management and service fees.
        platformManagementFee_ = (grossPaymentInterest_ + grossLateInterest_) * paymentInfo_.platformManagementFeeRate / HUNDRED_PERCENT;
        platformServiceFee_    = serviceFees_[1];

        // Scale the fees down if the default was triggered prematurely.
        if (!isLate_) {
            platformManagementFee_ = _getAccruedAmount(platformManagementFee_, paymentInfo_.startDate, paymentInfo_.paymentDueDate, block.timestamp);
            platformServiceFee_    = _getAccruedAmount(platformServiceFee_,    paymentInfo_.startDate, paymentInfo_.paymentDueDate, block.timestamp);
        }

        // Calculate the late interest if a late payment was made.
        if (isLate_) {
            netLateInterest_ = _getNetInterest(grossLateInterest_, paymentInfo_.platformManagementFeeRate + paymentInfo_.delegateManagementFeeRate);
        }
    }

    function _getPaymentAccruedInterest(uint256 startTime_, uint256 endTime_, uint256 paymentIssuanceRate_, uint256 refinanceInterest_) internal pure returns (uint256 accruedInterest_) {
        accruedInterest_ = (endTime_ - startTime_) * paymentIssuanceRate_ / PRECISION + refinanceInterest_;
    }

    function _getAccruedAmount(uint256 totalAccruingAmount_, uint256 startTime_, uint256 endTime_, uint256 currentTime_) internal pure returns (uint256 accruedAmount_) {
        accruedAmount_ = totalAccruingAmount_ * (currentTime_ - startTime_) / (endTime_ - startTime_);
    }

    // TODO: Rename function to indicate that it can happen on refinance as well.
    // TODO: make paymentId based.
    function _recognizePayment(address loan_) internal returns (uint256 issuanceRate_) {
        // TODO: struct memory/storage.stack fix.
        uint256 paymentId_              = paymentIdOf[loan_];
        PaymentInfo memory paymentInfo_ = payments[paymentId_];

        _removePaymentFromList(paymentId_);

        issuanceRate_ = paymentInfo_.issuanceRate;

        // If the amount of interest claimed is greater than the amount accounted for, set to zero.
        // Discrepancy between accounted and actual is always captured by balance change in the pool from the claimed interest.
        uint256 paymentAccruedInterest_ =
            block.timestamp <= paymentInfo_.paymentDueDate  // TODO: Investigate underflow and change to < again if possible.
                ? (block.timestamp - paymentInfo_.startDate) * issuanceRate_ / PRECISION
                : paymentInfo_.incomingNetInterest;

        // Add any interest owed prior to a refinance and reduce AUM accordingly.
        accountedInterest -= _uint112(paymentAccruedInterest_ + paymentInfo_.refinanceInterest);

        // PaymentInfo is deleted, because the payment has been fully recognized in the pool accounting, and will never be used again.
        delete paymentIdOf[loan_];
        delete payments[paymentId_];
    }

    function _recognizePaymentOfLoanInDefaultWarning(address loan_) internal {
        uint256 paymentId_ = paymentIdOf[loan_];

        _revertDefaultWarning(loan_);

        delete paymentIdOf[loan_];
        delete payments[paymentId_];
    }

    function _revertDefaultWarning(address loan_) internal {
        LiquidationInfo memory liquidationInfo_ = liquidationInfo[loan_];

        accountedInterest -= _uint112(liquidationInfo_.interest);
        unrealizedLosses  -= _uint128(liquidationInfo_.principal + liquidationInfo_.interest);

        delete liquidationInfo[loan_];
    }

    function _queueNextPayment(address loan_, uint256 startDate_, uint256 nextPaymentDueDate_) internal returns (uint256 newRate_) {
        uint256 platformManagementFeeRate_ = IMapleGlobalsLike(globals()).platformManagementFeeRate(poolManager);
        uint256 delegateManagementFeeRate_ = IPoolManagerLike(poolManager).delegateManagementFeeRate();
        uint256 managementFeeRate_         = platformManagementFeeRate_ + delegateManagementFeeRate_;

        // NOTE: If combined fee is greater than 100%, then cap delegate fee and clamp management fee.
        if (managementFeeRate_ > HUNDRED_PERCENT) {
            delegateManagementFeeRate_ = HUNDRED_PERCENT - platformManagementFeeRate_;
            managementFeeRate_         = HUNDRED_PERCENT;
        }

        ( , uint256[3] memory interest_, )  = ILoanLike(loan_).getNextPaymentDetailedBreakdown();

        uint256 netInterest_          = _getNetInterest(interest_[0], managementFeeRate_);
        uint256 netRefinanceInterest_ = _getNetInterest(interest_[2], managementFeeRate_);

        newRate_ = (netInterest_ * PRECISION) / (nextPaymentDueDate_ - startDate_);

        // Add the payment to the sorted list, making sure to take the effective start date (and not the current block timestamp).
        payments[
            paymentIdOf[loan_] = _addPaymentToList(_uint48(nextPaymentDueDate_))
        ] = PaymentInfo({
            platformManagementFeeRate: _uint24(platformManagementFeeRate_),
            delegateManagementFeeRate: _uint24(delegateManagementFeeRate_),
            startDate:                 _uint48(startDate_),
            paymentDueDate:            _uint48(nextPaymentDueDate_),
            incomingNetInterest:       _uint128(netInterest_),
            refinanceInterest:         _uint128(netRefinanceInterest_),
            issuanceRate:              newRate_
        });

        // Update the accounted interest to reflect what is present in the loan.
        accountedInterest += _uint112(netRefinanceInterest_);
    }

    function _updateDomainEnd() internal {
        // If there are no more payments in the list, set domain end to block.timestamp.
        // Otherwise, set it to the next upcoming payment.
        if (paymentWithEarliestDueDate == 0) {
            domainEnd = _uint48(block.timestamp);
        } else {
            domainEnd = payments[paymentWithEarliestDueDate].paymentDueDate;
        }
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function assetsUnderManagement() public view virtual override returns (uint256 assetsUnderManagement_) {
        assetsUnderManagement_ = principalOut + accountedInterest + getAccruedInterest();
    }

    function factory() external view override returns (address factory_) {
        factory_ = _factory();
    }

    function getAccruedInterest() public view override returns (uint256 accruedInterest_) {
        uint256 issuanceRate_ = issuanceRate;

        if (issuanceRate_ == 0) return uint256(0);

        // If before domain end, use current timestamp.
        accruedInterest_ = issuanceRate_ * (_min(block.timestamp, domainEnd) - domainStart) / PRECISION;
    }

    function getExpectedAmount(address collateralAsset_, uint256 swapAmount_) public view override returns (uint256 returnAmount_) {
        address globals_ = globals();

        uint8 collateralAssetDecimals_ = IERC20Like(collateralAsset_).decimals();

        uint256 oracleAmount =
            swapAmount_
                * IMapleGlobalsLike(globals_).getLatestPrice(collateralAsset_)  // Convert from `fromAsset` value.
                * uint256(10) ** uint256(IERC20Like(fundsAsset).decimals())     // Convert to `toAsset` decimal precision.
                * (HUNDRED_PERCENT - allowedSlippageFor[collateralAsset_])      // Multiply by allowed slippage basis points
                / IMapleGlobalsLike(globals_).getLatestPrice(fundsAsset)        // Convert to `toAsset` value.
                / uint256(10) ** uint256(collateralAssetDecimals_)              // Convert from `fromAsset` decimal precision.
                / HUNDRED_PERCENT;                                              // Divide basis points for slippage.

        // TODO: Document precision of minRatioFor is decimal representation of min ratio in fundsAsset decimal precision.
        uint256 minRatioAmount = (swapAmount_ * minRatioFor[collateralAsset_]) / (uint256(10) ** collateralAssetDecimals_);

        returnAmount_ = oracleAmount > minRatioAmount ? oracleAmount : minRatioAmount;
    }

    function globals() public view override returns (address globals_) {
        globals_ = IPoolManagerLike(poolManager).globals();
    }

    function governor() public view override returns (address governor_) {
        governor_ = IMapleGlobalsLike(globals()).governor();
    }

    function implementation() external view override returns (address implementation_) {
        implementation_ = _implementation();
    }

    function isLiquidationActive(address loan_) public view override returns (bool isActive_) {
        address liquidatorAddress_ = liquidationInfo[loan_].liquidator;

        // TODO: Investigate dust collateralAsset will ensure `isLiquidationActive` is always true.
        isActive_ = (liquidatorAddress_ != address(0)) && (IERC20Like(ILoanLike(loan_).collateralAsset()).balanceOf(liquidatorAddress_) != uint256(0));
    }

    function poolDelegate() public view override returns (address poolDelegate_) {
        poolDelegate_ = IPoolManagerLike(poolManager).poolDelegate();
    }

    function mapleTreasury() public view override returns (address treasury_) {
        treasury_ = IMapleGlobalsLike(globals()).mapleTreasury();
    }

    /*********************************/
    /*** Internal Helper Functions ***/
    /*********************************/

    function _getNetInterest(uint256 interest_, uint256 feeRate_) internal pure returns (uint256 netInterest_) {
        netInterest_ = interest_ * (HUNDRED_PERCENT - feeRate_) / HUNDRED_PERCENT;
    }

    function _max(uint256 a_, uint256 b_) internal pure returns (uint256 maximum_) {
        maximum_ = a_ > b_ ? a_ : b_;
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256 minimum_) {
        minimum_ = a_ < b_ ? a_ : b_;
    }

    function _uint24(uint256 input_) internal pure returns (uint24 output_) {
        require(input_ <= type(uint24).max, "LM:UINT24_CAST_OOB");
        output_ = uint24(input_);
    }

    function _uint48(uint256 input_) internal pure returns (uint32 output_) {
        require(input_ <= type(uint32).max, "LM:UINT32_CAST_OOB");
        output_ = uint32(input_);
    }

    function _uint96(uint256 input_) internal pure returns (uint96 output_) {
        require(input_ <= type(uint96).max, "LM:UINT96_CAST_OOB");
        output_ = uint96(input_);
    }

    function _uint112(uint256 input_) internal pure returns (uint112 output_) {
        require(input_ <= type(uint112).max, "LM:UINT112_CAST_OOB");
        output_ = uint112(input_);
    }

    function _uint120(uint256 input_) internal pure returns (uint120 output_) {
        require(input_ <= type(uint120).max, "LM:UINT120_CAST_OOB");
        output_ = uint120(input_);
    }

    function _uint128(uint256 input_) internal pure returns (uint128 output_) {
        require(input_ <= type(uint128).max, "LM:UINT128_CAST_OOB");
        output_ = uint128(input_);
    }

}
