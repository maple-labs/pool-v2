// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

// TODO: Leaving this interface definition loose while we are rapidly iterating.
interface IPoolManager {

    function claim(address investment_) external;

    function decreaseTotalAssets(uint256 decrement_) external returns (uint256 newTotalAssets_);

    function decreaseUnrealizedLosses(uint256 decrement_) external returns (uint256 remainingUnrealizedLosses_);

    function finishCollateralLiquidation(address investment_) external returns (uint256 remainingLosses_);

    function fund(uint256 amountOut_, address investment_, address investmentManager_) external;

    function issuanceRate() external view returns (uint256 issuanceRate_);

    function pool() external view returns (address pool_);

    function poolCoverManager() external view returns (address poolCoverManager_);

    function precision() external view returns (uint256 precision_);

    function principalOut() external view returns (uint256 principalOut_);

    function setInvestmentManager(address investmentManager_, bool isValid) external;

    function setPoolCoverManager(address poolCoverManager_) external ;

    function setWithdrawalManager(address withdrawalManager_) external;

    function setPool(address pool_) external;
    
    function totalAssetsWithUnrealizedLoss() external view returns (uint256 totalAssetsWithUnrealizedLoss_);

    function totalAssets() external view returns (uint256 totalAssets_);

    function triggerCollateralLiquidation(address investment_) external;

    function unrealizedLosses() external view returns (uint256 unrealizedLosses_);

}