// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

interface IMaplePoolDeployer {

    /**
     *  @dev   Emitted when a new pool is deployed.
     *  @param pool_              The address of the Pool deployed.
     *  @param poolManager_       The address of the PoolManager deployed.
     *  @param withdrawalManager_ The address of the WithdrawalManager deployed.
     *  @param strategies_        An array of the addresses of the Strategies deployed.
     */
    event PoolDeployed(address indexed pool_, address indexed poolManager_, address indexed withdrawalManager_, address[] strategies_);

    /**
     *  @dev   Deploys a pool along with its dependencies.
     *  @param poolManagerFactory_       The address of the PoolManager factory to use.
     *  @param withdrawalManagerFactory_ The address of the WithdrawalManager factory to use.
     *  @param strategyFactories_        An array of Strategy factories to use.
     *  @param asset_                    The address of the asset to use.
     *  @param poolPermissionManager_    The address of the PoolPermissionManager to use.
     *  @param name_                     The name of the Pool.
     *  @param symbol_                   The symbol of the Pool.
     *  @param configParams_             Array of uint256 config parameters. Array used to avoid stack too deep issues.
     *                                    [0]: liquidityCap
     *                                    [1]: delegateManagementFeeRate
     *                                    [2]: coverAmountRequired
     *                                    [3]: cycleDuration
     *                                    [4]: windowDuration
     *                                    [5]: initialSupply
     *                                    [6]: startTime
     *  @return poolManager_ The address of the PoolManager.
     */
    function deployPool(
        address           poolManagerFactory_,
        address           withdrawalManagerFactory_,
        address[]  memory strategyFactories_,
        address           asset_,
        address           poolPermissionManager_,
        string     memory name_,
        string     memory symbol_,
        uint256[7] memory configParams_
    )
        external
        returns (address poolManager_);

    /**
     *  @dev   Deploys a pool along with its dependencies.
     *  @param poolManagerFactory_       The address of the PoolManager factory to use.
     *  @param withdrawalManagerFactory_ The address of the WithdrawalManager factory to use.
     *  @param strategyFactories_        An array of Strategy factories to use.
     *  @param asset_                    The address of the asset to use.
     *  @param poolPermissionManager_    The address of the PoolPermissionManager to use.
     *  @param name_                     The name of the Pool.
     *  @param symbol_                   The symbol of the Pool.
     *  @param configParams_             Array of uint256 config parameters. Array used to avoid stack too deep issues.
     *                                    [0]: liquidityCap
     *                                    [1]: delegateManagementFeeRate
     *                                    [2]: coverAmountRequired
     *                                    [3]: initialSupply
     *  @return poolManager_ The address of the PoolManager.
     */
    function deployPool(
        address           poolManagerFactory_,
        address           withdrawalManagerFactory_,
        address[]  memory strategyFactories_,
        address           asset_,
        address           poolPermissionManager_,
        string     memory name_,
        string     memory symbol_,
        uint256[4] memory configParams_
    )
        external
        returns (address poolManager_);

    /**
     *  @dev   Gets the addresses that would result from a deployment.
     *  @param poolDelegate_             The address of the PoolDelegate that will deploy the Pool.
     *  @param poolManagerFactory_       The address of the PoolManager factory to use.
     *  @param withdrawalManagerFactory_ The address of the WithdrawalManager factory to use.
     *  @param strategyFactories_        An array of Strategy factories to use.
     *  @param asset_                    The address of the asset to use.
     *  @param name_                     The name of the Pool.
     *  @param symbol_                   The symbol of the Pool.
     *  @param configParams_             Array of uint256 config parameters. Array used to avoid stack too deep issues.
     *                                    [0]: liquidityCap
     *                                    [1]: delegateManagementFeeRate
     *                                    [2]: coverAmountRequired
     *                                    [3]: cycleDuration
     *                                    [4]: windowDuration
     *                                    [5]: initialSupply
     *                                    [6]: startTime
     *  @return poolManager_       The address of the PoolManager contract that will be deployed.
     *  @return pool_              The address of the Pool contract that will be deployed.
     *  @return poolDelegateCover_ The address of the PoolDelegateCover contract that will be deployed.
     *  @return withdrawalManager_ The address of the WithdrawalManager contract that will be deployed.
     *  @return strategies_        The address of the Strategy contracts that will be deployed.
     */
    function getDeploymentAddresses(
        address           poolDelegate_,
        address           poolManagerFactory_,
        address           withdrawalManagerFactory_,
        address[]  memory strategyFactories_,
        address           asset_,
        string     memory name_,
        string     memory symbol_,
        uint256[7] memory configParams_
    )
        external view
        returns (
            address          poolManager_,
            address          pool_,
            address          poolDelegateCover_,
            address          withdrawalManager_,
            address[] memory strategies_
        );

    /**
     *  @dev   Gets the addresses that would result from a deployment.
     *  @param poolDelegate_             The address of the PoolDelegate that will deploy the Pool.
     *  @param poolManagerFactory_       The address of the PoolManager factory to use.
     *  @param withdrawalManagerFactory_ The address of the WithdrawalManager factory to use.
     *  @param strategyFactories_        An array of Strategy factories to use.
     *  @param asset_                    The address of the asset to use.
     *  @param name_                     The name of the Pool.
     *  @param symbol_                   The symbol of the Pool.
     *  @param configParams_             Array of uint256 config parameters. Array used to avoid stack too deep issues.
     *                                    [0]: liquidityCap
     *                                    [1]: delegateManagementFeeRate
     *                                    [2]: coverAmountRequired
     *                                    [3]: initialSupply
     *  @return poolManager_       The address of the PoolManager contract that will be deployed.
     *  @return pool_              The address of the Pool contract that will be deployed.
     *  @return poolDelegateCover_ The address of the PoolDelegateCover contract that will be deployed.
     *  @return withdrawalManager_ The address of the WithdrawalManager contract that will be deployed.
     *  @return strategies_        The address of the Strategy contracts that will be deployed.
     */
    function getDeploymentAddresses(
        address           poolDelegate_,
        address           poolManagerFactory_,
        address           withdrawalManagerFactory_,
        address[]  memory strategyFactories_,
        address           asset_,
        string     memory name_,
        string     memory symbol_,
        uint256[4] memory configParams_
    )
        external view
        returns (
            address          poolManager_,
            address          pool_,
            address          poolDelegateCover_,
            address          withdrawalManager_,
            address[] memory strategies_
        );

    function globals() external view returns (address globals_);

}
