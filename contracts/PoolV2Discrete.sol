// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC4626, IRevenueDistributionToken }          from "../modules/revenue-distribution-token/contracts/interfaces/IRevenueDistributionToken.sol";
import { ERC20, ERC20Helper, RevenueDistributionToken } from "../modules/revenue-distribution-token/contracts/RevenueDistributionToken.sol";

import { IInvestmentManagerLike, IPoolCoverManagerLike } from "./interfaces/Interfaces.sol";
import { IPoolV2 }                                       from "./interfaces/IPoolV2.sol";

contract PoolV2Discrete is IPoolV2, RevenueDistributionToken {

    address public poolCoverManager;
    address public withdrawalManager;
    address public investmentManager;      // TODO: Change to a mapping to allow different investment managers

    uint256 public override interestOut;
    uint256 public override principalOut;  // Full amount of principal that's not currently on the pool

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

    function setInvestmentManager(address investmentManager_) external override {
        // TODO: ACL
        investmentManager = investmentManager_;
    }

    /**************************/
    /*** External Functions ***/
    /**************************/

    /// @dev Claim proceeds of an investment opportunity
    /// Need to break apart what's "principal" and what's interest
    function claim(address investment_) external override {
        IInvestmentManagerLike manager = IInvestmentManagerLike(investmentManager);

        uint256 expectedInterest = manager.expectedInterest(investment_);

        ( uint256 principalBack, uint256 interestAdded, uint256 interestReturned, uint256 nextDate ) = manager.claim(investment_);

        // Very loose accounting
        principalOut -= principalBack;
        interestOut   = interestOut + interestAdded - interestReturned;

        if (interestReturned > expectedInterest) {
            // Incorporate the difference into free assets
            freeAssets += interestReturned - expectedInterest;
        } else if (expectedInterest > interestReturned) {
            // TODO: Handle short of interest
        }
  
        // TODO: If nextDate == 0, IV need to be closed by PD
        _updateVesting(interestOut, nextDate);

        // TODO: Research the best way to move funds between pool and IV. Currently is being transferred from IV to Pool in `claim`

        // Send a portion of the interest to the pool cover manager.
        _distributePoolCoverAssets(interestReturned);
    }

    /// @dev Fund an investment opportunity. Maybe this should be the new updateVestingSchedule?
    function fund(uint256 amountOut_, address investment_) external override returns (uint256 issuanceRate_) {
        require(msg.sender == owner, "P:F:NOT_OWNER");
        require(totalSupply != 0,    "P:F:ZERO_SUPPLY");

        require(ERC20Helper.transfer(asset, investment_, amountOut_), "GIV:F:TRANSFER_FAILED");
        
        // TODO: Funds need to be sent beforehand, otherwise the call to loan fails. Research a more robust flow of money
        ( uint256 interestAdded_, uint256 periodEnd_ ) = IInvestmentManagerLike(investmentManager).fund(investment_);

        principalOut += amountOut_;
        interestOut  += interestAdded_;

        _updateVesting(interestOut, periodEnd_);
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

    function _updateVesting(uint256 vestingAmount_, uint256 periodEnd_) internal returns (uint256 issuanceRate_) {
        uint256 freeAssets_ = freeAssets  = totalAssets();
        
        lastUpdated = block.timestamp;

        // Update period finish only if it's the latest investment to be concluded
        uint256 currentFinish = vestingPeriodFinish;
        vestingPeriodFinish = periodEnd_ > currentFinish ? periodEnd_ : currentFinish; //TODO: Current finish can be in the past

        // Calculate the new issuance rate using the new amount out and the time to all loans to mature
        issuanceRate_ = issuanceRate = block.timestamp >= vestingPeriodFinish ? 0 :
            vestingAmount_ * precision / (vestingPeriodFinish - block.timestamp);

        emit IssuanceParamsUpdated(freeAssets_, issuanceRate_);
        emit VestingScheduleUpdated(msg.sender, vestingPeriodFinish);
    }

}
