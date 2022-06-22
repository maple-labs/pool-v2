// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { console } from "../modules/contract-test-utils/contracts/log.sol";

import { IPool } from "./Pool.sol";

import { ERC20Helper } from "../modules/erc20-helper/src/ERC20Helper.sol";

import { IInvestmentManagerLike, IPoolCoverManagerLike } from "./interfaces/Interfaces.sol";

import { IPoolManager } from "./interfaces/IPoolManager.sol";

contract PoolManager is IPoolManager {

    uint256 public immutable override precision;  // Precision of rates, equals max deposit amounts before rounding errors occur

    address public owner;
    address public override pool;
    address public override poolCoverManager;
    address public withdrawalManager;

    // Maybe those variables should go in the pool?
    uint256 public interestOut;
    uint256 public override principalOut;
    uint256 public override unrealizedLosses;

    uint256 public freeAssets;            // Amount of assets unlocked regardless of time passed.
    uint256 public override issuanceRate; // asset/second rate dependent on aggregate vesting schedule.
    uint256 public lastUpdated;           // Timestamp of when issuance equation was last updated.
    uint256 public vestingPeriodFinish;   // Timestamp when current vesting schedule ends.

    mapping (address => bool)    public isInvestmentManager;
    mapping (address => address) public investmentManagers;

    constructor(address owner_, uint256 precision_) {
        owner     = owner_;      // Naive acl for now
        precision = precision_;  // TODO: Should we just hardcode this to 1e30?
    }

    /******************************/
    /*** Administrative Setters ***/
    /******************************/

    function setInvestmentManager(address investmentManager_, bool isValid) external override {
        require(msg.sender == owner, "PM:SIM:NOT_OWNER");
        isInvestmentManager[investmentManager_] = isValid;
    }

    // TODO: Revisit to see if there is a better approach
    function setPool(address pool_) external override {
        require(address(pool) == address(0), "PM:SP:POOL_SET");
        pool = pool_;
    }

    function setPoolCoverManager(address poolCoverManager_) external override {
        require(msg.sender == owner, "PM:SPCM:NOT_OWNER");
        poolCoverManager = poolCoverManager_;
    }

    function setWithdrawalManager(address withdrawalManager_) external override {
        require(msg.sender == owner, "PM:SWM:NOT_OWNER");
        withdrawalManager = withdrawalManager_;
    }

    /****************************/
    /*** Investment Functions ***/
    /****************************/
    // Based on existing implementation for IM, but should be catared to the final solution

    function claim(address investment_) external override {
        require(IPool(pool).totalSupply() != 0, "P:F:ZERO_SUPPLY");

        // Claim funds, moving funds into pool
        (
            principalOut,
            freeAssets,
            issuanceRate,
            vestingPeriodFinish
        ) = IInvestmentManagerLike(investmentManagers[investment_]).claim(investment_);
    }

    function decreaseTotalAssets(uint256 decrement_) external override returns (uint256 newTotalAssets_) {
        // TODO: ACL
        
        freeAssets = newTotalAssets_ = totalAssets() - decrement_;
    }
    
    function decreaseUnrealizedLosses(uint256 decrement_) external override returns (uint256 remainingUnrealizedLosses_) {
        // TODO: ACL
        
        unrealizedLosses -= decrement_;
        remainingUnrealizedLosses_ = unrealizedLosses;
    }

    function fund(uint256 amountOut_, address investment_, address investmentManager_) external override {
        require(msg.sender == owner,                     "PM:F:NOT_OWNER");
        require(IPool(pool).totalSupply() != 0,          "PM:F:ZERO_SUPPLY");
        require(isInvestmentManager[investmentManager_], "PM:F:IM_INVALID");

        // NOTE This contracts needs infinite allowance of asset from pool. Or do a 2 step transfer
        require(ERC20Helper.transferFrom(IPool(pool).asset(), address(pool), investment_, amountOut_), "P:F:TRANSFER_FAILED");

        investmentManagers[investment_] = investmentManager_;

        // Fund loan, getting information from InvestmentManager on how to update issuance params
        ( principalOut, freeAssets, issuanceRate, vestingPeriodFinish ) = IInvestmentManagerLike(investmentManager_).fund(investment_);
    }

    function triggerCollateralLiquidation(address investment_) external override {
        unrealizedLosses += IInvestmentManagerLike(investmentManagers[investment_]).triggerCollateralLiquidation(investment_);
    }

    function finishCollateralLiquidation(address investment_) external override returns (uint256 remainingLosses_) {
        uint256 decreasedUnrealizedLosses;
        ( decreasedUnrealizedLosses, remainingLosses_ ) = IInvestmentManagerLike(investmentManagers[investment_]).finishCollateralLiquidation(investment_);

        unrealizedLosses -= decreasedUnrealizedLosses;

        // TODO: Dust threshold?
        if (remainingLosses_ > 0) {
            IPoolCoverManagerLike(poolCoverManager).triggerCoverLiquidation(remainingLosses_);
        }
    }

    // function finishCoverLiquidation(address poolCoverReserve_) external {
    //     IPoolCoverManagerLike(poolCoverManager).finishLiquidation
    // }

    /**********************/
    /*** Exit Functions ***/
    /**********************/

    function redeem(uint256 shares_, address receiver_, address owner_) external returns (uint256 assets_) {
        require(msg.sender == withdrawalManager, "PM:R:NOT_WM");
        return IPool(pool).redeem(shares_, receiver_, owner_);
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function totalAssets() public view virtual override returns (uint256 totalManagedAssets_) {
        uint256 issuanceRate_ = issuanceRate;

        if (issuanceRate_ == 0) return freeAssets;

        uint256 vestingPeriodFinish_ = vestingPeriodFinish;
        uint256 lastUpdated_         = lastUpdated;

        uint256 vestingTimePassed =
            block.timestamp > vestingPeriodFinish_ ?
                vestingPeriodFinish_ - lastUpdated_ :
                block.timestamp - lastUpdated_;

        return ((issuanceRate_ * vestingTimePassed) / precision) + freeAssets;
    }

    function totalAssetsWithUnrealizedLoss() external view override returns (uint256 totalAssetsWithUnrealizedLoss_) {
        return totalAssets() - unrealizedLosses;
    }

}
