// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

struct PoolManagerInitParams {
    address asset;
    uint256 initialSupply;
    string name;
    string symbol;
}

struct PoolConfigParams {
    address poolPermissionManager;
    uint256 delegateManagementFeeRate;
    uint256 liquidityCap;
}

struct StrategyDeployParams {
    address factory;
    uint256 cap;
    bytes32 salt;
    bytes deploymentData;
}

struct StrategyManagerParams {
    address instance;
    uint256 cap;
}

interface IMaplePoolDeployer {

    /**
     *  @dev   Emitted when a new pool is deployed.
     *  @param pool              The address of the Pool deployed.
     *  @param poolManager       The address of the PoolManager deployed.
     *  @param withdrawalManager The address of the queue WithdrawalManager deployed.
     *  @param strategies        Addresses of the Strategies deployed and registered on the PoolManager.
     *  @param strategyManagers  Addresses of the StrategyManagers registered on the PoolManager.
     */
    event PoolDeployed(
        address indexed pool,
        address indexed poolManager,
        address indexed withdrawalManager,
        address[] strategies,
        address[] strategyManagers
    );

    /**
     *  @dev    Deploys a pool along with its dependencies and atomically completes configuration.
     *          NOTE: The PoolManager address is encoded and prepended to the strategyDeploymentData.
     *  @param  poolManagerFactory       The address of the PoolManager factory to use.
     *  @param  withdrawalManagerFactory The address of the queue WithdrawalManager factory to use.
     *  @param  poolManagerInitParams    Initial parameters for the PoolManager (asset, name, symbol, initialSupply).
     *  @param  poolConfigParams         Pool configuration (poolPermissionManager, liquidityCap, delegateManagementFeeRate).
     *  @param  strategiesParams         Strategies to deploy and register on the PoolManager (with optional caps).
     *  @param  strategyManagersParams   Pre-deployed StrategyManagers to register on the PoolManager (with optional caps).
     *  @return poolManager              The address of the deployed PoolManager.
     */
    function deployPool(
        address poolManagerFactory,
        address withdrawalManagerFactory,
        PoolManagerInitParams calldata poolManagerInitParams,
        PoolConfigParams calldata poolConfigParams,
        StrategyDeployParams[] calldata strategiesParams,
        StrategyManagerParams[] calldata strategyManagersParams
    )
        external
        returns (address poolManager);

    /**
     *  @dev    Gets the address of the Globals contract.
     *  @return globals The address of the Globals contract.
     */
    function globals() external view returns (address globals);

    /**
     *  @dev    Gets the addresses that would result from a deployment.
     *  @param  poolManagerFactory The address of the PoolManager factory to use.
     *  @param  poolDelegate       The address of the PoolDelegate that will deploy the Pool.
     *  @param  asset              The address of the asset to use.
     *  @param  initialSupply      The initial supply of the Pool.
     *  @param  name               The name of the Pool.
     *  @param  symbol             The symbol of the Pool.
     *  @return poolManager        The address of the PoolManager contract that will be deployed.
     *  @return pool               The address of the Pool contract that will be deployed.
     */
    function getPoolDeploymentAddresses(
        address poolManagerFactory,
        address poolDelegate,
        address asset,
        uint256 initialSupply,
        string memory name,
        string memory symbol
    )
        external
        view
        returns (address poolManager, address pool);

    /**
     *  @dev    Gets the address of the Queue Withdrawal Manager that would result from a deployment.
     *  @param  withdrawalManagerFactory The address of the WithdrawalManager factory to use.
     *  @param  pool                     The address of the Pool to use.
     *  @param  poolManager              The address of the PoolManager to use.
     *  @return withdrawalManager        The address of the WithdrawalManager contract that will be deployed.
     */
    function getQueueWithdrawalManagerAddress(
        address withdrawalManagerFactory,
        address pool,
        address poolManager
    )
        external
        view
        returns (address withdrawalManager);

    /**
     *  @dev    Gets the addresses of the Strategies that would result from a deployment.
     *  @param  poolManager            The address of the PoolManager to use.
     *  @param  strategyFactories      An array of Strategy factories to use.
     *  @param  strategyDeploymentData An array of bytes to use to construct the strategies.
     *  @param  strategySalts          An array of salts used as the CREATE2 salt for each strategy.
     *  @return strategies             The addresses of the Strategy contracts that will be deployed.
     */
    function getStrategiesAddresses(
        address poolManager,
        address[] memory strategyFactories,
        bytes[] memory strategyDeploymentData,
        bytes32[] memory strategySalts
    )
        external
        view
        returns (address[] memory strategies);

}
