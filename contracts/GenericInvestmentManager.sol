// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20Like, IInvestmentManagerLike, IInvestmentVehicleLike } from "./interfaces/Interfaces.sol";

/// @dev Heavily borrowed from Loan
contract GenericInvestmentManager is IInvestmentManagerLike {

    address public pool;

    function claim(address investment_) external override 
        returns (
            uint256 principal_, 
            uint256 interestAdded_, 
            uint256 interestRemoved_, 
            uint256 nextPaymentDate_
        ) 
    {
        ( 
            principal_, 
            interestAdded_, 
            interestRemoved_, 
            nextPaymentDate_ 
        ) = IInvestmentVehicleLike(investment_).claim();
    }

    function closeInvestment(address investment_) external override returns (uint256 expectedPrincipal, uint256 principal_, uint256 interest_) {
        // TODO: decide how to properly close accounting
    }

    function expectedInterest(address investment_) external view override returns (uint256 interest_) {
        interest_ = IInvestmentVehicleLike(investment_).expectedInterest();
    }

    /// @dev Naive implementation
    function fund(address investment_) external override returns (uint256 interestForPeriod_, uint256 periodEnd_) {
        ( interestForPeriod_, periodEnd_ ) = IInvestmentVehicleLike(investment_).fund();
    }

}
