// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { ERC20Helper }           from "../modules/erc20-helper/src/ERC20Helper.sol";
import { Liquidator }            from "../modules/liquidations/contracts/Liquidator.sol";
import { IMapleProxyFactory }    from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import { ILoanManager }                            from "./interfaces/ILoanManager.sol";
import { IERC20Like, ILoanLike, IPoolManagerLike } from "./interfaces/Interfaces.sol";

import { LoanManagerStorage } from "./proxy/LoanManagerStorage.sol";

contract LoanManager is ILoanManager, MapleProxiedInternals, LoanManagerStorage {

    uint256 constant PRECISION  = 1e30;
    uint256 constant SCALED_ONE = 1e18;

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

    /**************************/
    /*** External Functions ***/
    /**************************/

    // TODO: Test situation where multiple payment intervals pass between claims of a single loan

    function claim(address loanAddress_) external returns (uint256 managementPortion_) {
        require(msg.sender == poolManager, "LM:C:NOT_POOL_MANAGER");

        // Update initial accounting
        // TODO: Think we need to update issuanceRate here
        accountedInterest = getAccruedInterest();
        lastUpdated       = block.timestamp;

        uint256 principalPaid   = 0;
        uint256 netInterestPaid = 0;

        // Claim loan and get principal and interest portion of claimable.
        ( principalPaid, netInterestPaid, managementPortion_ ) = _claimLoan(loanAddress_);

        principalOut -= principalPaid;

        // Remove loan from sorted list and get relevant previous parameters.
        ( , , uint256 previousPaymentDueDate, uint256 previousRate ) = _removeLoan(loanAddress_);

        uint256 managementFee_ = IPoolManagerLike(poolManager).managementFee();

        // Get relevant next parameters.
        ( , uint256 incomingNetInterest, uint256 nextPaymentDueDate ) = _getNextPaymentOf(loanAddress_, managementFee_);

        uint256 newRate = 0;

        // If there is a next payment for this loan.
        if (nextPaymentDueDate != 0) {

            // The next rate will be over the course of the remaining time, or the payment interval, whichever is longer.
            // In other words, if the previous payment was early, then the next payment will start accruing from now,
            // but if the previous payment was late, then we should have been accruing the next payment from the moment the previous payment was due.
            uint256 nextStartDate = _minimumOf(block.timestamp, previousPaymentDueDate);

            // Add the LoanInfo to the sorted list, making sure to take the effective start date (and not the current block timestamp).
            _addLoan(LoanInfo({
                // Previous and next will be overriden within _addLoan function
                previous:            0,
                next:                0,
                incomingNetInterest: incomingNetInterest,
                startDate:           nextStartDate,
                paymentDueDate:      nextPaymentDueDate,
                managementFee:       managementFee_,
                vehicle:             loanAddress_
            }));

            newRate = (incomingNetInterest * PRECISION) / (nextPaymentDueDate - nextStartDate);
        }

        // The new vesting period finish is the maximum of the current earliest, if it does not exist set to current timestamp to end vesting.
        // TODO: Should we make this paymentDueDate + gracePeriod?
        vestingPeriodFinish = _maximumOf(loans[loanWithEarliestPaymentDueDate].paymentDueDate, block.timestamp);

        // Update the vesting state an then set the new issuance rate take into account the cessation of the previous rate
        // and the commencement of the new rate for this loan.
        issuanceRate = issuanceRate + newRate - previousRate;

        // If the amount of interest claimed is greater than the amount accounted for, set to zero.
        // Discrepancy between accounted and actual is always captured by balance change in the pool from the claimed interest.
        accountedInterest = netInterestPaid > accountedInterest ? 0 : accountedInterest - netInterestPaid;

        // If there even is a new rate, and the next payment should have already been accruing, then accrue it.
        if (newRate != 0 && block.timestamp > previousPaymentDueDate) {
            accountedInterest += (block.timestamp - previousPaymentDueDate) * newRate / PRECISION;
        }
    }

    function fund(address loanAddress_) external {
        require(msg.sender == poolManager, "LM:F:NOT_POOL_MANAGER");

        ILoanLike(loanAddress_).fundLoan(address(this));

        uint256 principal = principalOf[loanAddress_] = ILoanLike(loanAddress_).principal();

        uint256 managementFee_ = IPoolManagerLike(poolManager).managementFee();

        ( , uint256 nextInterest, uint256 nextPaymentDueDate ) = _getNextPaymentOf(loanAddress_, managementFee_);

        _addLoan(LoanInfo({
            previous:            0,
            next:                0,
            incomingNetInterest: nextInterest,
            startDate:           block.timestamp,
            paymentDueDate:      nextPaymentDueDate,
            managementFee:       managementFee_,
            vehicle:             loanAddress_
        }));

        uint256 issuanceRateIncrease = (nextInterest * PRECISION) / (nextPaymentDueDate - block.timestamp);

        principalOut        += principal;
        accountedInterest    = getAccruedInterest();
        issuanceRate        += issuanceRateIncrease;
        vestingPeriodFinish  = loans[loanWithEarliestPaymentDueDate].paymentDueDate;
        lastUpdated          = block.timestamp;
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

    function triggerCollateralLiquidation(address loan_, address auctioneer_) external returns (uint256 increasedUnrealizedLosses_) {
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
                        auctioneer_:      auctioneer_,
                        destination_:     address(this),
                        globals_:         address(this)
                })
            );

            require(ERC20Helper.transfer(collateralAsset,   liquidator, collateralAssetAmount), "LM:TD:CA_TRANSFER");
            require(ERC20Helper.transfer(loan.fundsAsset(), liquidator, fundsAssetAmount),      "LM:TD:FA_TRANSFER");
        }

        increasedUnrealizedLosses_ = principal;  // TODO: Should this be principal + accrued interest?

        liquidationInfo[loan_] = LiquidationInfo(principal, liquidator);

        // TODO: Remove issuance rate from loan, but it's dependant on how the IM does that
        // TODO: Incorporate real auctioneer and globals, currently using address(this) for all 3 liquidator actors.
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    // TODO Passing Memory due to stack too deep error. Investigate if efficiency is lost here
    function _addLoan(LoanInfo memory loan_) internal returns (uint256 loanId_) {
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

    function _claimLoan(address loan_) internal returns (uint256 principalPortion_, uint256 interestPortion_, uint256 managementPortion_) {
        ILoanLike loan     = ILoanLike(loan_);
        principalPortion_  = principalOf[loan_] - loan.principal();
        interestPortion_   = loan.claimableFunds() - principalPortion_;
        principalOf[loan_] = loan.principal();

        uint256 id_ = loanIdOf[loan_];

        managementPortion_ = interestPortion_ * loans[id_].managementFee / SCALED_ONE;

        if (managementPortion_ != 0) {
            loan.claimFunds(managementPortion_, address(poolManager));
            interestPortion_ -= managementPortion_;
        }

        loan.claimFunds(loan.claimableFunds(), pool);
    }

    function _removeLoan(address loan_) internal returns (uint256 payment_, uint256 startDate_, uint256 paymentDueDate_, uint256 issuanceRate_) {
        // TODO: Should this revert if the loan/id is not used?
        uint256 loanId_      = loanIdOf[loan_];
        LoanInfo memory loan = loans[loanId_];

        uint256 previous = loan.previous;
        uint256 next     = loan.next;

        payment_        = loan.incomingNetInterest;
        startDate_      = loan.startDate;
        paymentDueDate_ = loan.paymentDueDate;

        if (loanWithEarliestPaymentDueDate == loanId_) {
            loanWithEarliestPaymentDueDate = next;
        }

        if (next != 0) {
            loans[next].previous = previous;
        }

        if (previous != 0) {
            loans[previous].next = next;
        }

        delete loanIdOf[loan.vehicle];
        delete loans[loanId_];

        issuanceRate_ = (payment_ * PRECISION) / (paymentDueDate_ - startDate_);
    }

    function _minimumVestingPeriodFinishOf(uint256 a_, uint256 b_) internal view returns (uint256 realMinimum_) {
        if (a_ == 0 && b_ == 0) return block.timestamp;

        if (a_ == 0) return b_;

        if (b_ == 0) return a_;

        return _minimumOf(a_, b_);
    }

    function _getNextPaymentOf(address loan_, uint256 managementFee_) internal view returns (uint256 nextPrincipal_, uint256 nextInterest_, uint256 nextPaymentDueDate_) {
        nextPaymentDueDate_ = ILoanLike(loan_).nextPaymentDueDate();
        ( nextPrincipal_, nextInterest_ ) = nextPaymentDueDate_ == 0
            ? (0, 0)
            : ILoanLike(loan_).getNextPaymentBreakdown();

        nextInterest_ = nextInterest_ * (SCALED_ONE - managementFee_) / SCALED_ONE;
    }

    function _maximumOf(uint256 a_, uint256 b_) internal pure returns (uint256 maximum_) {
        return a_ > b_ ? a_ : b_;
    }

    function _minimumOf(uint256 a_, uint256 b_) internal pure returns (uint256 minimum_) {
        return a_ < b_ ? a_ : b_;
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

        if (issuanceRate_ == 0) return accountedInterest;

        uint256 vestingPeriodFinish_ = vestingPeriodFinish;
        uint256 lastUpdated_         = lastUpdated;

        uint256 vestingTimePassed = block.timestamp > vestingPeriodFinish_
            ? vestingPeriodFinish_ - lastUpdated_
            : block.timestamp - lastUpdated_;

        accruedInterest_ = issuanceRate_ * vestingTimePassed / PRECISION;
    }

    function implementation() external view returns (address implementation_) {
        return _implementation();
    }

    function isLiquidationActive(address loan_) public view returns (bool isActive_) {
        address liquidatorAddress = liquidationInfo[loan_].liquidator;

        return (liquidatorAddress != address(0)) && (IERC20Like(ILoanLike(loan_).collateralAsset()).balanceOf(liquidatorAddress) != uint256(0));
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
