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
    IMapleGlobalsLike,
    IMapleLoanFeeManagerLike,
    IPoolManagerLike
} from "./interfaces/Interfaces.sol";

import { LoanManagerStorage } from "./proxy/LoanManagerStorage.sol";

contract LoanManager is ILoanManager, MapleProxiedInternals, LoanManagerStorage {

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
        require(allowedSlippage_ <= SCALED_ONE, "LM:SAS:INVALID_SLIPPAGE");

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
            principalOut += principal_ - previousPrincipal;
        } else {
            principalOut -= previousPrincipal - principal_;
        }

        uint256 newRate_ = _queueNextLoanPayment(loan_, block.timestamp, ILoanLike(loan_).nextPaymentDueDate());

        // The new vesting period finish is the maximum of the current earliest, if it does not exist set to
        // current timestamp to end vesting.
        // TODO: Investigate adding `_accountToEndOfLoan` logic
        domainEnd = loans[loanWithEarliestPaymentDueDate].paymentDueDate;

        // Update the vesting state an then set the new issuance rate take into account the cessation of the previous rate
        // and the commencement of the new rate for this loan.
        issuanceRate = issuanceRate + newRate_ - previousRate_;

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

                accountedInterest += accountedInterestIncrease_;

                // `newRate_` always equals `issuanceRateReduction_`
                newRate_ = 0;
            }

            // If the current timestamp is greater than the previous payment due date, then the next payment must be
            // PARTIALLY accounted for, using the new loan's issuance rate and the time passed in the new interval.
            else if (block.timestamp > previousPaymentDueDate_) {
                accountedInterest += (block.timestamp - previousPaymentDueDate_) * newRate_ / PRECISION;
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

        principalOut += ILoanLike(loanAddress_).principal();
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

        uint256 loanId_ = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        // TODO: Storage is also read within _revertDefaultWarning function, so can be optimized. But the following reversion should be in this function (JG's opinion)
        if (liquidationInfo[loan_].triggeredByGovernor) require(isCalledByGovernor_, "LM:RDW:NOT_AUTHORIZED");

        _revertDefaultWarning(loan_);

        _addLoanToList(loanId_, loanInfo_);

        // Discretely update missing interest as if loan was always part of the list.
        accountedInterest += _getLoanAccruedInterest(loanInfo_.startDate, domainStart, loanInfo_.issuanceRate, loanInfo_.refinanceInterest);
        issuanceRate      += loanInfo_.issuanceRate;

        domainEnd = loans[loanWithEarliestPaymentDueDate].paymentDueDate;

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);
    }

    function triggerDefaultWarning(address loan_, uint256 newPaymentDueDate_, bool isGovernor_) external override {
        require(msg.sender == poolManager, "LM:TDW:NOT_PM");

        _advanceLoanAccounting();

        ( , uint256 grossInterest_, ) = ILoanLike(loan_).getNextPaymentBreakdown();

        ILoanLike(loan_).triggerDefaultWarning(newPaymentDueDate_);

        // Get necessary data structures.
        uint256 loanId_           = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        // Remove payment's issuance rate from the LM issuance rate.
        issuanceRate -= loanInfo_.issuanceRate;

        // NOTE: Even though `nextPaymentDueDate` could be set to after `block.timestamp`, we still stop the interest accrual.
        // NOTE: `platformManagementFee` is calculated from gross interest as to not use the `delegateManagementFeeRate` to save gas.
        // Principal + payment accrued interest + refinance interest.
        uint256 principal_          = ILoanLike(loan_).principal();
        uint256 platformServiceFee_ = IMapleLoanFeeManagerLike(ILoanLike(loan_).feeManager()).platformServiceFee(loan_);

        uint256 accruedGrossInterest_         = _getAccruedAmount(grossInterest_,                loanInfo_.startDate, loanInfo_.paymentDueDate, block.timestamp);
        uint256 accruedNetInterest_           = _getAccruedAmount(loanInfo_.incomingNetInterest, loanInfo_.startDate, loanInfo_.paymentDueDate, block.timestamp);
        uint256 accruedPlatformServiceFee_    = _getAccruedAmount(platformServiceFee_,           loanInfo_.startDate, loanInfo_.paymentDueDate, block.timestamp);
        uint256 accruedPlatformManagementFee_ = accruedGrossInterest_ * loanInfo_.platformManagementFeeRate / SCALED_ONE;

        liquidationInfo[loan_] = LiquidationInfo({
            principal:           principal_,
            interest:            accruedNetInterest_,
            platformFees:        accruedPlatformManagementFee_ + accruedPlatformServiceFee_,
            liquidator:          address(0),  // This will be set during triggerCollateralLiquidation.
            triggeredByGovernor: isGovernor_
        });

        unrealizedLosses += (principal_ + accruedNetInterest_);

        // Update `loanInfo_` with new values reflecting a loan that is expected to default.
        _removeLoanFromList(loanInfo_.previous, loanInfo_.next, loanId_);

        // NOTE: `loanInfo_` state is not updated in case the default warning must be removed and previous state must be restored.

        // If there are no more payments in the list, set domain end to block.timestamp (which equals `domainStart`, from `_advanceLoanAccounting`)
        // Otherwise, set it to the next upcoming payment.
        if (loanWithEarliestPaymentDueDate == 0) {
            domainEnd = block.timestamp;
        } else {
            domainEnd = loans[loanWithEarliestPaymentDueDate].paymentDueDate;
        }

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);
    }

    // TODO: Reorder functions alphabetically.
    function finishCollateralLiquidation(address loan_) external override returns (uint256 remainingLosses_, uint256 platformFees_) {
        require(msg.sender == poolManager,   "LM:FCL:NOT_POOL_MANAGER");
        require(!isLiquidationActive(loan_), "LM:FCL:LIQ_STILL_ACTIVE");

        // Philosophy for this function is triggerCollateralLiquidation should figure out all the details,
        // and finish should use that info and execute the liquidation and accounting updates.
        uint256 loanId_ = loanIdOf[loan_];

        uint256 recoveredFunds_ = IERC20Like(fundsAsset).balanceOf(address(this));

        LiquidationInfo memory liquidationInfo_ = liquidationInfo[loan_];

        remainingLosses_ = liquidationInfo_.principal + liquidationInfo_.interest;
        platformFees_    = liquidationInfo_.platformFees;

        // Realize the loss following the liquidation.
        unrealizedLosses -= remainingLosses_;

        uint256 toTreasury_ = _min(recoveredFunds_, platformFees_);

        recoveredFunds_ -= toTreasury_;
        platformFees_   -= toTreasury_;

        uint256 toPool_ = _min(recoveredFunds_, remainingLosses_);

        recoveredFunds_  -= toPool_;
        remainingLosses_ -= toPool_;

        // Reduce principal out, since it has been accounted for in the liquidation.
        principalOut -= liquidationInfo_.principal;

        // Reduce accounted interest by the interest portion of the shortfall, as the loss has been realized, and therefore this interest has been accounted for.
        accountedInterest -= liquidationInfo_.interest;

        delete liquidationInfo[loan_];
        delete loanIdOf[loan_];
        delete loans[loanId_];

        require(toTreasury_     == 0 || ERC20Helper.transfer(fundsAsset, IMapleGlobalsLike(globals()).mapleTreasury(), toTreasury_), "LM:FCL:MT_TRANSFER");
        require(toPool_         == 0 || ERC20Helper.transfer(fundsAsset, pool, toPool_),                                             "LM:FCL:POOL_TRANSFER");
        require(recoveredFunds_ == 0 || ERC20Helper.transfer(fundsAsset, ILoanLike(loan_).borrower(), recoveredFunds_),              "LM:FCL:B_TRANSFER");

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);
    }

    /// @dev Trigger Default on a loan
    function triggerCollateralLiquidation(address loan_) external override {
        require(msg.sender == poolManager, "LM:TCL:NOT_POOL_MANAGER");

        _advanceLoanAccounting();

        ILoanLike loan            = ILoanLike(loan_);
        uint256 loanId_           = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        ( uint256 collateralAssetAmount, uint256 fundsAssetAmount ) = loan.repossess(address(this));

        address collateralAsset = loan.collateralAsset();

        address liquidator_;

        if (collateralAsset != fundsAsset && collateralAssetAmount != uint256(0)) {
            liquidator_ = address(
                new Liquidator({
                    owner_:           address(this),
                    collateralAsset_: collateralAsset,
                    fundsAsset_:      fundsAsset,
                    auctioneer_:      address(this),
                    destination_:     address(this),
                    globals_:         globals()
                })
            );

            require(ERC20Helper.transfer(collateralAsset,   liquidator_, collateralAssetAmount), "LM:TD:CA_TRANSFER");
            require(ERC20Helper.transfer(loan.fundsAsset(), liquidator_, fundsAssetAmount),      "LM:TD:FA_TRANSFER");
        }

        if (!loan.isInDefaultWarning()) {
            uint256 principal_             = ILoanLike(loan_).principal();
            ( , uint256 grossInterest_, )  = ILoanLike(loan_).getNextPaymentBreakdown();
            uint256 netInterest_           = _getNetInterest(grossInterest_, loanInfo_.delegateManagementFeeRate + loanInfo_.platformManagementFeeRate);
            uint256 platformManagementFee_ = grossInterest_ * loanInfo_.platformManagementFeeRate / SCALED_ONE;
            uint256 platformServiceFee_    = IMapleLoanFeeManagerLike(ILoanLike(loan_).feeManager()).platformServiceFee(loan_);

            // Don't include fees in unrealized losses, because this is not to be passed onto the LPs. Only collateral and cover can cover the fees.
            unrealizedLosses += principal_ + netInterest_;

            // Loan Info is removed from actively accruing payments, because this function confirms that the payment will not be made and that it is recognized as a loss.
            _removeLoanFromList(loanInfo_.previous, loanInfo_.next, loanId_);

            liquidationInfo[loan_] = LiquidationInfo({
                principal:           principal_,
                interest:            netInterest_,
                platformFees:        platformManagementFee_ + platformServiceFee_,
                liquidator:          liquidator_,
                triggeredByGovernor: false
            });
        } else {
            // Liquidation info was already set in trigger default warning.
            liquidationInfo[loan_].liquidator = liquidator_;
        }

        // If there are no more payments in the list, set domain end to block.timestamp (which equals `domainStart`, from `_advanceLoanAccounting`)
        // Otherwise, set it to the next upcoming payment.
        if (loanWithEarliestPaymentDueDate == 0) {
            domainEnd = block.timestamp;
        } else {
            domainEnd = loans[loanWithEarliestPaymentDueDate].paymentDueDate;
        }

        emit IssuanceParamsUpdated(principalOut, domainStart, domainEnd, issuanceRate, accountedInterest);  // TODO: Gas optimize
        emit UnrealizedLossesUpdated(unrealizedLosses);

        // TODO: need to clean up loan contract accounting, since it has defaulted.
    }

    /***************************************/
    /*** Internal Loan Sorting Functions ***/
    /***************************************/

    // TODO: Should domain end be set here to the end date of loanWithEarliestPaymentDueDate.
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
        accountedInterest = accountedInterest_;
        domainStart       = domainStart_;
        domainEnd         = domainEnd_;
        issuanceRate      = issuanceRate_;
    }

    function _advanceLoanAccounting() internal {
        // If VPF is in the past, account for all previous issuance domains and get to current state.
        _accountPreviousDomains();

        // Accrue interest to the current timestamp.
        accountedInterest += getAccruedInterest();
        domainStart        = block.timestamp;
    }

    // TODO: Change return vars after management fees are properly implemented.
    function _claimLoan(address loanAddress_, uint256 principal_, uint256 interest_) internal {
        principalOut -= principal_;

        uint256 loanId_ = loanIdOf[loanAddress_];

        bool hasSufficientCover_ = IPoolManagerLike(poolManager).hasSufficientCover();

        uint256 platformFee_ = interest_ * loans[loanId_].platformManagementFeeRate / SCALED_ONE;

        uint256 delegateFee_ = hasSufficientCover_ ? interest_ * loans[loanId_].delegateManagementFeeRate / SCALED_ONE : 0;

        require(ERC20Helper.transfer(fundsAsset, pool, principal_ + interest_ - platformFee_ - delegateFee_), "LM:CL:POOL_TRANSFER");

        require(ERC20Helper.transfer(fundsAsset, mapleTreasury(), platformFee_), "LM:CL:MT_TRANSFER");

        require(!hasSufficientCover_ || ERC20Helper.transfer(fundsAsset, poolDelegate(), delegateFee_), "LM:CL:PD_TRANSFER");
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
        accountedInterest -= (loanAccruedInterest_ + loanInfo_.refinanceInterest);

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

        accountedInterest -= liquidationInfo_.interest;
        unrealizedLosses  -= (liquidationInfo_.principal + liquidationInfo_.interest);

        delete liquidationInfo[loan_];
    }

    function _queueNextLoanPayment(address loan_, uint256 startDate_, uint256 nextPaymentDueDate_) internal returns (uint256 newRate_) {
        uint256 platformManagementFeeRate_ = IMapleGlobalsLike(globals()).platformManagementFeeRate(poolManager);
        uint256 delegateManagementFeeRate_ = IPoolManagerLike(poolManager).delegateManagementFeeRate();
        uint256 managementFeeRate_         = platformManagementFeeRate_ + delegateManagementFeeRate_;

        // NOTE: If combined fee is greater than 100%, then cap delegate fee and clamp management fee.
        if (managementFeeRate_ > SCALED_ONE) {
            delegateManagementFeeRate_ = SCALED_ONE - platformManagementFeeRate_;
            managementFeeRate_ = SCALED_ONE;
        }

        ( , uint256 interest_, )   = ILoanLike(loan_).getNextPaymentBreakdown();
        uint256 refinanceInterest_ = ILoanLike(loan_).refinanceInterest();

        uint256 netRefinanceInterest_ = _getNetInterest(refinanceInterest_,             managementFeeRate_);
        uint256 netInterest_          = _getNetInterest(interest_ - refinanceInterest_, managementFeeRate_);

        newRate_ = (netInterest_ * PRECISION) / (nextPaymentDueDate_ - startDate_);

        // Add the LoanInfo to the sorted list, making sure to take the effective start date (and not the current block timestamp).
        uint256 loanId_ = loanIdOf[loan_] = ++loanCounter;

        _addLoanToList(loanId_, LoanInfo({
            // Previous and next will be overridden within _addLoan function.
            previous:                  0,
            next:                      0,
            incomingNetInterest:       netInterest_,
            refinanceInterest:         netRefinanceInterest_,
            issuanceRate:              newRate_,
            startDate:                 startDate_,
            paymentDueDate:            nextPaymentDueDate_,
            platformManagementFeeRate: platformManagementFeeRate_,
            delegateManagementFeeRate: delegateManagementFeeRate_
        }));

        // Update the accounted interest to reflect what is present in the loan.
        accountedInterest += netRefinanceInterest_;
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
                * IMapleGlobalsLike(globals_).getLatestPrice(collateralAsset_) // Convert from `fromAsset` value.
                * uint256(10) ** uint256(IERC20Like(fundsAsset).decimals())    // Convert to `toAsset` decimal precision.
                * (SCALED_ONE - allowedSlippageFor[collateralAsset_])          // Multiply by allowed slippage basis points
                / IMapleGlobalsLike(globals_).getLatestPrice(fundsAsset)       // Convert to `toAsset` value.
                / uint256(10) ** uint256(collateralAssetDecimals)              // Convert from `fromAsset` decimal precision.
                / SCALED_ONE;                                                  // Divide basis points for slippage.

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
        netInterest_ = interest_ * (SCALED_ONE - feeRate_) / SCALED_ONE;
    }

    function _max(uint256 a_, uint256 b_) internal pure returns (uint256 maximum_) {
        return a_ > b_ ? a_ : b_;
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256 minimum_) {
        return a_ < b_ ? a_ : b_;
    }

    /******************************/
    /*** Mock Globals Functions ***/
    /******************************/

    // TODO: Remove
    function protocolPaused() external view override returns (bool protocolPaused_) {
        return false;
    }

    // TODO: Add event emission.

}
