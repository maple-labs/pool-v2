// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

interface IPoolDeployer {

    function globals() external view returns (address globals_);

    /**
     *  @dev   Deploys a pool along with its dependencies.
     *  @param factories_    Array of deployer addresses. Array used to avoid stack too deep issues.
     *                         [0]: poolManagerFactory
     *                         [1]: loanManagerFactory
     *                         [2]: withdrawalManagerFactory
     *  @param initializers_ Array of initializer addresses.
     *                         [0]: poolManagerInitializer
     *                         [1]: loanManagerInitializer
     *                         [2]: withdrawalManagerInitializer
     *  @param configParams_ Array of uint256 config parameters. Array used to avoid stack too deep issues.
     *                         [0]: liquidityCap
     *                         [1]: delegateManagementFeeRate
     *                         [2]: coverAmountRequired
     *                         [3]: cycleDuration
     *                         [4]: windowDuration
     *                         [5]: initialSupply
     */
    function deployPool(
        address[3] memory factories_,
        address[3] memory initializers_,
        address asset_,
        string memory name_,
        string memory symbol_,
        uint256[6] memory configParams_
    ) external returns (
        address poolManager_,
        address loanManager_,
        address withdrawalManager_
    );

}
