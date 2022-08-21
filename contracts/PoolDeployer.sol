// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { ERC20Helper }        from "../modules/erc20-helper/src/ERC20Helper.sol";
import { IMapleProxyFactory } from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";

import { IPoolDeployer }                             from "./interfaces/IPoolDeployer.sol";
import { IPoolManager }                              from "./interfaces/IPoolManager.sol";
import { IPoolManagerInitializer }                   from "./interfaces/IPoolManagerInitializer.sol";
import { IMapleGlobalsLike, ILoanManagerInitializerLike } from "./interfaces/Interfaces.sol";

contract PoolDeployer is IPoolDeployer {

    address public override globals;

    constructor(address globals_) {
        globals = globals_;
    }

    function deployPool(
        address[3] memory factories_,
        address[3] memory initializers_,
        address asset_,
        string memory name_,
        string memory symbol_,
        uint256[6] memory configParams_
    ) external override returns (
        address poolManager_,
        address loanManager_,
        address withdrawalManager_
    ) {
        address poolDelegate_ = msg.sender;

        require(IMapleGlobalsLike(globals).isPoolDelegate(poolDelegate_), "PD:DP:INVALID_PD");

        bytes32 salt_ = keccak256(abi.encode(poolDelegate_));

        // Deploy Pool Manager
        bytes memory arguments = IPoolManagerInitializer(initializers_[0]).encodeArguments(globals, poolDelegate_, asset_, configParams_[5], name_, symbol_);
        poolManager_           = IMapleProxyFactory(factories_[0]).createInstance(arguments, salt_);
        address pool_          = IPoolManager(poolManager_).pool();

        // Deploy Loan Manager
        arguments    = ILoanManagerInitializerLike(initializers_[1]).encodeArguments(pool_);
        loanManager_ = IMapleProxyFactory(factories_[1]).createInstance(arguments, salt_);

        // Deploy Withdrawal Manager
        arguments          = abi.encode(pool_, configParams_[3], configParams_[4]);
        withdrawalManager_ = IMapleProxyFactory(factories_[2]).createInstance(arguments, salt_);

        // Configure Pool Manager
        IPoolManager(poolManager_).configure(loanManager_, withdrawalManager_, configParams_[0], configParams_[1]);

        require(ERC20Helper.transferFrom(asset_, poolDelegate_, IPoolManager(poolManager_).poolDelegateCover(), configParams_[2]), "PD:DP:TRANSFER_FAILED");
    }

}
