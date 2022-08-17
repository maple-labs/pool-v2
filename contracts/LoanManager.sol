// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { console } from "../modules/contract-test-utils/contracts/test.sol";

import { ERC20Helper }           from "../modules/erc20-helper/src/ERC20Helper.sol";
import { Liquidator }            from "../modules/liquidations/contracts/Liquidator.sol";
import { IMapleProxyFactory }    from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import { ILoanManager } from "./interfaces/ILoanManager.sol";
import {
    IERC20Like,
    IGlobalsLike,
    ILoanLike,
    IPoolLike,
    IPoolManagerLike
} from "./interfaces/Interfaces.sol";

import { LoanManagerStorage } from "./proxy/LoanManagerStorage.sol";

contract LoanManager is ILoanManager, MapleProxiedInternals, LoanManagerStorage {

    /**
     * @dev   Emitted when `setAllowedSlippage` is called.
     * @param collateralAsset_  Address of a collateral asset.
     * @param newSlippage_      New value for `allowedSlippage`.
     */
    event AllowedSlippageSet(address collateralAsset_, uint256 newSlippage_);

    /**
     * @dev   Emitted when `setMinRatio` is called.
     * @param collateralAsset_ Address of a collateral asset.
     * @param newMinRatio_     New value for `minRatio`.
     */
    event MinRatioSet(address collateralAsset_, uint256 newMinRatio_);

    uint256 constant PRECISION  = 1e30;
    uint256 constant SCALED_ONE = 1e18;
    uint256 constant ONE_HUNDRED_PERCENT_BASIS = 10_000;

    /***************************/
    /*** Migration Functions ***/
    /***************************/

    function migrate(address migrator_, bytes calldata arguments_) external {
        require(msg.sender == _factory(),        "LM:M:NOT_FACTORY");
        require(_migrate(migrator_, arguments_), "LM:M:FAILED");
    }

    function setImplementation(address implementation_) external {
        require(msg.sender == _factory(), "LM:SI:NOT_FACTORY");

        _setImplementation(implementation_);
    }

    function upgrade(uint256 version_, bytes calldata arguments_) external {
        require(msg.sender == IPoolManagerLike(poolManager).poolDelegate(), "LM:U:NOT_PD");

        IMapleProxyFactory(_factory()).upgradeInstance(version_, arguments_);
    }

    /*******************************/
    /*** Adminstrative Functions ***/
    /*******************************/

    function setAllowedSlippage(address collateralAsset_, uint256 allowedSlippage_) external {
        require(msg.sender == poolManager,                     "LM:SAS:NOT_POOL_MANAGER");
        require(allowedSlippage_ <= ONE_HUNDRED_PERCENT_BASIS, "LM:SAS:INVALID_SLIPPAGE");
        emit AllowedSlippageSet(collateralAsset_, allowedSlippageFor[collateralAsset_] = allowedSlippage_);
    }

    function setMinRatio(address collateralAsset_, uint256 minRatio_) external {
        require(msg.sender == poolManager, "LM:SMR:NOT_POOL_MANAGER");
        emit MinRatioSet(collateralAsset_, minRatioFor[collateralAsset_] = minRatio_);
    }

    /*********************************/
    /*** Loan Accounting Functions ***/
    /*********************************/

    function acceptNewTerms(address loan_, address refinancer_, uint256 deadline_, bytes[] calldata calls_) external {
        require(msg.sender == poolManager, "LM:ANT:NOT_ADMIN");

        _advanceLoanAccounting();

        // Remove loan from sorted list and get relevant previous parameters.
        ( , uint256 previousRate_ ) = _recognizeLoanPayment(loan_);

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
    }

    // TODO: Test situation where multiple payment intervals pass between claims of a single loan

    function claim(uint256 principal_, uint256 interest_, uint256 nextPaymentDueDate_) external {
        require(loanIdOf[msg.sender] != 0, "LM:C:NOT_LOAN");

        _advanceLoanAccounting();

        // Claim loan and move funds into pool and to PM.
        _claimLoan(msg.sender, principal_, interest_);

        // Finalized the previous payment into the pool accounting.
        uint256 previousPaymentDueDate_;
        uint256 previousRate_;

        // TODO: Should we clear the flag in the loan and pass in a bool to this function, or call this during a default warning payment, then clear the flag in the loan after this call returns?
        if (!ILoanLike(msg.sender).isInDefaultWarning()) {
            ( previousPaymentDueDate_, previousRate_ ) = _recognizeLoanPayment(msg.sender);
        } else {
            // If we successfully claimed above, that means that the payment has been made through the default warning, and the loan did not default.
            ( previousPaymentDueDate_, previousRate_ ) = _recognizeDefaultWarningLoanPayment(msg.sender);
        }

        uint256 newRate_ = 0;

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
    }

    function fund(address loanAddress_) external {
        require(msg.sender == poolManager, "LM:F:NOT_POOL_MANAGER");

        _advanceLoanAccounting();

        ILoanLike(loanAddress_).fundLoan(address(this));

        uint256 newRate_ = _queueNextLoanPayment(loanAddress_, block.timestamp, ILoanLike(loanAddress_).nextPaymentDueDate());

        principalOut += ILoanLike(loanAddress_).principal();
        issuanceRate += newRate_;
        domainEnd     = loans[loanWithEarliestPaymentDueDate].paymentDueDate;
    }

    /*************************/
    /*** Default Functions ***/
    /*************************/

    function removeDefaultWarning(address loan_) external {
        require(msg.sender == poolManager, "LM:RDW:NOT_POOL_MANAGER");

        _advanceLoanAccounting();

        ILoanLike(loan_).removeDefaultWarning();

        uint256 loanId_ = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        _revertDefaultWarning(loanId_);

        _addLoanToList(loanId_, loanInfo_);

        // Discretely update missing interest as if loan was always part of the list.
        accountedInterest += _getLoanAccruedInterest(loanInfo_.startDate, domainStart, loanInfo_.issuanceRate, loanInfo_.refinanceInterest);

        domainEnd = loans[loanWithEarliestPaymentDueDate].paymentDueDate;
    }

    function triggerDefaultWarning(address loan_, uint256 newPaymentDueDate_) external {
        require(msg.sender == poolManager, "LM:TDW:NOT_POOL_MANAGER");

        _advanceLoanAccounting();

        ILoanLike(loan_).triggerDefaultWarning(newPaymentDueDate_);

        // Get necessary data structures.
        uint256 loanId_           = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        // Remove payment's issuance rate from the LM issuance rate.
        issuanceRate -= loanInfo_.issuanceRate;

        // NOTE: Even though `nextPaymentDueDate` could be set to after `block`.timestamp, we still stop the interest accrual.
        // Principal + payment accrued interest + refinance interest.
        uint256 shortfallPrincipalPortion_ = ILoanLike(loan_).principal();
        uint256 shortfallInterestPortion_  = _getLoanAccruedInterest(loanInfo_.startDate, block.timestamp, loanInfo_.issuanceRate, loanInfo_.refinanceInterest);
        triggerDefaultWarningInfo[loanId_] = TriggerDefaultWarningInfo(newPaymentDueDate_, shortfallPrincipalPortion_, shortfallInterestPortion_);

        unrealizedLosses += (shortfallPrincipalPortion_ + shortfallInterestPortion_);

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
    }

    // TODO: Reorder funcs alphabetically.
    // TODO: Revisit `recoveredFunds` logic, especially in the case of multiple simultaneous liquidations.
    function finishCollateralLiquidation(address loan_) external returns (uint256 remainingLosses_) {
        require(msg.sender == poolManager,   "LM:FCL:NOT_POOL_MANAGER");
        require(!isLiquidationActive(loan_), "LM:FCL:LIQ_STILL_ACTIVE");

        uint256 recoveredFunds_   = IERC20Like(fundsAsset).balanceOf(address(this));
        uint256 shortfallToCover_ = liquidationInfo[loan_].shortfallToCover;
        uint256 principal_        = ILoanLike(loan_).principal();

        // Realize the loss following the liquidation.
        unrealizedLosses -= shortfallToCover_;

        // Get the remaining losses to attempt to recover via pool delegate cover.
        remainingLosses_ = recoveredFunds_ > shortfallToCover_ ? 0 : shortfallToCover_ - recoveredFunds_;

        // Reduce principal out, since it has been accounted for in the liquidation.
        principalOut -= principal_;

        // Reduce accounted interest by the interest portion of the shortfall, as the loss has been realized, and therefore this interest has been accounted for.
        accountedInterest -= shortfallToCover_ - principal_;

        delete liquidationInfo[loan_];

        require(ERC20Helper.transfer(fundsAsset, pool, recoveredFunds_));
    }

    /// @dev Trigger Default on a loan
    function triggerCollateralLiquidation(address loan_) external {
        require(msg.sender == poolManager, "LM:TCL:NOT_POOL_MANAGER");

        _advanceLoanAccounting();

        ILoanLike loan            = ILoanLike(loan_);
        uint256 loanId_           = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        ( uint256 collateralAssetAmount, uint256 fundsAssetAmount ) = loan.repossess(address(this));

        address collateralAsset = loan.collateralAsset();

        if (collateralAsset != fundsAsset && collateralAssetAmount != uint256(0)) {
            liquidator = address(
                new Liquidator({
                    owner_:           address(this),
                    collateralAsset_: collateralAsset,
                    fundsAsset_:      fundsAsset,
                    auctioneer_:      address(this),
                    destination_:     address(this),
                    globals_:         globals()
                })
            );

            require(ERC20Helper.transfer(collateralAsset,   liquidator, collateralAssetAmount), "LM:TD:CA_TRANSFER");
            require(ERC20Helper.transfer(loan.fundsAsset(), liquidator, fundsAssetAmount),      "LM:TD:FA_TRANSFER");
        }

        uint256 defaultAmount_;

        // `unrealizedLosses` is unchanged if `isInDefaultWarning` because it has already been accounted for.
        if (!loan.isInDefaultWarning()) {
            defaultAmount_ = loan.principal() + loanInfo_.incomingNetInterest + loanInfo_.refinanceInterest;

            // TODO: Include paying Maple fees in finalizeCollateralLiquidation, using collateral and/or cover.
            // TODO: Validate late interest is correctly accounted.
            unrealizedLosses += defaultAmount_;

            // Loan Info is cleaned up, because this function confirms that the payment will not be made and that it is recognized as a loss.
            _removeLoanFromList(loanInfo_.previous, loanInfo_.next, loanId_);
        } else {
            // TODO: Need to revisit late interest for this code path.
            TriggerDefaultWarningInfo memory defaultInfo = triggerDefaultWarningInfo[loanId_];
            defaultAmount_ = defaultInfo.principal + defaultInfo.interest;
            delete triggerDefaultWarningInfo[loanId_];
        }

        liquidationInfo[loan_] = LiquidationInfo(defaultAmount_, liquidator);

        delete loanIdOf[loan_];
        delete loans[loanId_];

        // If there are no more payments in the list, set domain end to block.timestamp (which equals `domainStart`, from `_advanceLoanAccounting`)
        // Otherwise, set it to the next upcoming payment.
        if (loanWithEarliestPaymentDueDate == 0) {
            domainEnd = block.timestamp;
        } else {
            domainEnd = loans[loanWithEarliestPaymentDueDate].paymentDueDate;
        }

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

    // TODO: Change return vars after managment fees are properly implemented.
    function _claimLoan(address loanAddress_, uint256 principal_, uint256 interest_) internal {
        principalOut -= principal_;

        uint256 loanId_ = loanIdOf[loanAddress_];

        bool hasSufficientCover_ = IPoolManagerLike(poolManager).hasSufficientCover();

        uint256 platformFee_ = interest_ * loans[loanId_].platformManagementFeeRate / SCALED_ONE;

        uint256 delegateFee_ = hasSufficientCover_ ? interest_ * loans[loanId_].delegateManagementFeeRate / SCALED_ONE : 0;

        require(ERC20Helper.transfer(fundsAsset, pool, principal_ + interest_ - platformFee_ - delegateFee_), "LM:CL:POOL_TRANSFER");

        require(ERC20Helper.transfer(fundsAsset, mapleTreasury(), platformFee_), "LM:CL:MT_TRANSFER");

        if (hasSufficientCover_) {
            require(ERC20Helper.transfer(fundsAsset, poolDelegate(), delegateFee_), "LM:CL:MT_TRANSFER");
        }
    }

    function _getLoanAccruedInterest(uint256 startTime_, uint256 endTime_, uint256 loanIssuanceRate_, uint256 refinanceInterest_) internal pure returns (uint256 accruedInterest_) {
        accruedInterest_ = (endTime_ - startTime_) * loanIssuanceRate_ / PRECISION + refinanceInterest_;
    }

    // TODO: Rename function to indicate that it can happen on refinance as well.
    function _recognizeLoanPayment(address loan_) internal returns (uint256 paymentDueDate_, uint256 issuanceRate_) {
        uint256 loanId_           = loanIdOf[loan_];
        LoanInfo memory loanInfo_ = loans[loanId_];

        _removeLoanFromList(loanInfo_.previous, loanInfo_.next, loanId_);

        issuanceRate_   = loanInfo_.issuanceRate;
        paymentDueDate_ = loanInfo_.paymentDueDate;

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

    function _recognizeDefaultWarningLoanPayment(address loan_) internal returns (uint256 paymentDueDate_, uint256 issuanceRate_) {
        uint256 loanId_ = loanIdOf[loan_];

        paymentDueDate_ = triggerDefaultWarningInfo[loanId_].paymentDueDate;
        issuanceRate_ = 0;

        _revertDefaultWarning(loanId_);

        delete loanIdOf[loan_];
        delete loans[loanId_];
    }

    function _revertDefaultWarning(uint256 loanId_) internal {
        TriggerDefaultWarningInfo memory defaultInfo = triggerDefaultWarningInfo[loanId_];

        accountedInterest -= defaultInfo.interest;
        unrealizedLosses  -= (defaultInfo.principal + defaultInfo.interest);

        delete triggerDefaultWarningInfo[loanId_];
    }

    function _queueNextLoanPayment(address loan_, uint256 startDate_, uint256 nextPaymentDueDate_) internal returns (uint256 newRate_) {
        uint256 platformManagementFeeRate_ = IGlobalsLike(globals()).platformManagementFeeRate(poolManager);
        uint256 delegateManagementFeeRate_ = IPoolManagerLike(poolManager).delegateManagementFeeRate();
        uint256 managementFeeRate_         = platformManagementFeeRate_ + delegateManagementFeeRate_;

        ( , uint256 incomingNetInterest_ ) = ILoanLike(loan_).getNextPaymentBreakdown();

        // Calculate net refinance interest.
        uint256 refinanceInterest_ = ILoanLike(loan_).refinanceInterest() * (SCALED_ONE - managementFeeRate_) / SCALED_ONE;

        // Interest used for issuance rate calculation is:
        // Net interest minus the interest accrued prior to refinance.
        incomingNetInterest_ = (incomingNetInterest_ * (SCALED_ONE - managementFeeRate_) / SCALED_ONE) - refinanceInterest_;

        newRate_ = (incomingNetInterest_ * PRECISION) / (nextPaymentDueDate_ - startDate_);

        // Add the LoanInfo to the sorted list, making sure to take the effective start date (and not the current block timestamp).
        uint256 loanId_ = loanIdOf[loan_] = ++loanCounter;

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
            delegateManagementFeeRate: delegateManagementFeeRate_,
            vehicle:                   loan_
        }));

        // Update the accounted interest to reflect what is present in the loan.
        accountedInterest += refinanceInterest_;
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function assetsUnderManagement() public view virtual returns (uint256 assetsUnderManagement_) {
        // TODO: Figure out better approach for this
        uint256 accruedInterest = domainStart == block.timestamp ? 0 : getAccruedInterest();

        return principalOut + accountedInterest + accruedInterest;
    }

    function factory() external view returns (address factory_) {
        return _factory();
    }

    function getAccruedInterest() public view returns (uint256 accruedInterest_) {
        uint256 issuanceRate_ = issuanceRate;

        if (issuanceRate_ == 0) return uint256(0);

        // If before domain end, use current timestamp.
        accruedInterest_ = issuanceRate_ * (_min(block.timestamp, domainEnd) - domainStart) / PRECISION;
    }

    function getExpectedAmount(address collateralAsset_, uint256 swapAmount_) public view returns (uint256 returnAmount_) {
        address globals_ = globals();

        uint8 collateralAssetDecimals = IERC20Like(collateralAsset_).decimals();

        uint256 oracleAmount =
            swapAmount_
                * IGlobalsLike(globals_).getLatestPrice(collateralAsset_)              // Convert from `fromAsset` value.
                * uint256(10) ** uint256(IERC20Like(fundsAsset).decimals())           // Convert to `toAsset` decimal precision.
                * (ONE_HUNDRED_PERCENT_BASIS - allowedSlippageFor[collateralAsset_])  // Multiply by allowed slippage basis points
                / IGlobalsLike(globals_).getLatestPrice(fundsAsset)                    // Convert to `toAsset` value.
                / uint256(10) ** uint256(collateralAssetDecimals)                     // Convert from `fromAsset` decimal precision.
                / ONE_HUNDRED_PERCENT_BASIS;                                          // Divide basis points for slippage.

        // TODO: Document precision of minRatioFor is decimal representation of min ratio in fundsAsset decimal precision.
        uint256 minRatioAmount = (swapAmount_ * minRatioFor[collateralAsset_]) / (uint256(10) ** collateralAssetDecimals);

        return oracleAmount > minRatioAmount ? oracleAmount : minRatioAmount;
    }

    function globals() public view returns (address globals_) {
        return IPoolManagerLike(poolManager).globals();
    }

    function implementation() external view returns (address implementation_) {
        return _implementation();
    }

    function isLiquidationActive(address loan_) public view returns (bool isActive_) {
        address liquidatorAddress = liquidationInfo[loan_].liquidator;

        return (liquidatorAddress != address(0)) && (IERC20Like(ILoanLike(loan_).collateralAsset()).balanceOf(liquidatorAddress) != uint256(0));
    }

    function poolDelegate() public view returns (address poolDelegate_) {
        return IPoolManagerLike(poolManager).poolDelegate();
    }

    function mapleTreasury() public view returns (address treasury_) {
        return IGlobalsLike(globals()).mapleTreasury();
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

    /******************************/
    /*** Mock Globals Functions ***/
    /******************************/

    // TODO: Remove
    function protocolPaused() external view returns (bool protocolPaused_) {
        return false;
    }

    // TODO: Add event emission.

}
