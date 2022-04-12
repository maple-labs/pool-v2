// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like } from "./interfaces/Interfaces.sol";

/// @dev Heavily borrowed from Loan
contract GenericInvestmentVehicle {

    uint256 private constant SCALED_ONE = 1e18;
    
    uint256 public interestRate;
    uint256 public paymentInterval;
    uint256 public principal;
    uint256 public startingTime;

    address public asset;
    address public pool;

    bool public lastPayment;

    constructor(uint256 principal_, uint256 interestRate_, uint256 paymentInterval_, address pool_, address asset_) {
        interestRate    = interestRate_;
        paymentInterval = paymentInterval_;
        principal       = principal_;
        asset           = asset_;
        pool            = pool_;
    }

    function setLastPayment(bool status) external {
        lastPayment = status;
    }

    /// @dev naive implementation
    function fund() external returns (uint256 interestForPeriod_, uint256 periodEnd_) {
        require(msg.sender == pool, "not pool");

        interestForPeriod_ = _getInterest(principal, interestRate, paymentInterval);
        periodEnd_         = block.timestamp + paymentInterval;

        startingTime = block.timestamp;
    }

    function claim() external returns (uint256 interest_, uint256 principal_, uint256 nextPayment_) {
        require(msg.sender == pool, "not pool");

        // Assuming correct timing
        interest_    = _getInterest(principal, interestRate, paymentInterval);
        nextPayment_ =  lastPayment ? 0 : block.timestamp + paymentInterval;
        principal_   =  lastPayment ? principal : 0; // Using open ended IV for now

        // Obviously insecure
        IERC20Like(asset).transfer(msg.sender, interest_ + principal_);
    }

    /// @dev Returns an amount by applying an annualized and scaled interest rate, to a principal, over an interval of time.
    function _getInterest(uint256 principal_, uint256 interestRate_, uint256 interval_) internal pure returns (uint256 interest_) {
        return (principal_ * interestRate_ * interval_) / (uint256(365 days) * SCALED_ONE);
    }

}
