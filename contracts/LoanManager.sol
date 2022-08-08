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

        require(
            ILoanLike(loan_).claimableFunds() == uint256(0) &&
            ILoanLike(loan_).principal() == principalOf[loan_],
            "LM:ANT:NEED_TO_CLAIM"
        );

        _advanceLoanAccounting();

        // Remove loan from sorted list and get relevant previous parameters.
        ( , uint256 previousRate_ ) = _recognizeLoanPayment(loan_);

        uint256 previousPrincipal = ILoanLike(loan_).principal();

        // Perform the refinancing, updating the loan state.
        ILoanLike(loan_).acceptNewTerms(refinancer_, deadline_, calls_);

        uint256 principal_ = principalOf[loan_] = ILoanLike(loan_).principal();

        if (principal_ > previousPrincipal) {
            principalOut += principal_ - previousPrincipal;
        } else {
            principalOut -= previousPrincipal - principal_;
        }

        uint256 newRate_ = _queueNextLoanPayment(loan_, block.timestamp, ILoanLike(loan_).nextPaymentDueDate());

        // The new vesting period finish is the maximum of the current earliest, if it does not exist set to
        // current timestamp to end vesting.
        vestingPeriodFinish = _max(loans[loanWithEarliestPaymentDueDate].paymentDueDate, block.timestamp);

        // Update the vesting state an then set the new issuance rate take into account the cessation of the previous rate
        // and the commencement of the new rate for this loan.
        issuanceRate = issuanceRate + newRate_ - previousRate_;
    }

    // TODO: Test situation where multiple payment intervals pass between claims of a single loan
    // TODO: Does this handle the situation where there is nothing to claim?

    function claim(address loanAddress_) external returns (uint256 managementPortion_) {
        require(msg.sender == poolManager, "LM:C:NOT_POOL_MANAGER");

        _advanceLoanAccounting();

        // Claim loan and move funds into pool and to PM.
        managementPortion_ = _claimLoan(loanAddress_);

        // Finalized the previous payment into the pool accounting.
        ( uint256 previousPaymentDueDate_, uint256 previousRate_ ) = _recognizeLoanPayment(loanAddress_);

        uint256 newRate_ = 0;

        uint256 nextPaymentDueDate_ = ILoanLike(loanAddress_).nextPaymentDueDate();

        // The next rate will be over the course of the remaining time, or the payment interval, whichever is longer.
        // In other words, if the previous payment was early, then the next payment will start accruing from now,
        // but if the previous payment was late, then we should have been accruing the next payment
        // from the moment the previous payment was due.
        uint256 nextStartDate_ = _min(block.timestamp, previousPaymentDueDate_);

        // If there is a next payment for this loan.
        if (nextPaymentDueDate_ != 0) {
            newRate_ = _queueNextLoanPayment(loanAddress_, nextStartDate_, nextPaymentDueDate_);
        }

        // The new vesting period finish is the maximum of the current earliest, if it does not exist set to
        // current timestamp to end vesting.
        // TODO: We should try and remove this, VPF should never be explicitly set to BT.
        vestingPeriodFinish = _max(loans[loanWithEarliestPaymentDueDate].paymentDueDate, block.timestamp);

        // Update the vesting state an then set the new issuance rate take into account the cessation of the previous rate
        // and the commencement of the new rate for this loan.
        issuanceRate = issuanceRate + newRate_ - previousRate_;

        /*
           If there is a new rate (meaning there is a new payment queued), and the block.timestamp is past the previousPaymentDueDate,
           then the previous payment has been claimed late, and we are late to apply the new issuance rate, because it should have started at previousPaymentDueDate.
           Since the new issuance rate is late to be applied, we have some unaccounted interest. We catch up the accounted interest by doing a discrete update of the missing interest,
           starting from when the new rate should have been applied, to when the new rate is actually applied.
        */
        if (newRate_ != 0 && block.timestamp > previousPaymentDueDate_) {
            accountedInterest += (block.timestamp - previousPaymentDueDate_) * newRate_ / PRECISION;
        }
    }

    function fund(address loanAddress_) external {
        require(msg.sender == poolManager, "LM:F:NOT_POOL_MANAGER");

        _advanceLoanAccounting();

        ILoanLike(loanAddress_).fundLoan(address(this));

        uint256 principal_ = principalOf[loanAddress_] = ILoanLike(loanAddress_).principal();
        uint256 newRate_   = _queueNextLoanPayment(loanAddress_, block.timestamp, ILoanLike(loanAddress_).nextPaymentDueDate());

        principalOut        += principal_;
        issuanceRate        += newRate_;
        vestingPeriodFinish = _max(loans[loanWithEarliestPaymentDueDate].paymentDueDate, block.timestamp);
    }

    /*************************/
    /*** Default Functions ***/
    /*************************/

    // TODO: Investigate transferring funds directly into pool from liquidator instead of accumulating in IM
    // TODO: Decrement principalOut by the full principal balance of the loan at the time of the repossession (principalToCover).
    // TODO: Rename principalToCover to indicate that it is the full principal balance of the loan at the time of the repossession.
    // TODO: Revisit `recoveredFunds` logic, especially in the case of multiple simultaneous liquidations.
    function finishCollateralLiquidation(address loan_) external returns (uint256 principalToCover_, uint256 remainingLosses_) {
        require(msg.sender == poolManager,   "LM:FCL:NOT_POOL_MANAGER");
        require(!isLiquidationActive(loan_), "LM:FCL:LIQ_STILL_ACTIVE");

        uint256 recoveredFunds_ = IERC20Like(fundsAsset).balanceOf(address(this));

        principalToCover_ = liquidationInfo[loan_].principalToCover;
        remainingLosses_  = recoveredFunds_ > principalToCover_ ? 0 : principalToCover_ - recoveredFunds_;

        delete liquidationInfo[loan_];

        // TODO decide on how the pool will handle the accounting
        require(ERC20Helper.transfer(fundsAsset, pool, recoveredFunds_));
    }

    /// @dev Trigger Default on a loan
    function triggerCollateralLiquidation(address loan_) external returns (uint256 increasedUnrealizedLosses_) {
        require(msg.sender == poolManager, "LM:TCL:NOT_POOL_MANAGER");

        // TODO: The loan is not able to handle defaults while there are claimable funds
        ILoanLike loan = ILoanLike(loan_);

        require(loan.claimableFunds() == uint256(0), "LM:TCL:NEED_TO_CLAIM");

        uint256 principal = loan.principal();

        (uint256 collateralAssetAmount, uint256 fundsAssetAmount) = loan.repossess(address(this));

        address collateralAsset = loan.collateralAsset();

        if (collateralAsset != fundsAsset && collateralAssetAmount != uint256(0)) {
            liquidator = address(
                new Liquidator({
                    owner_:           address(this),
                    collateralAsset_: collateralAsset,
                    fundsAsset_:      fundsAsset,
                    auctioneer_:      address(this),
                    destination_:     address(this),
                    globals_:         IPoolManagerLike(poolManager).globals()
                })
            );

            require(ERC20Helper.transfer(collateralAsset,   liquidator, collateralAssetAmount), "LM:TD:CA_TRANSFER");
            require(ERC20Helper.transfer(loan.fundsAsset(), liquidator, fundsAssetAmount),      "LM:TD:FA_TRANSFER");
        }

        increasedUnrealizedLosses_ = principal;  // TODO: Should this be principal + accrued interest?

        liquidationInfo[loan_] = LiquidationInfo(principal, liquidator);

        // TODO: Remove issuance rate from loan, but it's dependant on how the IM does that
    }

    /***************************************/
    /*** Internal Loan Sorting Functions ***/
    /***************************************/

    // TODO Passing Memory due to stack too deep error. Investigate if efficiency is lost here
    function _addLoanToList(LoanInfo memory loan_) internal returns (uint256 loanId_) {
        loanId_ = loanIdOf[loan_.vehicle] = ++loanCounter;

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

    // TODO: Gas optimize
    function _advanceLoanAccounting() internal {
        // If no vesting period finish, do not advance previous loan accounting.
        if (vestingPeriodFinish != 0) {
            uint256 loanId_ = loanWithEarliestPaymentDueDate;

            // Advance loans in previous domains to "catch up" to current state.
            while (loans[loanId_].paymentDueDate == vestingPeriodFinish && block.timestamp > vestingPeriodFinish) {
                LoanInfo memory loan_ = loans[loanId_];

                // Remove the loan from the linked list so the next loan can be used as the shortest timestamp.
                // NOTE: This keeps the loan accounting info intact so it can be accounted for when the payment is claimed.
                _removeLoanFromList(loan_.previous, loan_.next, loanId_);

                // Remove issuanceRate as it is deducted from global issuanceRate.
                loans[loanId_].issuanceRate = 0;

                // Update accounting between timestamps and set last updated to the vestingPeriodFinish.
                // Reduce the issuanceRate for the loan.
                accountedInterest += (vestingPeriodFinish - lastUpdated) * issuanceRate / PRECISION;
                issuanceRate      -= loan_.issuanceRate;
                lastUpdated        = vestingPeriodFinish;

                // Update the new VPF by using the updated linked list.
                vestingPeriodFinish = _min(loans[loanWithEarliestPaymentDueDate].paymentDueDate, block.timestamp);  // TODO: Revisit

                // If the end of the list has been reached, exit the loop.
                if ((loanId_ = loans[loanId_].next) == 0) break;
            }
        }

        // Accrue interest to the current timestamp.
        accountedInterest += getAccruedInterest();
        lastUpdated        = block.timestamp;
    }

    // TODO: Change return vars after managment fees are properly implemented.
    function _claimLoan(address loan_) internal returns (uint256 managementPortion_) {
        ILoanLike loan = ILoanLike(loan_);

        uint256 claimable_ = loan.claimableFunds();

        require(claimable_ != 0, "LM:ANT:NO_CLAIMABLE_FUNDS");

        uint256 currentPrincipal_ = loan.principal();
        uint256 principalPortion_ = principalOf[loan_] - currentPrincipal_;
        uint256 interestPortion_  = claimable_ - principalPortion_;

        principalOf[loan_] = currentPrincipal_;

        // Decrement principal claimed.
        principalOut -= principalPortion_;

        uint256 id_ = loanIdOf[loan_];

        managementPortion_ = interestPortion_ * loans[id_].managementFee / SCALED_ONE;

        if (managementPortion_ != 0) {
            loan.claimFunds(managementPortion_, address(poolManager));
        }

        loan.claimFunds(loan.claimableFunds(), pool);
    }

    // TODO: Rename function to indicate that it can happen on refinance as well.
    function _recognizeLoanPayment(address loan_) internal returns (uint256 paymentDueDate_, uint256 issuanceRate_) {
        uint256 loanId_ = loanIdOf[loan_];

        LoanInfo memory loanInfo_ = loans[loanId_];

        _removeLoanFromList(loanInfo_.previous, loanInfo_.next, loanId_);

        issuanceRate_   = loanInfo_.issuanceRate;
        paymentDueDate_ = loanInfo_.paymentDueDate;

        // If the amount of interest claimed is greater than the amount accounted for, set to zero.
        // Discrepancy between accounted and actual is always captured by balance change in the pool from the claimed interest.
        uint256 loanAccruedInterest_ =
            block.timestamp < loanInfo_.paymentDueDate
                ? (block.timestamp - loanInfo_.startDate) * loanInfo_.issuanceRate / PRECISION
                : loanInfo_.incomingNetInterest;

        // Add any interest owed prior to a refinance and reduce AUM accordingly.
        accountedInterest -= (loanAccruedInterest_ + loanInfo_.refinanceInterest);

        // Loan Info is deleted, because the payment has been fully recognized in the pool accounting, and will never be used again.
        delete loanIdOf[loan_];
        delete loans[loanId_];
    }

    function _queueNextLoanPayment(address loan_, uint256 startDate_, uint256 nextPaymentDueDate_) internal returns (uint256 newRate_) {
        uint256 managementFee_ = IPoolManagerLike(poolManager).managementFee();

        ( , uint256 incomingNetInterest_ ) = ILoanLike(loan_).getNextPaymentBreakdown();

        // Calculate net refinance interest.
        uint256 refinanceInterest_ = ILoanLike(loan_).refinanceInterest() * (SCALED_ONE - managementFee_) / SCALED_ONE;

        // Interest used for issuance rate calculation is:
        // Net interest minus the interest accrued prior to refinance.
        incomingNetInterest_ = (incomingNetInterest_ * (SCALED_ONE - managementFee_) / SCALED_ONE) - refinanceInterest_;

        newRate_ = (incomingNetInterest_ * PRECISION) / (nextPaymentDueDate_ - startDate_);

        // Add the LoanInfo to the sorted list, making sure to take the effective start date (and not the current block timestamp).
        _addLoanToList(LoanInfo({
            // Previous and next will be overriden within _addLoan function
            previous:            0,
            next:                0,
            incomingNetInterest: incomingNetInterest_,
            refinanceInterest:   refinanceInterest_,
            issuanceRate:        newRate_,
            startDate:           startDate_,
            paymentDueDate:      nextPaymentDueDate_,
            managementFee:       managementFee_,
            vehicle:             loan_
        }));

        // Update the accounted interest to reflect what is present in the loan.
        accountedInterest += refinanceInterest_;
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    // TODO: Add bool flag for optionally including unrecognized losses.
    function assetsUnderManagement() public view virtual returns (uint256 assetsUnderManagement_) {
        // TODO: Figure out better approach for this
        uint256 accruedInterest = lastUpdated == block.timestamp ? 0 : getAccruedInterest();

        return principalOut + accountedInterest + accruedInterest;
    }

    function factory() external view returns (address factory_) {
        return _factory();
    }

    function getAccruedInterest() public view returns (uint256 accruedInterest_) {
        uint256 issuanceRate_ = issuanceRate;

        if (issuanceRate_ == 0) return uint256(0);

        uint256 vestingPeriodFinish_ = vestingPeriodFinish;
        uint256 lastUpdated_         = lastUpdated;

        uint256 vestingTimePassed = block.timestamp > vestingPeriodFinish_
            ? vestingPeriodFinish_ - lastUpdated_
            : block.timestamp - lastUpdated_;

        accruedInterest_ = issuanceRate_ * vestingTimePassed / PRECISION;
    }

    function getExpectedAmount(address collateralAsset_, uint256 swapAmount_) public view returns (uint256 returnAmount_) {
        address globals = IPoolManagerLike(poolManager).globals();

        uint8 collateralAssetDecimals = IERC20Like(collateralAsset_).decimals();

        uint256 oracleAmount =
            swapAmount_
                * IGlobalsLike(globals).getLatestPrice(collateralAsset_)              // Convert from `fromAsset` value.
                * uint256(10) ** uint256(IERC20Like(fundsAsset).decimals())           // Convert to `toAsset` decimal precision.
                * (ONE_HUNDRED_PERCENT_BASIS - allowedSlippageFor[collateralAsset_])  // Multiply by allowed slippage basis points
                / IGlobalsLike(globals).getLatestPrice(fundsAsset)                    // Convert to `toAsset` value.
                / uint256(10) ** uint256(collateralAssetDecimals)                     // Convert from `fromAsset` decimal precision.
                / ONE_HUNDRED_PERCENT_BASIS;                                          // Divide basis points for slippage.

        // TODO: Document precision of minRatioFor is decimal representation of min ratio in fundsAsset decimal precision.
        uint256 minRatioAmount = (swapAmount_ * minRatioFor[collateralAsset_]) / (uint256(10) ** collateralAssetDecimals);

        return oracleAmount > minRatioAmount ? oracleAmount : minRatioAmount;
    }

    function implementation() external view returns (address implementation_) {
        return _implementation();
    }

    function isLiquidationActive(address loan_) public view returns (bool isActive_) {
        address liquidatorAddress = liquidationInfo[loan_].liquidator;

        return (liquidatorAddress != address(0)) && (IERC20Like(ILoanLike(loan_).collateralAsset()).balanceOf(liquidatorAddress) != uint256(0));
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
