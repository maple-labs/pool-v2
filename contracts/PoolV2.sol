// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC4626, IRevenueDistributionToken }          from "../modules/revenue-distribution-token/contracts/interfaces/IRevenueDistributionToken.sol";
import { ERC20, ERC20Helper, RevenueDistributionToken } from "../modules/revenue-distribution-token/contracts/RevenueDistributionToken.sol";

import { IInvestmentManagerLike, IPoolCoverManagerLike } from "./interfaces/Interfaces.sol";
import { IPoolV2 }                                       from "./interfaces/IPoolV2.sol";

import { console } from "../modules/contract-test-utils/contracts/log.sol";

contract PoolV2 is IPoolV2, RevenueDistributionToken {

    address public poolCoverManager;
    address public withdrawalManager;
    address public investmentManager;      // TODO: Change to a mapping to allow different investment managers

    uint256 public override interestOut;
    uint256 public override principalOut;  // Full amount of principal that's not currently on the pool

    mapping (address => bool) isInvestmentManager;

    mapping (address => address) investmentManagers;

    constructor(string memory name_, string memory symbol_, address owner_, address asset_, uint256 precision_)
        RevenueDistributionToken(name_, symbol_, owner_, asset_, precision_) { }

    /******************************/
    /*** Administrative Setters ***/
    /******************************/

    function setWithdrawalManager(address withdrawalManager_) external {
        // TODO: ACL
        withdrawalManager = withdrawalManager_;
    }

    function setPoolCoverManager(address poolCoverManager_) external {
        // TODO: ACL
        poolCoverManager = poolCoverManager_;
    }

    function setInvestmentManager(address investmentManager_, bool isValid) external override {
        // TODO: ACL
        isInvestmentManager[investmentManager_] = isValid;
    }

    /**************************/
    /*** External Functions ***/
    /**************************/

    function claim(address investment_) external {
        require(totalSupply != 0, "P:F:ZERO_SUPPLY");

        // Update vesting schedule based on claim results
        freeAssets = totalAssets();

        // Claim funds, moving funds into pool
        (
            uint256 principalOut_,
            uint256 freeAssets_,
            uint256 issuanceRate_,
            uint256 vestingPeriodFinish_
        ) = IInvestmentManagerLike(investmentManagers[investment_]).claim(investment_);

        // Update vesting schedule based on claim results
        _updateVesting(issuanceRate_, vestingPeriodFinish_);

        // Decrement principalOut, increment freeAssets by any discrepancy between expected and actual interest paid
        principalOut = principalOut_;
        freeAssets   = freeAssets_;
    }

    function fund(uint256 amountOut_, address investment_, address investmentManager_) external override returns (uint256 issuanceRate_) {
        require(msg.sender == owner,                     "P:F:NOT_OWNER");
        require(totalSupply != 0,                        "P:F:ZERO_SUPPLY");
        require(isInvestmentManager[investmentManager_], "P:F:IM_INVALID");

        require(ERC20Helper.transfer(asset, investment_, amountOut_), "P:F:TRANSFER_FAILED");

        investmentManagers[investment_] = investmentManager_;

        // Fund loan, getting information from InvestmentManager on how to update issuance params
        ( uint256 issuanceRate, uint256 vestingPeriodFinish_ ) = IInvestmentManagerLike(investmentManager_).fund(investment_);

        // Update pool accounting state
        principalOut += amountOut_;
        issuanceRate_ = issuanceRate;

        _updateVesting(issuanceRate, vestingPeriodFinish_);
    }

    /*****************/
    /*** Overrides ***/
    /*****************/

    function redeem(uint256 shares_, address receiver_, address owner_) external override(IERC4626, RevenueDistributionToken) nonReentrant returns (uint256 assets_) {
        require(msg.sender == withdrawalManager, "P:R:NOT_WM");
        _burn(shares_, assets_ = previewRedeem(shares_), receiver_, owner_, msg.sender);
    }

    function updateVestingSchedule(uint256) external virtual override(IRevenueDistributionToken, RevenueDistributionToken) returns (uint256 issuanceRate_, uint256 freeAssets_) {
        // Explicitly locking this function because it'll cause issues with the pool's value calculation.
        require(false);
    }

    function withdraw(uint256 assets_, address receiver_, address owner_) external override(IERC4626, RevenueDistributionToken) nonReentrant returns (uint256 shares_) {
       require(msg.sender == withdrawalManager, "P:W:NOT_WM");
        _burn(shares_ = previewWithdraw(assets_), assets_, receiver_, owner_, msg.sender);
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _distributePoolCoverAssets(uint256 interest_) internal {
        // Check if the pool cover manager has been set.
        // TODO: Should this revert instead?
        if (poolCoverManager == address(0)) return;

        // Calculate the portion of interest that goes towards all pool cover (currently hardcoded to 20%).
        // TODO: Read the cover percentage from somewhere and make it configurable.
        uint256 assets = 0.2e18 * interest_ / 1e18;

        // Transfer the assets (if any exist) to the pool cover manager.
        require(assets == 0 || ERC20Helper.transfer(asset, poolCoverManager, assets));

        // Trigger distribution of all transferred assets.
        IPoolCoverManagerLike(poolCoverManager).distributeAssets();
    }

    function _updateVesting(uint256 issuanceRate_, uint256 vestingPeriodFinish_) internal {
        uint256 freeAssets_ = freeAssets = totalAssets();

        lastUpdated = block.timestamp;

        // console.log("vestingPeriodFinish_ 3", vestingPeriodFinish == 0 ? 0 : (vestingPeriodFinish - 1622400000) * 100 / 1 days);

        // Calculate the new issuance rate using the new amount out and the time to all loans to mature
        issuanceRate        = issuanceRate_;
        vestingPeriodFinish = vestingPeriodFinish_;

        // console.log("vestingPeriodFinish_ 4", (vestingPeriodFinish - 1622400000) * 100 / 1 days);

        emit IssuanceParamsUpdated(freeAssets_, issuanceRate_);
        emit VestingScheduleUpdated(msg.sender, vestingPeriodFinish);
    }

}
