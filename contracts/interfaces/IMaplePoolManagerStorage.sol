// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

interface IMaplePoolManagerStorage {

    /**
     *  @dev    Returns whether or not a pool is active.
     *  @return active_ True if the pool is active.
     */
    function active() external view returns (bool active_);

    /**
     *  @dev    Gets the address of the funds asset.
     *  @return asset_ The address of the funds asset.
     */
    function asset() external view returns (address asset_);

    /**
     *  @dev    Returns whether or not a pool is configured.
     *  @return configured_ True if the pool is configured.
     */
    function configured() external view returns (bool configured_);

    /**
     *  @dev    Gets the delegate management fee rate.
     *  @return delegateManagementFeeRate_ The value for the delegate management fee rate.
     */
    function delegateManagementFeeRate() external view returns (uint256 delegateManagementFeeRate_);

    /**
     *  @dev    Returns whether or not the given address is a strategy.
     *  @param  strategy_   The address of the strategy.
     *  @return isStrategy_ True if the address is a strategy.
     */
    function isStrategy(address strategy_) external view returns (bool isStrategy_);

    /**
     *  @dev    Gets the liquidity cap for the pool.
     *  @return liquidityCap_ The liquidity cap for the pool.
     */
    function liquidityCap() external view returns (uint256 liquidityCap_);

    /**
     *  @dev    Gets the address of the strategy in the list.
     *  @param  index_    The index to get the address of.
     *  @return strategy_ The address in the list.
     */
    function strategyList(uint256 index_) external view returns (address strategy_);

    /**
     *  @dev    Gets the address of the pending pool delegate.
     *  @return pendingPoolDelegate_ The address of the pending pool delegate.
     */
    function pendingPoolDelegate() external view returns (address pendingPoolDelegate_);

    /**
     *  @dev    Gets the address of the pool.
     *  @return pool_ The address of the pool.
     */
    function pool() external view returns (address pool_);

    /**
     *  @dev    Gets the address of the pool delegate.
     *  @return poolDelegate_ The address of the pool delegate.
     */
    function poolDelegate() external view returns (address poolDelegate_);

    /**
     *  @dev    Gets the address of the pool delegate cover.
     *  @return poolDelegateCover_ The address of the pool delegate cover.
     */
    function poolDelegateCover() external view returns (address poolDelegateCover_);

    /**
     *  @dev    Gets the address of the pool delegate cover.
     *  @return poolPermissionManager_ The address of the pool permission manager.
     */
    function poolPermissionManager() external view returns (address poolPermissionManager_);

    /**
     *  @dev    Gets the address of the withdrawal manager.
     *  @return withdrawalManager_ The address of the withdrawal manager.
     */
    function withdrawalManager() external view returns (address withdrawalManager_);

}
