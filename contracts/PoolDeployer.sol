// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { ERC20Helper }        from "../modules/erc20-helper/src/ERC20Helper.sol";
import { IMapleProxyFactory } from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";

import { ILoanManagerInitializerLike, IMapleGlobalsLike, IWithdrawalManagerInitializerLike } from "./interfaces/Interfaces.sol";

import { IPoolDeployer }           from "./interfaces/IPoolDeployer.sol";
import { IPoolManager }            from "./interfaces/IPoolManager.sol";
import { IPoolManagerInitializer } from "./interfaces/IPoolManagerInitializer.sol";

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
        address[3] memory factories_,
        address[3] memory initializers_,
        address asset_,
        string memory name_,
        string memory symbol_,
        uint256[6] memory configParams_
    )
        external override returns (
            address poolManager_,
            address loanManager_,
            address withdrawalManager_
        )
    {
        address poolDelegate_ = msg.sender;

        IMapleGlobalsLike globals_ = IMapleGlobalsLike(globals);

        require(globals_.isPoolDelegate(poolDelegate_), "PD:DP:INVALID_PD");

        require(globals_.isFactory("POOL_MANAGER",       factories_[0]), "PD:DP:INVALID_PM_FACTORY");
        require(globals_.isFactory("LOAN_MANAGER",       factories_[1]), "PD:DP:INVALID_LM_FACTORY");
        require(globals_.isFactory("WITHDRAWAL_MANAGER", factories_[2]), "PD:DP:INVALID_WM_FACTORY");

        // Avoid stack too deep error
        {
            IMapleProxyFactory PMFactory_ = IMapleProxyFactory(factories_[0]);
            IMapleProxyFactory LMFactory_ = IMapleProxyFactory(factories_[1]);
            IMapleProxyFactory WMFactory_ = IMapleProxyFactory(factories_[2]);

            require(
                initializers_[0] == PMFactory_.migratorForPath(PMFactory_.defaultVersion(), PMFactory_.defaultVersion()),
                "PD:DP:INVALID_PM_INITIALIZER"
            );

            require(
                initializers_[1] == LMFactory_.migratorForPath(LMFactory_.defaultVersion(), LMFactory_.defaultVersion()),
                "PD:DP:INVALID_LM_INITIALIZER"
            );

            require(
                initializers_[2] == WMFactory_.migratorForPath(WMFactory_.defaultVersion(), WMFactory_.defaultVersion()),
                "PD:DP:INVALID_WM_INITIALIZER"
            );
        }

        bytes32 salt_ = keccak256(abi.encode(poolDelegate_));

        // Deploy Pool Manager
        bytes memory arguments = IPoolManagerInitializer(
            initializers_[0]).encodeArguments(poolDelegate_, asset_, configParams_[5], name_, symbol_
        );

        poolManager_  = IMapleProxyFactory(factories_[0]).createInstance(arguments, salt_);
        address pool_ = IPoolManager(poolManager_).pool();

        // Deploy Loan Manager
        arguments    = ILoanManagerInitializerLike(initializers_[1]).encodeArguments(pool_);
        loanManager_ = IMapleProxyFactory(factories_[1]).createInstance(arguments, salt_);

        // Deploy Withdrawal Manager
        arguments          = IWithdrawalManagerInitializerLike(initializers_[2]).encodeArguments(pool_, configParams_[3], configParams_[4]);
        withdrawalManager_ = IMapleProxyFactory(factories_[2]).createInstance(arguments, salt_);

        // Configure Pool Manager
        IPoolManager(poolManager_).configure(loanManager_, withdrawalManager_, configParams_[0], configParams_[1]);

        require(
            ERC20Helper.transferFrom(asset_, poolDelegate_, IPoolManager(poolManager_).poolDelegateCover(), configParams_[2]),
            "PD:DP:TRANSFER_FAILED"
        );
    }

}
