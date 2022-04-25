// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentVehicleLike } from "../../contracts/interfaces/Interfaces.sol";

/// @dev Heavily borrowed from Loan
contract MockInvestmentVehicle is IInvestmentVehicleLike {

    uint256 private constant SCALED_ONE = 1e18;
    
    uint256 public interestRate;
    uint256 public lastClaim;
    uint256 public nextPayment;
    uint256 public paymentInterval;
    uint256 public principal;

    address public asset;
    address public investmentManager;
    address public pool;

    bool public lastPayment;

    constructor(uint256 principal_, uint256 interestRate_, uint256 paymentInterval_, address pool_, address asset_, address investmentManager_) {
        interestRate      = interestRate_;
        paymentInterval   = paymentInterval_;
        principal         = principal_;
        asset             = asset_;
        pool              = pool_;
        investmentManager = investmentManager_;
    }

    function setLastPayment(bool status) external {
        lastPayment = status;
    }

    function claim() external override returns (uint256 principal_, uint256 interestAdded_, uint256 interestRemoved_, uint256 nextPaymentDate_) {
        require(msg.sender == investmentManager, "MIV:C:NOT_IM");

        // Assuming correct timing
        uint256 interest_ = _getInterest(principal, interestRate, paymentInterval);

        interestRemoved_ = interest_;
        interestAdded_   = lastPayment ? 0         : interest_;
        nextPayment      = lastPayment ? 0         : nextPayment + paymentInterval;
        principal_       = lastPayment ? principal : 0; // Using open ended IV for now
        nextPaymentDate_ = nextPayment;

        lastClaim = block.timestamp;

        // Obviously insecure
        IERC20Like(asset).transfer(pool, interest_ + principal_);
    }

    function close() external override returns (uint256 expectedPrincipal, uint256 principal_, uint256 interest_) {

    }

    function expectedInterest() external view override returns (uint256 interest_) {
        return _getInterest(principal, interestRate, block.timestamp - lastClaim);
    }

    /// @dev naive implementation
    function fund() external override returns (uint256 interestForPeriod_, uint256 periodEnd_) {
        require(msg.sender == investmentManager, "MIV:C:NOT_IM");

        interestForPeriod_ = _getInterest(principal, interestRate, paymentInterval);
        periodEnd_         = block.timestamp + paymentInterval;

        nextPayment = block.timestamp + paymentInterval;
        lastClaim   = block.timestamp;
    }

    /// @dev Returns an amount by applying an annualized and scaled interest rate, to a principal, over an interval of time.
    function _getInterest(uint256 principal_, uint256 interestRate_, uint256 interval_) internal pure returns (uint256 interest_) {
        return (principal_ * interestRate_ * interval_) / (uint256(365 days) * SCALED_ONE);
    }

}
