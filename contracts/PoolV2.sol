// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC4626, IRevenueDistributionToken }          from "../modules/revenue-distribution-token/contracts/interfaces/IRevenueDistributionToken.sol";
import { ERC20, ERC20Helper, RevenueDistributionToken } from "../modules/revenue-distribution-token/contracts/RevenueDistributionToken.sol";

import { IInvestmentVehicle } from "./interfaces/Interfaces.sol";
import { IPoolV2 }            from "./interfaces/IPoolV2.sol";


contract PoolV2 is IPoolV2, RevenueDistributionToken {

    address public withdrawalManager;

    uint256 public interestOut;
    uint256 public principalOut;   // Full amount of principal that's not currently on the pool

    constructor(string memory name_, string memory symbol_, address owner_, address asset_, uint256 precision_)
        RevenueDistributionToken(name_, symbol_, owner_, asset_, precision_) { }

    function setWithdrawalManager(address withdrawalManager_) external {
        // TODO: ACL
        withdrawalManager = withdrawalManager_;
    }

    /// @dev Fund an investment opportunity. Maybe this should be the new updateVestingSchedule?
    function fund(uint256 amountOut_, address investment) external returns (uint256 issuanceRate_,  uint256 freeAssets_) {
        require(msg.sender == owner, "P:F:NOT_OWNER");
        require(totalSupply != 0,    "P:F:ZERO_SUPPLY");

        ( uint256 interestForPeriod_, uint256 periodEnd_ ) = IInvestmentVehicle(investment).fund();

        // totalAmount += profit;
        principalOut += amountOut_;
        interestOut  += interestForPeriod_;

        freeAssets_ = freeAssets = totalAssets();
        lastUpdated = block.timestamp;

        // Update period finish only if it's the latest investment to be concluded
        uint256 currentFinish = vestingPeriodFinish;
        vestingPeriodFinish = periodEnd_ > currentFinish ? periodEnd_ : currentFinish; //TODO: current finish can be in the past

        // Calculate the new issuance rate using the new amount out and the time to all loans to mature
        issuanceRate_ = issuanceRate = interestOut * precision / (periodEnd_ - block.timestamp);

        emit IssuanceParamsUpdated(freeAssets_, issuanceRate_);
        emit VestingScheduleUpdated(msg.sender, vestingPeriodFinish);

        // Send funds
        require(ERC20Helper.transfer(asset, investment, amountOut_), "GIV:F:TRANSFER_FAILED");
    }


    /// @dev Claim proceeds of an investment opportunity
    /// Need to break apart what's "principal" and what's interest
    function claim(address investment_) external {

        ( uint256 interest_, uint256 principal_, uint256 nextPayment_ ) = IInvestmentVehicle(investment_).claim();

        // Very loose accounting
        principalOut -= principal_;

        // This is weird, but at the same time the pool is receiving an interest payment, it's also "funding" for another period. This impl assumes regular periods and interest
        if (nextPayment_ == 0) {
            interestOut -= interest_;
        }

        freeAssets  = totalAssets();
        lastUpdated = block.timestamp;

        uint256 currentFinish = vestingPeriodFinish;
        vestingPeriodFinish = nextPayment_ <= currentFinish ? currentFinish : nextPayment_ ; //TODO: current finish can be in the past

        // When claiming, the end date of the last investiment to mature does not change
        issuanceRate = vestingPeriodFinish > block.timestamp ? interestOut * precision / (vestingPeriodFinish - block.timestamp) : 0;

        // TODO: Research the best way to move funds between pool and IV. Currently is being transferred from IV to Pool in `claim`
    }

    function redeem(uint256 shares_, address receiver_, address owner_) external override(IERC4626, RevenueDistributionToken) nonReentrant returns (uint256 assets_) {
        require(msg.sender == withdrawalManager, "P:R:NOT_WM");
        _burn(shares_, assets_ = previewRedeem(shares_), receiver_, owner_, msg.sender);
    }

    function withdraw(uint256 assets_, address receiver_, address owner_) external override(IERC4626, RevenueDistributionToken) nonReentrant returns (uint256 shares_) {
       require(msg.sender == withdrawalManager, "P:W:NOT_WM");
        _burn(shares_ = previewWithdraw(assets_), assets_, receiver_, owner_, msg.sender);
    }

    function updateVestingSchedule(uint256) external virtual override(IRevenueDistributionToken, RevenueDistributionToken) returns (uint256 issuanceRate_, uint256 freeAssets_) {
        // Explicitly locking this function because it'll cause issues with the pool's value calculation.
        require(false);
    }

}
