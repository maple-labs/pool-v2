// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface IERC20Like {

    function approve(address spender_, uint256 amount_) external;

    function transfer(address destination_, uint256 amount_) external;
    
}

interface IInvestmentVehicle {

    function fund() external returns (uint256 interestForPeriod_, uint256 periodEnd_);

    function claim() external returns (uint256 interest_, uint256 principal_, uint256 nextPayment_);

}
