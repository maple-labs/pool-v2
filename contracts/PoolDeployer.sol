// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { ERC20Helper }        from "../modules/erc20-helper/src/ERC20Helper.sol";
import { IMapleProxyFactory } from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";

import { IMapleGlobalsLike, IPoolManagerLike } from "./interfaces/Interfaces.sol";
import { IPoolDeployer }                       from "./interfaces/IPoolDeployer.sol";

/*

    ██████╗  ██████╗  ██████╗ ██╗         ██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗███████╗██████╗
    ██╔══██╗██╔═══██╗██╔═══██╗██║         ██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝██╔════╝██╔══██╗
    ██████╔╝██║   ██║██║   ██║██║         ██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝ █████╗  ██████╔╝
    ██╔═══╝ ██║   ██║██║   ██║██║         ██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝  ██╔══╝  ██╔══██╗
    ██║     ╚██████╔╝╚██████╔╝███████╗    ██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║   ███████╗██║  ██║
    ╚═╝      ╚═════╝  ╚═════╝ ╚══════╝    ╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝   ╚══════╝╚═╝  ╚═╝

*/

contract PoolDeployer is IPoolDeployer {

    address public override globals;

    constructor(address globals_) {
        require((globals = globals_) != address(0), "PD:C:ZERO_ADDRESS");
    }

    function deployPool(
        address poolManagerFactory_,
        address withdrawalManagerFactory_,
        address[] memory loanManagerFactories_,
        address asset_,
        string memory name_,
        string memory symbol_,
        uint256[6] memory configParams_
    )
        external override
        returns (address poolManager_)
    {
        IMapleGlobalsLike globals_ = IMapleGlobalsLike(globals);

        require(globals_.isPoolDelegate(msg.sender), "PD:DP:INVALID_PD");

        require(globals_.isFactory("POOL_MANAGER",       poolManagerFactory_),       "PD:DP:INVALID_PM_FACTORY");
        require(globals_.isFactory("WITHDRAWAL_MANAGER", withdrawalManagerFactory_), "PD:DP:INVALID_WM_FACTORY");

        // Deploy Pool Manager (and Pool).
        poolManager_ = IMapleProxyFactory(poolManagerFactory_).createInstance(
            abi.encode(msg.sender, asset_, configParams_[5], name_, symbol_),
            keccak256(abi.encode(msg.sender))
        );

        address pool_ = IPoolManagerLike(poolManager_).pool();

        // Deploy Withdrawal Manager.
        address withdrawalManager_ = IMapleProxyFactory(withdrawalManagerFactory_).createInstance(
            abi.encode(pool_, configParams_[3], configParams_[4]),
            keccak256(abi.encode(poolManager_))
        );

        address[] memory loanManagers_ = new address[](loanManagerFactories_.length);

        for (uint256 i_; i_ < loanManagerFactories_.length; ++i_) {
            loanManagers_[i_] = IPoolManagerLike(poolManager_).addLoanManager(loanManagerFactories_[i_]);
        }

        emit PoolDeployed(pool_, poolManager_, withdrawalManager_, loanManagers_);

        require(
            ERC20Helper.transferFrom(asset_, msg.sender, IPoolManagerLike(poolManager_).poolDelegateCover(), configParams_[2]),
            "PD:DP:TRANSFER_FAILED"
        );

        IPoolManagerLike(poolManager_).setDelegateManagementFeeRate(configParams_[1]);
        IPoolManagerLike(poolManager_).setLiquidityCap(configParams_[0]);
        IPoolManagerLike(poolManager_).setWithdrawalManager(withdrawalManager_);
        IPoolManagerLike(poolManager_).completeConfiguration();
    }

}
