// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { console } from "../modules/contract-test-utils/contracts/test.sol";

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
        console.log("AC0", accountedInterest);

        _advanceLoanAccounting();

        console.log("AC1", accountedInterest);

        uint256 netInterestPaid = 0;

        // TODO: Remove scope block
        {
            uint256 principalPaid = 0;

            // Claim loan and get principal and interest portion of claimable.
            ( principalPaid, netInterestPaid, managementPortion_ ) = _claimLoan(loanAddress_);

            principalOut -= principalPaid;
        }

        // Remove loan from sorted list and get relevant previous parameters.
        ( uint256 loanAccruedInterest, uint256 previousPaymentDueDate, uint256 previousRate ) = _deleteLoan(loanAddress_);

        uint256 newRate = 0;

        // TODO: Remove scope block
        {
            uint256 managementFee_ = IPoolManagerLike(poolManager).managementFee();

            // Get relevant next parameters.
            ( , uint256 incomingNetInterest, uint256 nextPaymentDueDate ) = _getNextPaymentOf(loanAddress_, managementFee_);

            // If there is a next payment for this loan.
            if (nextPaymentDueDate != 0) {

                // The next rate will be over the course of the remaining time, or the payment interval, whichever is longer.
                // In other words, if the previous payment was early, then the next payment will start accruing from now,
                // but if the previous payment was late, then we should have been accruing the next payment
                // from the moment the previous payment was due.
                uint256 nextStartDate = _min(block.timestamp, previousPaymentDueDate);

                newRate = (incomingNetInterest * PRECISION) / (nextPaymentDueDate - nextStartDate);

                // Add the LoanInfo to the sorted list, making sure to take the effective start date (and not the current block timestamp).
                _addLoan(LoanInfo({
                    // Previous and next will be overriden within _addLoan function
                    previous:            0,
                    next:                0,
                    incomingNetInterest: incomingNetInterest,
                    issuanceRate:        newRate,
                    startDate:           nextStartDate,
                    paymentDueDate:      nextPaymentDueDate,
                    managementFee:       managementFee_,
                    vehicle:             loanAddress_
                }));
            }
        }

        // The new vesting period finish is the maximum of the current earliest, if it does not exist set to
        // current timestamp to end vesting.
        vestingPeriodFinish = _max(loans[loanWithEarliestPaymentDueDate].paymentDueDate, block.timestamp);

        // Update the vesting state an then set the new issuance rate take into account the cessation of the previous rate
        // and the commencement of the new rate for this loan.
        issuanceRate = issuanceRate + newRate - previousRate;

        // If the amount of interest claimed is greater than the amount accounted for, set to zero.
        // Discrepancy between accounted and actual is always captured by balance change in the pool from the claimed interest.
        accountedInterest -= loanAccruedInterest;

        console.log("AC2", accountedInterest);
        console.log("NIP", netInterestPaid);
        console.log("LAI", loanAccruedInterest);

        // If there is a new rate, and the next payment should have already been accruing, then accrue and account for it.
        if (newRate != 0 && block.timestamp > previousPaymentDueDate) {
            console.log("NEW", (block.timestamp - previousPaymentDueDate) * newRate / PRECISION);
            accountedInterest += (block.timestamp - previousPaymentDueDate) * newRate / PRECISION;
        }

        console.log("AC3", accountedInterest);
    }

    function fund(address loanAddress_) external {
        require(msg.sender == poolManager, "LM:F:NOT_POOL_MANAGER");

        ILoanLike(loanAddress_).fundLoan(address(this));

        uint256 principal = principalOf[loanAddress_] = ILoanLike(loanAddress_).principal();

        uint256 managementFee_ = IPoolManagerLike(poolManager).managementFee();

        ( , uint256 nextInterest, uint256 nextPaymentDueDate ) = _getNextPaymentOf(loanAddress_, managementFee_);

        uint256 loanIssuanceRate = (nextInterest * PRECISION) / (nextPaymentDueDate - block.timestamp);

        _addLoan(LoanInfo({
            previous:            0,
            next:                0,
            incomingNetInterest: nextInterest,
            startDate:           block.timestamp,
            paymentDueDate:      nextPaymentDueDate,
            issuanceRate:        (nextInterest * PRECISION) / (nextPaymentDueDate - block.timestamp),
            managementFee:       managementFee_,
            vehicle:             loanAddress_
        }));

        principalOut        += principal;
        accountedInterest   += getAccruedInterest();
        issuanceRate        += loanIssuanceRate;
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

    function _accrueCurrentInterest() internal {
        accountedInterest += getAccruedInterest();
        lastUpdated        = block.timestamp;
    }

    // TODO: Gas optimize
    function _advanceLoanAccounting() internal {
        uint256 loanId_ = loanWithEarliestPaymentDueDate;

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
            vestingPeriodFinish = _max(loans[loanWithEarliestPaymentDueDate].paymentDueDate, block.timestamp);  // TODO: Revisit

            loanId_ = loans[loanId_].next;
        }

        // Accrue interest to the current timestamp.
        _accrueCurrentInterest();
    }

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

    function _deleteLoan(address loan_) internal returns (uint256 loanAccruedInterest_, uint256 paymentDueDate_, uint256 issuanceRate_) {
        uint256 loanId_ = loanIdOf[loan_];

        LoanInfo memory loan = loans[loanId_];

        _removeLoanFromList(loan.previous, loan.next, loanId_);

        issuanceRate_   = loan.issuanceRate;
        paymentDueDate_ = loan.paymentDueDate;

        // If the loan is early, calculate accrued interest from issuance, else use total interest.
        loanAccruedInterest_ =
            block.timestamp < paymentDueDate_
                ? (block.timestamp - loan.startDate) * issuanceRate_ / PRECISION
                : loan.incomingNetInterest;

        delete loanIdOf[loan_];
        delete loans[loanId_];
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

    function _getNextPaymentOf(address loan_, uint256 managementFee_) internal view returns (uint256 nextPrincipal_, uint256 nextInterest_, uint256 nextPaymentDueDate_) {
        nextPaymentDueDate_ = ILoanLike(loan_).nextPaymentDueDate();
        ( nextPrincipal_, nextInterest_ ) = nextPaymentDueDate_ == 0
            ? (0, 0)
            : ILoanLike(loan_).getNextPaymentBreakdown();

        nextInterest_ = nextInterest_ * (SCALED_ONE - managementFee_) / SCALED_ONE;
    }

    function _max(uint256 a_, uint256 b_) internal pure returns (uint256 maximum_) {
        return a_ > b_ ? a_ : b_;
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256 minimum_) {
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

        if (issuanceRate_ == 0) return uint256(0);

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
