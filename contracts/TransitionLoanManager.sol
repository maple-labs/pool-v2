// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IMapleProxyFactory }    from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import { ITransitionLoanManager } from "./interfaces/ITransitionLoanManager.sol";

import { IMapleGlobalsLike, IMapleLoanV3Like, IPoolManagerLike } from "./interfaces/Interfaces.sol";

import { LoanManagerStorage } from "./proxy/LoanManagerStorage.sol";

/*

    ████████╗██████╗  █████╗ ███╗   ██╗███████╗██╗████████╗██╗ ██████╗ ███╗   ██╗
    ╚══██╔══╝██╔══██╗██╔══██╗████╗  ██║██╔════╝██║╚══██╔══╝██║██╔═══██╗████╗  ██║
       ██║   ██████╔╝███████║██╔██╗ ██║███████╗██║   ██║   ██║██║   ██║██╔██╗ ██║
       ██║   ██╔══██╗██╔══██║██║╚██╗██║╚════██║██║   ██║   ██║██║   ██║██║╚██╗██║
       ██║   ██║  ██║██║  ██║██║ ╚████║███████║██║   ██║   ██║╚██████╔╝██║ ╚████║
       ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝

    ██╗      ██████╗  █████╗ ███╗   ██╗    ███╗   ███╗ █████╗ ███╗   ██╗ █████╗  ██████╗ ███████╗██████╗
    ██║     ██╔═══██╗██╔══██╗████╗  ██║    ████╗ ████║██╔══██╗████╗  ██║██╔══██╗██╔════╝ ██╔════╝██╔══██╗
    ██║     ██║   ██║███████║██╔██╗ ██║    ██╔████╔██║███████║██╔██╗ ██║███████║██║  ███╗█████╗  ██████╔╝
    ██║     ██║   ██║██╔══██║██║╚██╗██║    ██║╚██╔╝██║██╔══██║██║╚██╗██║██╔══██║██║   ██║██╔══╝  ██╔══██╗
    ███████╗╚██████╔╝██║  ██║██║ ╚████║    ██║ ╚═╝ ██║██║  ██║██║ ╚████║██║  ██║╚██████╔╝███████╗██║  ██║
    ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝

*/

contract TransitionLoanManager is ITransitionLoanManager, MapleProxiedInternals, LoanManagerStorage {

    uint256 public override constant PRECISION       = 1e30;
    uint256 public override constant HUNDRED_PERCENT = 1e6;  // 100.0000%

    /******************************************************************************************************************************/
    /*** Modifiers                                                                                                              ***/
    /******************************************************************************************************************************/

    modifier nonReentrant() {
        require(_locked == 1, "TLM:LOCKED");

        _locked = 2;

        _;

        _locked = 1;
    }

    /******************************************************************************************************************************/
    /*** Upgradeability Functions                                                                                               ***/
    /******************************************************************************************************************************/

    function migrate(address migrator_, bytes calldata arguments_) override external {
        require(msg.sender == _factory(),        "TLM:M:NOT_FACTORY");
        require(_migrate(migrator_, arguments_), "TLM:M:FAILED");
    }

    function setImplementation(address implementation_) override external {
        require(msg.sender == _factory(), "TLM:SI:NOT_FACTORY");
        _setImplementation(implementation_);
    }

    function upgrade(uint256 version_, bytes calldata arguments_) external override {
        require(msg.sender == migrationAdmin(), "TLM:U:NOT_MA");

        IMapleProxyFactory(_factory()).upgradeInstance(version_, arguments_);
    }

    /******************************************************************************************************************************/
    /*** Liquidity Migration Functions                                                                                          ***/
    /******************************************************************************************************************************/

    function add(address loan_) external override nonReentrant {
        require(msg.sender == migrationAdmin(), "TLM:A:NOT_MA");

        uint256 dueDate_ = IMapleLoanV3Like(loan_).nextPaymentDueDate();

        require(dueDate_ != 0 && block.timestamp < dueDate_, "TLM:A:INVALID_LOAN");

        uint256 domainStart_ = domainStart;

        if (domainStart_ == 0 || domainStart_ != block.timestamp) {
            domainStart = _uint48(block.timestamp);
        }

        uint256 startDate_ = dueDate_ - IMapleLoanV3Like(loan_).paymentInterval();

        if (block.timestamp < startDate_) {
            startDate_ = block.timestamp;
        }

        uint256 newRate_ = _queueNextPayment(loan_, startDate_, dueDate_);

        emit PrincipalOutUpdated(principalOut += _uint128(IMapleLoanV3Like(loan_).principal()));

        _updateIssuanceParams(issuanceRate += newRate_, accountedInterest);
    }

    function setOwnershipTo(address[] calldata loans_, address[] calldata newLenders_) external override {
        require(msg.sender == migrationAdmin(), "TLM:SOT:NOT_MA");

        require(loans_.length == newLenders_.length, "TLM:SOT:ARRAY_LENGTH_MISMATCH");

        for (uint256 i_ = 0; i_ < loans_.length; i_++) {
            IMapleLoanV3Like(loans_[i_]).setPendingLender(newLenders_[i_]);
        }
    }

    function takeOwnership(address[] calldata loans_) external override {
        require(msg.sender == migrationAdmin(), "TLM:TO:NOT_MA");

        for (uint256 i_ = 0; i_ < loans_.length; i_++) {
            IMapleLoanV3Like(loans_[i_]).acceptLender();
        }
    }

    /******************************************************************************************************************************/
    /*** Internal Payment Sorting Functions                                                                                     ***/
    /******************************************************************************************************************************/

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

    /******************************************************************************************************************************/
    /*** Internal Payment Accounting Functions                                                                                  ***/
    /******************************************************************************************************************************/

    function _queueNextPayment(address loan_, uint256 startDate_, uint256 nextPaymentDueDate_) internal returns (uint256 newRate_) {
        uint256 platformManagementFeeRate_ = IMapleGlobalsLike(globals()).platformManagementFeeRate(poolManager);
        uint256 delegateManagementFeeRate_ = IPoolManagerLike(poolManager).delegateManagementFeeRate();
        uint256 managementFeeRate_         = platformManagementFeeRate_ + delegateManagementFeeRate_;

        // NOTE: If combined fee is greater than 100%, then cap delegate fee and clamp management fee.
        if (managementFeeRate_ > HUNDRED_PERCENT) {
            delegateManagementFeeRate_ = HUNDRED_PERCENT - platformManagementFeeRate_;
            managementFeeRate_         = HUNDRED_PERCENT;
        }

        uint256 incomingNetInterest_;
        uint256 netRefinanceInterest_;

        {
            ( , uint256 interest_, , ) = IMapleLoanV3Like(loan_).getNextPaymentBreakdown();
            uint256 refinanceInterest  = IMapleLoanV3Like(loan_).refinanceInterest();

            incomingNetInterest_  = _getNetInterest(interest_ - refinanceInterest, managementFeeRate_);
            netRefinanceInterest_ = _getNetInterest(refinanceInterest,             managementFeeRate_);
        }

        newRate_ = (incomingNetInterest_ * PRECISION) / (nextPaymentDueDate_ - startDate_);

        incomingNetInterest_ = newRate_ * (nextPaymentDueDate_ - startDate_) / PRECISION;  // NOTE: Use issuanceRate to capture rounding errors.

        uint256 paymentId_ = paymentIdOf[loan_] = _addPaymentToList(_uint48(nextPaymentDueDate_));  // Add the payment to the sorted list.

        payments[paymentId_] = PaymentInfo({
            platformManagementFeeRate: _uint24(platformManagementFeeRate_),
            delegateManagementFeeRate: _uint24(delegateManagementFeeRate_),
            startDate:                 _uint48(startDate_),
            paymentDueDate:            _uint48(nextPaymentDueDate_),
            incomingNetInterest:       _uint128(incomingNetInterest_),
            refinanceInterest:         _uint128(netRefinanceInterest_),
            issuanceRate:              newRate_
        });

        // Update the accounted interest to reflect what is present in the loan.
        accountedInterest += _uint112(netRefinanceInterest_) + _uint112(newRate_ * (block.timestamp - startDate_) / PRECISION);

        emit PaymentAdded(
            loan_,
            paymentId_,
            platformManagementFeeRate_,
            delegateManagementFeeRate_,
            startDate_,
            nextPaymentDueDate_,
            netRefinanceInterest_,
            newRate_
        );
    }

    function _updateIssuanceParams(uint256 issuanceRate_, uint112 accountedInterest_) internal {
        // If there are no more payments in the list, set domain end to block.timestamp, otherwise, set it to the next upcoming payment.
        uint48 domainEnd_ = paymentWithEarliestDueDate == 0
            ? _uint48(block.timestamp)
            : payments[paymentWithEarliestDueDate].paymentDueDate;

        emit IssuanceParamsUpdated(
            domainEnd         = domainEnd_,
            issuanceRate      = issuanceRate_,
            accountedInterest = accountedInterest_
        );
    }

    /******************************************************************************************************************************/
    /*** View Functions                                                                                                         ***/
    /******************************************************************************************************************************/

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

    function globals() public view override returns (address globals_) {
        globals_ = IPoolManagerLike(poolManager).globals();
    }

    function implementation() external view override returns (address implementation_) {
        implementation_ = _implementation();
    }

    function migrationAdmin() public view override returns (address migrationAdmin_) {
        migrationAdmin_ = IMapleGlobalsLike(globals()).migrationAdmin();
    }

    /******************************************************************************************************************************/
    /*** Internal Helper Functions                                                                                              ***/
    /******************************************************************************************************************************/

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
        require(input_ <= type(uint24).max, "TLM:UINT24_CAST_OOB");
        output_ = uint24(input_);
    }

    function _uint48(uint256 input_) internal pure returns (uint48 output_) {
        require(input_ <= type(uint48).max, "TLM:UINT48_CAST_OOB");
        output_ = uint48(input_);
    }

    function _uint112(uint256 input_) internal pure returns (uint112 output_) {
        require(input_ <= type(uint112).max, "TLM:UINT112_CAST_OOB");
        output_ = uint112(input_);
    }

    function _uint128(uint256 input_) internal pure returns (uint128 output_) {
        require(input_ <= type(uint128).max, "TLM:UINT128_CAST_OOB");
        output_ = uint128(input_);
    }

}
