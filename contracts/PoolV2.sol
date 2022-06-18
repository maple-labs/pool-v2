// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC4626, IRevenueDistributionToken }          from "../modules/revenue-distribution-token/contracts/interfaces/IRevenueDistributionToken.sol";
import { ERC20, ERC20Helper, RevenueDistributionToken } from "../modules/revenue-distribution-token/contracts/RevenueDistributionToken.sol";

import { IInvestmentManagerLike, IPoolCoverManagerLike } from "./interfaces/Interfaces.sol";
import { IPoolV2 }                                       from "./interfaces/IPoolV2.sol";

contract PoolV2 is IPoolV2, RevenueDistributionToken {

    address public poolCoverManager;
    address public withdrawalManager;
    address public investmentManager;      // TODO: Change to a mapping to allow different investment managers

    uint256 public override interestOut;
    uint256 public override principalOut;  // Full amount of principal that's not currently on the pool
    uint256 public override unrealizedLosses;

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

    function decreaseUnrealizedLosses(uint256 decrement_) external override {
        require(isInvestmentManager[msg.sender], "P:DC:NOT_IM");
        unrealizedLosses -= decrement_;
    }

    function increaseUnrealizedLosses(uint256 increment_) external override {
        require(isInvestmentManager[msg.sender], "P:IC:NOT_IM");
        unrealizedLosses += increment_;
    }

    /*****************/
    /*** Overrides ***/
    /*****************/

    function previewRedeem(uint256 shares_) public view virtual override(IERC4626, RevenueDistributionToken) returns (uint256 assets_) {
        // As per https://eips.ethereum.org/EIPS/eip-4626#security-considerations,
        // it should round DOWN if it’s calculating the amount of assets to send to a user, given amount of shares returned.
        uint256 supply = totalSupply;  // Cache to stack.

        assets_ = supply == 0 ? shares_ : (shares_ * (totalAssets() - unrealizedLosses)) / supply;
    }

    function previewWithdraw(uint256 assets_) public view virtual override(IERC4626, RevenueDistributionToken) returns (uint256 shares_) {
        uint256 supply = totalSupply;  // Cache to stack.

        // As per https://eips.ethereum.org/EIPS/eip-4626#security-considerations,
        // it should round UP if it’s calculating the amount of shares a user must return, to be sent a given amount of assets.
        shares_ = supply == 0 ? assets_ : _divRoundUp(assets_ * supply, (totalAssets() - unrealizedLosses));
    }

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
        IPoolCoverManagerLike(poolCoverManager).allocateLiquidity();
    }

    function _updateVesting(uint256 issuanceRate_, uint256 vestingPeriodFinish_) internal {
        uint256 freeAssets_ = freeAssets = totalAssets();

        lastUpdated = block.timestamp;

        // Calculate the new issuance rate using the new amount out and the time to all loans to mature
        issuanceRate        = issuanceRate_;
        vestingPeriodFinish = vestingPeriodFinish_;

        emit IssuanceParamsUpdated(freeAssets_, issuanceRate_);
        emit VestingScheduleUpdated(msg.sender, vestingPeriodFinish);
    }

}
