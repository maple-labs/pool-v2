// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

interface IPoolDeployer {

    /**
     *  @dev   Emitted when a new pool is deployed.
     *  @param pool_              The address of the Pool deployed.
     *  @param poolManager_       The address of the PoolManager deployed.
     *  @param withdrawalManager_ The address of the WithdrawalManager deployed.
     *  @param loanManagers_      An array of the addresses of the LoanManagers deployed.
     */
    event PoolDeployed(address indexed pool_, address indexed poolManager_, address indexed withdrawalManager_, address[] loanManagers_);

    function globals() external view returns (address globals_);

    /**
     *  @dev   Deploys a pool along with its dependencies.
     *  @param poolManagerFactory_       The address of the PoolManager factory to use.
     *  @param withdrawalManagerFactory_ The address of the WithdrawalManager factory to use.
     *  @param loanManagerFactories_     An array of LoanManager factories to use.
     *  @param configParams_             Array of uint256 config parameters. Array used to avoid stack too deep issues.
     *                                    [0]: liquidityCap
     *                                    [1]: delegateManagementFeeRate
     *                                    [2]: coverAmountRequired
     *                                    [3]: cycleDuration
     *                                    [4]: windowDuration
     *                                    [5]: initialSupply
     *  @return poolManager_ The address of the PoolManager.
     */
    function deployPool(
        address poolManagerFactory_,
        address withdrawalManagerFactory_,
        address[] memory loanManagerFactories_,
        address asset_,
        string memory name_,
        string memory symbol_,
        uint256[6] memory configParams_
    )
        external
        returns (address poolManager_);

}
