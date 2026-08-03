// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IMapleProxied } from "../../modules/maple-proxy-factory/contracts/interfaces/IMapleProxied.sol";

import { IMaplePoolManagerStorage } from "./IMaplePoolManagerStorage.sol";

interface IMaplePoolManager is IMapleProxied, IMaplePoolManagerStorage {

    /**************************************************************************************************************************************/
    /*** Events                                                                                                                         ***/
    /**************************************************************************************************************************************/

    /**
     *  @dev   Emitted when a collateral liquidations is finished.
     *  @param loan_             The address of the loan.
     *  @param unrealizedLosses_ The amount of unrealized losses.
     */
    event CollateralLiquidationFinished(address indexed loan_, uint256 unrealizedLosses_);

    /**
     *  @dev   Emitted when a new management fee rate is set.
     *  @param managementFeeRate The amount of management fee rate.
     */
    event DelegateManagementFeeRateSet(uint256 managementFeeRate);

    /**
     *  @dev   Emitted when a new liquidity cap is set.
     *  @param liquidityCap The value of liquidity cap.
     */
    event LiquidityCapSet(uint256 liquidityCap);

    /**
     *  @dev   Emitted when a new strategy is added.
     *  @param strategy The address of the new strategy.
     */
    event StrategyAdded(address indexed strategy);

    /**
     *  @dev   Emitted when the pool's AUM exposure cap to a strategy is set.
     *  @param strategy The address of the strategy.
     *  @param cap      The pool's AUM exposure cap to the strategy.
     */
    event StrategyCapSet(address indexed strategy, uint256 cap);

    /**
     *  @dev   Emitted when a strategy manager is registered with the pool.
     *  @param strategyManager The address of the strategy manager.
     */
    event StrategyManagerAdded(address indexed strategyManager);

    /**
     *  @dev   Emitted when a strategy manager is removed from the pool.
     *  @param strategyManager The address of the strategy manager.
     */
    event StrategyManagerRemoved(address indexed strategyManager);

    /**
     *  @dev   Emitted when the pending pool delegate accepts the ownership transfer.
     *  @param previousDelegate The address of the previous delegate.
     *  @param newDelegate      The address of the new delegate.
     */
    event PendingDelegateAccepted(address indexed previousDelegate, address indexed newDelegate);

    /**
     *  @dev   Emitted when the pending pool delegate is set.
     *  @param previousDelegate The address of the previous delegate.
     *  @param newDelegate      The address of the new delegate.
     */
    event PendingDelegateSet(address indexed previousDelegate, address indexed newDelegate);

    /**
     *  @dev Emitted when the pool configuration is marked as complete.
     */
    event PoolConfigurationComplete();

    /**
     *  @dev   Emitted when the pool permission manager is set.
     *  @param poolPermissionManager The address of the pool permission manager.
     */
    event PoolPermissionManagerSet(address indexed poolPermissionManager);

    /**
     *  @dev   Emitted when a redemption of shares from the pool is processed.
     *  @param owner            The owner of the shares.
     *  @param redeemableShares The amount of redeemable shares.
     *  @param resultingAssets  The amount of assets redeemed.
     */
    event RedeemProcessed(address indexed owner, uint256 redeemableShares, uint256 resultingAssets);

    /**
     *  @dev   Emitted when a redemption of shares from the pool is requested.
     *  @param owner  The owner of the shares.
     *  @param shares The amount of redeemable shares.
     */
    event RedeemRequested(address indexed owner, uint256 shares);

    /**
     *  @dev   Emitted when a pool is sets to be active or inactive.
     *  @param active Whether the pool is active.
     */
    event SetAsActive(bool active);

    /**
     *  @dev   Emitted when shares are removed from the pool.
     *  @param owner  The address of the owner of the shares.
     *  @param shares The amount of shares removed.
     */
    event SharesRemoved(address indexed owner, uint256 shares);

    /**
     *  @dev   Emitted when the withdrawal manager is set.
     *  @param withdrawalManager The address of the withdrawal manager.
     */
    event WithdrawalManagerSet(address indexed withdrawalManager);

    /**************************************************************************************************************************************/
    /*** Ownership Transfer Functions                                                                                                   ***/
    /**************************************************************************************************************************************/

    /**
     *  @dev Accepts the role of pool delegate.
     */
    function acceptPoolDelegate() external;

    /**
     *  @dev   Sets an address as the pending pool delegate.
     *  @param pendingPoolDelegate The address of the new pool delegate.
     */
    function setPendingPoolDelegate(address pendingPoolDelegate) external;

    /**************************************************************************************************************************************/
    /*** Administrative Functions                                                                                                       ***/
    /**************************************************************************************************************************************/

    /**
     *  @dev    Adds a new strategy.
     *          NOTE: The PoolManager address is encoded and prepended to the extraDeploymentData.
     *  @param  strategyFactory     The address of the strategy factory to use.
     *  @param  salt                The salt used by the factory to deploy the strategy instance.
     *  @param  extraDeploymentData The data to construct the strategy.
     *  @return strategy            The address of the new strategy.
     */
    function addStrategy(address strategyFactory, bytes32 salt, bytes calldata extraDeploymentData) external returns (address strategy);

    /**
     *  @dev   Registers an already-deployed strategy manager with the pool.
     *         Callable by any caller while the pool manager is not yet configured (typically during deployment).
     *         Once `completeConfiguration()` has been called, only the governor (timelock-gated) may call this function.
     *  @param strategyManager The address of the strategy manager.
     */
    function addStrategyManager(address strategyManager) external;

    /**
     *  @dev   Allows EOAs to batch admin calls.
     *  @param data Array of calldata.
     */
    function multicall(bytes[] calldata data) external;

    /**
     *  @dev   Removes a strategy manager from the pool and clears its strategy cap.
     *         Only callable by the operational admin after this pool manager has no assets in the strategy manager.
     *  @param strategyManager The address of the strategy manager.
     */
    function removeStrategyManager(address strategyManager) external;

    /**
     *  @dev Complete the configuration.
     */
    function completeConfiguration() external;

    /**
     *  @dev   Sets a the pool to be active or inactive.
     *  @param active Whether the pool is active.
     */
    function setActive(bool active) external;

    /**
     *  @dev   Sets the value for the delegate management fee rate.
     *  @param delegateManagementFeeRate The value for the delegate management fee rate.
     */
    function setDelegateManagementFeeRate(uint256 delegateManagementFeeRate) external;

    /**
     *  @dev   Sets the value for liquidity cap.
     *  @param liquidityCap The value for liquidity cap.
     */
    function setLiquidityCap(uint256 liquidityCap) external;

    /**
     *  @dev   Sets the pool's AUM exposure cap to a strategy.
     *         The strategy must be an instance of a valid strategy factory if the cap is non-zero.
     *  @param strategy The address of the strategy.
     *  @param cap      The pool's AUM exposure cap to the strategy.
     */
    function setStrategyCap(address strategy, uint256 cap) external;

    /**
     *  @dev   Sets the address of the pool permission manager.
     *  @param poolPermission The address of the pool permission manager.
     */
    function setPoolPermissionManager(address poolPermission) external;

    /**
     *  @dev   Sets the address of the withdrawal manager.
     *  @param withdrawalManager The address of the withdrawal manager.
     */
    function setWithdrawalManager(address withdrawalManager) external;

    /**
     *  @dev   Triggers the default of a loan held by the pool's loan manager.
     *  @param loan_ The address of the loan to default.
     */
    function triggerDefault(address loan_) external;

    /**************************************************************************************************************************************/
    /*** Funding Functions                                                                                                              ***/
    /**************************************************************************************************************************************/

    /**
     *  @dev   Strategy can request funds from the pool via the poolManager.
     *  @param destination The address to send the funds to.
     *  @param amount      Amount to fund the strategy with.
     */
    function requestFunds(address destination, uint256 amount) external;

    /**************************************************************************************************************************************/
    /*** Exit Functions                                                                                                                 ***/
    /**************************************************************************************************************************************/

    /**
     *  @dev    Processes a redemptions of shares for assets from the pool.
     *  @param  shares           The amount of shares to redeem.
     *  @param  owner            The address of the owner of the shares.
     *  @param  sender           The address of the sender of the redeem call.
     *  @return redeemableShares The amount of shares redeemed.
     *  @return resultingAssets  The amount of assets withdrawn.
     */
    function processRedeem(uint256 shares, address owner, address sender)
        external
        returns (uint256 redeemableShares, uint256 resultingAssets);

    /**
     *  @dev    Processes a redemptions of shares for assets from the pool.
     *  @param  assets           The amount of assets to withdraw.
     *  @param  owner            The address of the owner of the shares.
     *  @param  sender           The address of the sender of the withdraw call.
     *  @return redeemableShares The amount of shares redeemed.
     *  @return resultingAssets  The amount of assets withdrawn.
     */
    function processWithdraw(uint256 assets, address owner, address sender)
        external
        returns (uint256 redeemableShares, uint256 resultingAssets);

    /**
     *  @dev    Requests a redemption of shares from the pool.
     *  @param  shares         The amount of shares to redeem.
     *  @param  owner          The address of the owner of the shares.
     *  @return sharesReturned The amount of shares withdrawn.
     */
    function removeShares(uint256 shares, address owner) external returns (uint256 sharesReturned);

    /**
     *  @dev   Requests a redemption of shares from the pool.
     *  @param shares The amount of shares to redeem.
     *  @param owner  The address of the owner of the shares.
     *  @param sender The address of the sender of the shares.
     */
    function requestRedeem(uint256 shares, address owner, address sender) external;

    /**
     *  @dev   Requests a withdrawal of assets from the pool.
     *  @param shares The amount of shares to redeem.
     *  @param assets The amount of assets to withdraw.
     *  @param owner  The address of the owner of the shares.
     *  @param sender The address of the sender of the shares.
     */
     function requestWithdraw(uint256 shares, uint256 assets, address owner, address sender) external;

    /**************************************************************************************************************************************/
    /*** LP Token View Functions                                                                                                        ***/
    /**************************************************************************************************************************************/

    /**
     *  @dev    Returns the amount of exit shares for the input amount.
     *  @param  amount  Address of the account.
     *  @return shares  Amount of shares able to be exited.
     */
    function convertToExitShares(uint256 amount) external view returns (uint256 shares);

    /**
     *  @dev    Gets the information of escrowed shares.
     *  @param  owner        The address of the owner of the shares.
     *  @param  shares       The amount of shares to get the information of.
     *  @return escrowShares The amount of escrowed shares.
     *  @return destination  The address of the destination.
     */
    function getEscrowParams(address owner, uint256 shares) external view returns (uint256 escrowShares, address destination);

    /**
     *  @dev   Gets the amount of assets that can be deposited.
     *  @param receiver  The address to check the deposit for.
     *  @param maxAssets The maximum amount assets to deposit.
     */
    function maxDeposit(address receiver) external view returns (uint256 maxAssets);

    /**
     *  @dev   Gets the amount of shares that can be minted.
     *  @param receiver  The address to check the mint for.
     *  @param maxShares The maximum amount shares to mint.
     */
    function maxMint(address receiver) external view returns (uint256 maxShares);

    /**
     *  @dev   Gets the amount of shares that can be redeemed.
     *  @param owner     The address to check the redemption for.
     *  @param maxShares The maximum amount shares to redeem.
     */
    function maxRedeem(address owner) external view returns (uint256 maxShares);

    /**
     *  @dev   Gets the amount of assets that can be withdrawn.
     *  @param owner     The address to check the withdraw for.
     *  @param maxAssets The maximum amount assets to withdraw.
     */
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);

    /**
     *  @dev    Gets the amount of shares that can be redeemed.
     *  @param  owner   The address to check the redemption for.
     *  @param  shares  The amount of requested shares to redeem.
     *  @return assets  The amount of assets that will be returned for `shares`.
     */
    function previewRedeem(address owner, uint256 shares) external view returns (uint256 assets);

    /**
     *  @dev    Gets the amount of assets that can be redeemed.
     *  @param  owner   The address to check the redemption for.
     *  @param  assets  The amount of requested shares to redeem.
     *  @return shares  The amount of assets that will be returned for `assets`.
     */
    function previewWithdraw(address owner, uint256 assets) external view returns (uint256 shares);

    /**************************************************************************************************************************************/
    /*** View Functions                                                                                                                 ***/
    /**************************************************************************************************************************************/

    /**
     *  @dev    Checks if a scheduled call can be executed.
     *  @param  functionId   The function to check.
     *  @param  caller       The address of the caller.
     *  @param  data         The data of the call.
     *  @return canCall      True if the call can be executed, false otherwise.
     *  @return errorMessage The error message if the call cannot be executed.
     */
    function canCall(bytes32 functionId, address caller, bytes memory data)
        external view
        returns (bool canCall, string memory errorMessage);

    /**
     *  @dev    Gets the address of the globals.
     *  @return globals The address of the globals.
     */
    function globals() external view returns (address globals);

    /**
     *  @dev    Gets the address of the governor.
     *  @return governor The address of the governor.
     */
    function governor() external view returns (address governor);

    /**
     *  @dev    Returns whether the pool has sufficient cover. Pool delegate cover is deprecated, so this always returns true.
     *  @return hasSufficientCover True.
     */
    function hasSufficientCover() external pure returns (bool hasSufficientCover);

    /**
     *  @dev    Returns the length of the `strategyList`.
     *  @return strategyListLength The length of the `strategyList`.
     */
    function strategyListLength() external view returns (uint256 strategyListLength);

    /**
     *  @dev    Returns the amount of total assets.
     *  @return totalAssets Amount of of total assets.
     */
    function totalAssets() external view returns (uint256 totalAssets);

    /**
     *  @dev    Returns the sum of unrealized losses reported by every registered strategy and strategy manager.
     *  @return unrealizedLosses Aggregate unrealized losses across all strategies and strategy managers.
     */
    function unrealizedLosses() external view returns (uint256 unrealizedLosses);

}
