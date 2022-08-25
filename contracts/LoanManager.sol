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
        require(msg.sender == poolManager,      "LM:SAS:NOT_POOL_MANAGER");
        require(allowedSlippage_ <= HUNDRED_PERCENT, "LM:SAS:INVALID_SLIPPAGE");

        emit AllowedSlippageSet(collateralAsset_, allowedSlippageFor[collateralAsset_] = allowedSlippage_);
    }

    function setMinRatio(address collateralAsset_, uint256 minRatio_) external override {
        require(msg.sender == poolManager, "LM:SMR:NOT_POOL_MANAGER");
        emit MinRatioSet(collateralAsset_, minRatioFor[collateralAsset_] = minRatio_);
    }

    /*********************************/
    /*** Loan Accounting Functions ***/
    /*********************************/

    function acceptNewTerms(address loan_, address refinancer_, uint256 deadline_, bytes[] calldata calls_) external override {
        require(msg.sender == poolManager, "LM:ANT:NOT_ADMIN");

        _advanceLoanAccounting();

        // Remove loan from sorted list and get relevant previous parameters.
        uint256 previousRate_ = _recognizeLoanPayment(loan_);

        uint256 previousPrincipal = ILoanLike(loan_).principal();

        // Perform the refinancing, updating the loan state.
        ILoanLike(loan_).acceptNewTerms(refinancer_, deadline_, calls_);

        uint256 principal_ = ILoanLike(loan_).principal();

        if (principal_ > previousPrincipal) {
            principalOut += _uint128(principal_ - previousPrincipal);
        } else {
            principalOut -= _uint128(previousPrincipal - principal_);
        }

        uint256 newRate_ = _queueNextLoanPayment(loan_, block.timestamp, ILoanLike(loan_).nextPaymentDueDate());

        // The new vesting period finish is the maximum of the current earliest, if it does not exist set to
        // current timestamp to end vesting.
        // TODO: Investigate adding `_accountToEndOfLoan` logic
        domainEnd = loans[loanWithEarliestPaymentDueDate].paymentDueDate;

        // Update the vesting state an then set the new issuance rate take into account the cessation of the previous rate
        // and the commencement of the new rate for this loan.
        issuanceRate = _uint128(issuanceRate + newRate_ - previousRate_);

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
    }

    function claim(uint256 principal_, uint256 interest_, uint256 previousPaymentDueDate_, uint256 nextPaymentDueDate_) external override {
        require(loanIdOf[msg.sender] != 0, "LM:C:NOT_LOAN");

        _advanceLoanAccounting();

        // Claim loan and move funds into pool and to PM.
        _claimLoan(msg.sender, principal_, interest_);

        // Finalized the previous payment into the pool accounting.
        uint256 previousRate_;

        // TODO: Should we clear the flag in the loan and pass in a bool to this function, or call this during a default warning payment, then clear the flag in the loan after this call returns?
        if (!ILoanLike(msg.sender).isInDefaultWarning()) {
            previousRate_ = _recognizeLoanPayment(msg.sender);
        } else {
            // If we successfully claimed above, that means that the payment has been made through the default warning, and the loan did not default.
            // NOTE: Previous rate will always be 0, so we don't set it here.
            _recognizeDefaultWarningLoanPayment(msg.sender);
        }

        uint256 newRate_;

        // The next rate will be over the course of the remaining time, or the payment interval, whichever is longer.
        // In other words, if the previous payment was early, then the next payment will start accruing from now,
        // but if the previous payment was late, then we should have been accruing the next payment
        // from the moment the previous payment was due.
        uint256 nextStartDate_ = _min(block.timestamp, previousPaymentDueDate_);

        // If there is a next payment for this loan.
        if (nextPaymentDueDate_ != 0) {
            newRate_ = _queueNextLoanPayment(msg.sender, nextStartDate_, nextPaymentDueDate_);

            // If the current timestamp is greater than the resulting next payment due date, then the next payment must be
            // FULLY accounted for, and the loan must be removed from the sorted list.
            if (block.timestamp > nextPaymentDueDate_) {
                uint256 loanId_ = loanIdOf[msg.sender];

                ( uint256 accountedInterestIncrease_, ) = _accountToEndOfLoan(loanId_, loans[loanId_].issuanceRate, previousPaymentDueDate_, nextPaymentDueDate_);

                accountedInterest += _uint112(accountedInterestIncrease_);

                // `newRate_` always equals `issuanceRateReduction_`
                newRate_ = 0;
            }

            // If the current timestamp is greater than the previous payment due date, then the next payment must be
            // PARTIALLY accounted for, using the new loan's issuance rate and the time passed in the new interval.
            else if (block.timestamp > previousPaymentDueDate_) {
                accountedInterest += _uint112((block.timestamp - previousPaymentDueDate_) * newRate_ / PRECISION);
            }
        }

        // Update domainEnd to reflect the new sorted list state.
        domainEnd = loans[loanWithEarliestPaymentDueDate].paymentDueDate;

        // Update the vesting state an then set the new issuance rate take into account the cessation of the previous rate
        // and the commencement of the new rate for this loan.
        issuanceRate = issuanceRate + newRate_ - previousRate_;

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
    }

    function fund(address loanAddress_) external override {
        require(msg.sender == poolManager, "LM:F:NOT_POOL_MANAGER");

        _advanceLoanAccounting();

        ILoanLike(loanAddress_).fundLoan(address(this));

        uint256 newRate_ = _queueNextLoanPayment(loanAddress_, block.timestamp, ILoanLike(loanAddress_).nextPaymentDueDate());

        principalOut += _uint128(ILoanLike(loanAddress_).principal());
        issuanceRate += newRate_;
        domainEnd     = loans[loanWithEarliestPaymentDueDate].paymentDueDate;

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
    }

    /*************************/
    /*** Default Functions ***/
    /*************************/

    function removeDefaultWarning(address loan_, bool isCalledByGovernor_) external override {
        require(msg.sender == poolManager, "LM:RDW:NOT_PM");

        _advanceLoanAccounting();

        ILoanLike(loan_).removeDefaultWarning();

        uint24 loanId_ = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        // TODO: Storage is also read within _revertDefaultWarning function, so can be optimized. But the following reversion should be in this function (JG's opinion)
        if (liquidationInfo[loan_].triggeredByGovernor) require(isCalledByGovernor_, "LM:RDW:NOT_AUTHORIZED");

        _revertDefaultWarning(loan_);
        _addLoanToList(loanId_, loanInfo_);

        // Discretely update missing interest as if loan was always part of the list.
        accountedInterest += _uint112(_getLoanAccruedInterest(loanInfo_.startDate, domainStart, loanInfo_.issuanceRate, loanInfo_.refinanceInterest));
        issuanceRate      += loanInfo_.issuanceRate;

        domainEnd = loans[loanWithEarliestPaymentDueDate].paymentDueDate;

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);
    }

    // TODO: Ensure that the default warning can not be triggered after the payment due date.
    function triggerDefaultWarning(address loan_, bool isGovernor_) external override {
        require(msg.sender == poolManager, "LM:TDW:NOT_PM");

        _advanceLoanAccounting();

        uint256 principal_        = ILoanLike(loan_).principal();
        uint256 loanId_           = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        ( uint256 netInterest_, , uint256 platformManagementFee_, uint256 platformServiceFee_ ) = _getLiquidationInfoAmounts(loan_, loanInfo_, false);

        liquidationInfo[loan_] = LiquidationInfo({
            triggeredByGovernor: isGovernor_,
            principal:           _uint128(principal_),
            interest:            _uint120(netInterest_),
            lateInterest:        0,
            platformFees:        _uint96(platformManagementFee_ + platformServiceFee_),
            liquidator:          address(0)
        });

        issuanceRate     -= loanInfo_.issuanceRate;  // TODO: Is this supposed to be here?
        unrealizedLosses += _uint128(principal_ + netInterest_);

        _removeLoanFromList(loanInfo_.previous, loanInfo_.next, loanId_);
        _updateDomainEnd();

        ILoanLike(loan_).triggerDefaultWarning();

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);
    }

    // TODO: Reorder functions alphabetically.
    function finishCollateralLiquidation(address loan_) external override returns (uint256 remainingLosses_, uint256 platformFees_) {
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

        uint256 toTreasury_ = _min(recoveredFunds_, platformFees_);

        recoveredFunds_ -= toTreasury_;
        platformFees_   -= toTreasury_;

        uint256 toPool_ = _min(recoveredFunds_, remainingLosses_);

        recoveredFunds_  -= toPool_;
        remainingLosses_ -= toPool_;

        // Reduce principal out, since it has been accounted for in the liquidation.
        principalOut -= liquidationInfo_.principal;

        // Reduce accounted interest by the interest portion of the shortfall, as the loss has been realized, and therefore this interest has been accounted for.
        // Don't reduce by late interest, since we never account for this interest in the issuance rate, only via discrete updates.
        accountedInterest -= _uint112(liquidationInfo_.interest);

        // TODO: Confirm where overflow funds go.
        if (toTreasury_     != 0) ILiquidatorLike(liquidationInfo_.liquidator).pullFunds(fundsAsset, mapleTreasury(),             toTreasury_);
        if (toPool_         != 0) ILiquidatorLike(liquidationInfo_.liquidator).pullFunds(fundsAsset, pool,                        toPool_);
        if (recoveredFunds_ != 0) ILiquidatorLike(liquidationInfo_.liquidator).pullFunds(fundsAsset, ILoanLike(loan_).borrower(), recoveredFunds_);

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);

        delete liquidationInfo[loan_];
        delete loans[loanIdOf[loan_]];
        delete loanIdOf[loan_];
    }

    /// @dev Trigger Default on a loan
    function triggerCollateralLiquidation(address loan_) external override {
        require(msg.sender == poolManager, "LM:TCL:NOT_POOL_MANAGER");

        // Get loan info prior to advancing loan accounting, because that will set issuance rate to 0.
        uint24 loanId_           = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        _advanceLoanAccounting();

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
            ) = _getLiquidationInfoAmounts(loan_, loanInfo_, true);

            // Impair the loan with the default amount.
            // NOTE: Don't include fees in unrealized losses, because this is not to be passed onto the LPs. Only collateral and cover can cover the fees.
            unrealizedLosses += _uint128(principal_ + netInterest_ + netLateInterest_);

            // Loan Info is removed from actively accruing payments, because this function confirms that the payment will not be made and that it is recognized as a loss.
            _removeLoanFromList(loanInfo_.previous, loanInfo_.next, loanId_);

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
    /*** Internal Loan Sorting Functions ***/
    /***************************************/

    // TODO: Should domain end be set here to the end date of loanWithEarliestPaymentDueDate.
    function _addLoanToList(uint24 loanId_, LoanInfo memory loan_) internal {
        uint24 current = uint24(0);
        uint24 next    = loanWithEarliestPaymentDueDate;

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

    function _removeLoanFromList(uint24 previous_, uint24 next_, uint256 loanId_) internal {
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

    // Advance loans in previous domains to "catch up" to current state.
    function _accountToEndOfLoan(
        uint256 loanId_,
        uint256 issuanceRate_,
        uint256 intervalStart_,
        uint256 intervalEnd_
    )
        internal returns (uint256 accountedInterestIncrease_, uint256 issuanceRateReduction_)
    {
        LoanInfo memory loan_ = loans[loanId_];

        // Remove the loan from the linked list so the next loan can be used as the shortest timestamp.
        // NOTE: This keeps the loan accounting info intact so it can be accounted for when the payment is claimed.
        _removeLoanFromList(loan_.previous, loan_.next, loanId_);

        issuanceRateReduction_ = loan_.issuanceRate;

        // Update accounting between timestamps and set last updated to the domainEnd.
        // Reduce the issuanceRate for the loan.
        accountedInterestIncrease_ = (intervalEnd_ - intervalStart_) * issuanceRate_ / PRECISION;

        // Remove issuanceRate as it is deducted from global issuanceRate.
        loans[loanId_].issuanceRate = 0;
    }

    // TODO: Gas optimize
    function _accountPreviousDomains() internal {
        uint256 domainEnd_ = domainEnd;

        if (domainEnd_ == 0 || block.timestamp <= domainEnd_) return;

        uint256 loanId_ = loanWithEarliestPaymentDueDate;

        // Cache variables for looping.
        uint256 accountedInterest_ = accountedInterest;
        uint256 domainStart_       = domainStart;
        uint256 issuanceRate_      = issuanceRate;

        // Advance loans in previous domains to "catch up" to current state.
        while (block.timestamp > domainEnd_) {
            ( uint256 accountedInterestIncrease_, uint256 issuanceRateReduction_ ) = _accountToEndOfLoan(loanId_, issuanceRate_, domainStart_, domainEnd_);
            accountedInterest_ += accountedInterestIncrease_;
            issuanceRate_      -= issuanceRateReduction_;

            domainStart_ = domainEnd_;
            domainEnd_   = loans[loanWithEarliestPaymentDueDate].paymentDueDate;

            // If the end of the list has been reached, exit the loop.
            if ((loanId_ = loans[loanId_].next) == 0) break;
        }

        // Update global accounting.
        accountedInterest = _uint112(accountedInterest_);
        domainStart       = _uint48(domainStart_);
        domainEnd         = _uint48(domainEnd_);
        issuanceRate      = issuanceRate_;
    }

    function _advanceLoanAccounting() internal {
        // If VPF is in the past, account for all previous issuance domains and get to current state.
        _accountPreviousDomains();

        // Accrue interest to the current timestamp.
        accountedInterest += _uint112(getAccruedInterest());
        domainStart        = _uint48(block.timestamp);
    }

    // TODO: Change return vars after management fees are properly implemented.
    function _claimLoan(address loanAddress_, uint256 principal_, uint256 interest_) internal {
        principalOut -= _uint128(principal_);

        uint256 loanId_ = loanIdOf[loanAddress_];

        bool hasSufficientCover_ = IPoolManagerLike(poolManager).hasSufficientCover();

        uint256 platformFee_ = interest_ * loans[loanId_].platformManagementFeeRate / HUNDRED_PERCENT;

        uint256 delegateFee_ = hasSufficientCover_ ? interest_ * loans[loanId_].delegateManagementFeeRate / HUNDRED_PERCENT : 0;

        require(ERC20Helper.transfer(fundsAsset, pool, principal_ + interest_ - platformFee_ - delegateFee_), "LM:CL:POOL_TRANSFER");

        require(ERC20Helper.transfer(fundsAsset, mapleTreasury(), platformFee_), "LM:CL:MT_TRANSFER");

        require(!hasSufficientCover_ || ERC20Helper.transfer(fundsAsset, poolDelegate(), delegateFee_), "LM:CL:PD_TRANSFER");
    }

    function _getLiquidationInfoAmounts(address loan_, LoanInfo memory loanInfo_, bool isLate_)
        internal view returns (
            uint256 netInterest_,
            uint256 netLateInterest_,
            uint256 platformManagementFee_,
            uint256 platformServiceFee_
        )
    {
        // Calculate the accrued interest on the loan using IR to capture rounding errors.
        // Accrue the interest only up to the current time if the payment due date has not been reached yet.
        netInterest_ = _getLoanAccruedInterest({
            startTime_:         loanInfo_.startDate,
            endTime_:           isLate_ ? loanInfo_.paymentDueDate : block.timestamp,
            loanIssuanceRate_:  loanInfo_.issuanceRate,
            refinanceInterest_: loanInfo_.refinanceInterest
        });

        ( , uint256[3] memory grossInterest_, uint256[2] memory serviceFees_ ) = ILoanLike(loan_).getNextPaymentDetailedBreakdown();

        uint256 grossPaymentInterest_ = grossInterest_[0];
        uint256 grossLateInterest_    = grossInterest_[1];

        // Calculate the platform management and service fees.
        platformManagementFee_ = (grossPaymentInterest_ + grossLateInterest_) * loanInfo_.platformManagementFeeRate / HUNDRED_PERCENT;
        platformServiceFee_    = serviceFees_[1];

        // Scale the fees down if the default was triggered prematurely.
        if (!isLate_) {
            platformManagementFee_ = _getAccruedAmount(platformManagementFee_, loanInfo_.startDate, loanInfo_.paymentDueDate, block.timestamp);
            platformServiceFee_    = _getAccruedAmount(platformServiceFee_,    loanInfo_.startDate, loanInfo_.paymentDueDate, block.timestamp);
        }

        // Calculate the late interest if a late payment was made.
        if (isLate_) {
            netLateInterest_ = _getNetInterest(grossLateInterest_, loanInfo_.platformManagementFeeRate + loanInfo_.delegateManagementFeeRate);
        }
    }

    function _getLoanAccruedInterest(uint256 startTime_, uint256 endTime_, uint256 loanIssuanceRate_, uint256 refinanceInterest_) internal pure returns (uint256 accruedInterest_) {
        accruedInterest_ = (endTime_ - startTime_) * loanIssuanceRate_ / PRECISION + refinanceInterest_;
    }

    function _getAccruedAmount(uint256 totalAccruingAmount_, uint256 startTime_, uint256 endTime_, uint256 currentTime_) internal pure returns (uint256 accruedAmount_) {
        accruedAmount_ = totalAccruingAmount_ * (currentTime_ - startTime_) / (endTime_ - startTime_);
    }

    // TODO: Rename function to indicate that it can happen on refinance as well.
    function _recognizeLoanPayment(address loan_) internal returns (uint256 issuanceRate_) {
        uint256 loanId_           = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        _removeLoanFromList(loanInfo_.previous, loanInfo_.next, loanId_);

        issuanceRate_ = loanInfo_.issuanceRate;

        // If the amount of interest claimed is greater than the amount accounted for, set to zero.
        // Discrepancy between accounted and actual is always captured by balance change in the pool from the claimed interest.
        uint256 loanAccruedInterest_ =
            block.timestamp <= loanInfo_.paymentDueDate  // TODO: Investigate underflow and change to < again if possible.
                ? (block.timestamp - loanInfo_.startDate) * loanInfo_.issuanceRate / PRECISION
                : loanInfo_.incomingNetInterest;

        // Add any interest owed prior to a refinance and reduce AUM accordingly.
        accountedInterest -= _uint112(loanAccruedInterest_ + loanInfo_.refinanceInterest);

        // Loan Info is deleted, because the payment has been fully recognized in the pool accounting, and will never be used again.
        delete loanIdOf[loan_];
        delete loans[loanId_];
    }

    function _recognizeDefaultWarningLoanPayment(address loan_) internal {
        uint256 loanId_ = loanIdOf[loan_];

        _revertDefaultWarning(loan_);

        delete loanIdOf[loan_];
        delete loans[loanId_];
    }

    function _revertDefaultWarning(address loan_) internal {
        LiquidationInfo memory liquidationInfo_ = liquidationInfo[loan_];

        accountedInterest -= _uint112(liquidationInfo_.interest);
        unrealizedLosses  -= _uint128(liquidationInfo_.principal + liquidationInfo_.interest);

        delete liquidationInfo[loan_];
    }

    function _queueNextLoanPayment(address loan_, uint256 startDate_, uint256 nextPaymentDueDate_) internal returns (uint256 newRate_) {
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

        // Add the LoanInfo to the sorted list, making sure to take the effective start date (and not the current block timestamp).
        uint24 loanId_ = loanIdOf[loan_] = ++loanCounter;

        _addLoanToList(loanId_, LoanInfo({
            // Previous and next will be overridden within _addLoan function.
            previous:                  uint24(0),
            next:                      uint24(0),
            platformManagementFeeRate: _uint24(platformManagementFeeRate_),
            delegateManagementFeeRate: _uint24(delegateManagementFeeRate_),
            startDate:                 _uint48(startDate_),
            paymentDueDate:            _uint48(nextPaymentDueDate_),
            incomingNetInterest:       _uint128(netInterest_),
            refinanceInterest:         _uint128(netRefinanceInterest_),
            issuanceRate:              newRate_
        }));

        // Update the accounted interest to reflect what is present in the loan.
        accountedInterest += _uint112(netRefinanceInterest_);
    }

    function _updateDomainEnd() internal {
        // If there are no more payments in the list, set domain end to block.timestamp.
        // Otherwise, set it to the next upcoming payment.
        if (loanWithEarliestPaymentDueDate == 0) {
            domainEnd = _uint48(block.timestamp);
        } else {
            domainEnd = loans[loanWithEarliestPaymentDueDate].paymentDueDate;
        }
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function assetsUnderManagement() public view virtual override returns (uint256 assetsUnderManagement_) {
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

    function getExpectedAmount(address collateralAsset_, uint256 swapAmount_) public view override returns (uint256 returnAmount_) {
        address globals_ = globals();

        uint8 collateralAssetDecimals = IERC20Like(collateralAsset_).decimals();

        uint256 oracleAmount =
            swapAmount_
                * IMapleGlobalsLike(globals_).getLatestPrice(collateralAsset_)  // Convert from `fromAsset` value.
                * uint256(10) ** uint256(IERC20Like(fundsAsset).decimals())     // Convert to `toAsset` decimal precision.
                * (HUNDRED_PERCENT - allowedSlippageFor[collateralAsset_])      // Multiply by allowed slippage basis points
                / IMapleGlobalsLike(globals_).getLatestPrice(fundsAsset)        // Convert to `toAsset` value.
                / uint256(10) ** uint256(collateralAssetDecimals)               // Convert from `fromAsset` decimal precision.
                / HUNDRED_PERCENT;                                              // Divide basis points for slippage.

        // TODO: Document precision of minRatioFor is decimal representation of min ratio in fundsAsset decimal precision.
        uint256 minRatioAmount = (swapAmount_ * minRatioFor[collateralAsset_]) / (uint256(10) ** collateralAssetDecimals);

        return oracleAmount > minRatioAmount ? oracleAmount : minRatioAmount;
    }

    function globals() public view override returns (address globals_) {
        return IPoolManagerLike(poolManager).globals();
    }

    function governor() public view override returns (address governor_) {
        governor_ = IMapleGlobalsLike(globals()).governor();
    }

    function implementation() external view override returns (address implementation_) {
        return _implementation();
    }

    function isLiquidationActive(address loan_) public view override returns (bool isActive_) {
        address liquidatorAddress = liquidationInfo[loan_].liquidator;

        return (liquidatorAddress != address(0)) && (IERC20Like(ILoanLike(loan_).collateralAsset()).balanceOf(liquidatorAddress) != uint256(0));
    }

    function poolDelegate() public view override returns (address poolDelegate_) {
        return IPoolManagerLike(poolManager).poolDelegate();
    }

    function mapleTreasury() public view override returns (address treasury_) {
        return IMapleGlobalsLike(globals()).mapleTreasury();
    }

    /*********************************/
    /*** Internal Helper Functions ***/
    /*********************************/

    function _getNetInterest(uint256 interest_, uint256 feeRate_) internal pure returns (uint256 netInterest_) {
        netInterest_ = interest_ * (HUNDRED_PERCENT - feeRate_) / HUNDRED_PERCENT;
    }

    function _max(uint256 a_, uint256 b_) internal pure returns (uint256 maximum_) {
        return a_ > b_ ? a_ : b_;
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256 minimum_) {
        return a_ < b_ ? a_ : b_;
    }

    function _uint24(uint256 value_) internal pure returns (uint24 castedValue_) {
        require(value_ <= type(uint24).max, "LM:UINT24_CAST_OOB");
        castedValue_ = uint24(value_);
    }

    function _uint48(uint256 value_) internal pure returns (uint32 castedValue_) {
        require(value_ <= type(uint32).max, "LM:UINT32_CAST_OOB");
        castedValue_ = uint32(value_);
    }

    function _uint96(uint256 value_) internal pure returns (uint96 castedValue_) {
        require(value_ <= type(uint96).max, "LM:UINT96_CAST_OOB");
        castedValue_ = uint96(value_);
    }

    function _uint112(uint256 value_) internal pure returns (uint112 castedValue_) {
        require(value_ <= type(uint112).max, "LM:UINT112_CAST_OOB");
        castedValue_ = uint112(value_);
    }

    function _uint120(uint256 value_) internal pure returns (uint120 castedValue_) {
        require(value_ <= type(uint120).max, "LM:UINT120_CAST_OOB");
        castedValue_ = uint120(value_);
    }

    function _uint128(uint256 value_) internal pure returns (uint128 castedValue_) {
        require(value_ <= type(uint128).max, "LM:UINT128_CAST_OOB");
        castedValue_ = uint128(value_);
    }

}
