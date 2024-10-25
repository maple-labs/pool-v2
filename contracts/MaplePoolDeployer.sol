// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import { ERC20Helper }        from "../modules/erc20-helper/src/ERC20Helper.sol";
import { IMapleProxyFactory } from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";

import { IGlobalsLike, IPoolManagerLike } from "./interfaces/Interfaces.sol";
import { IMaplePoolDeployer }             from "./interfaces/IMaplePoolDeployer.sol";

/*

    ███╗   ███╗ █████╗ ██████╗ ██╗     ███████╗
    ████╗ ████║██╔══██╗██╔══██╗██║     ██╔════╝
    ██╔████╔██║███████║██████╔╝██║     █████╗
    ██║╚██╔╝██║██╔══██║██╔═══╝ ██║     ██╔══╝
    ██║ ╚═╝ ██║██║  ██║██║     ███████╗███████╗
    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝


    ██████╗  ██████╗  ██████╗ ██╗         ██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗███████╗██████╗
    ██╔══██╗██╔═══██╗██╔═══██╗██║         ██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝██╔════╝██╔══██╗
    ██████╔╝██║   ██║██║   ██║██║         ██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝ █████╗  ██████╔╝
    ██╔═══╝ ██║   ██║██║   ██║██║         ██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝  ██╔══╝  ██╔══██╗
    ██║     ╚██████╔╝╚██████╔╝███████╗    ██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║   ███████╗██║  ██║
    ╚═╝      ╚═════╝  ╚═════╝ ╚══════╝    ╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝   ╚══════╝╚═╝  ╚═╝

*/

contract MaplePoolDeployer is IMaplePoolDeployer {

    address public override globals;

    constructor(address globals_) {
        require((globals = globals_) != address(0), "PD:C:ZERO_ADDRESS");
    }

    function deployPool(
        address           poolManagerFactory_,
        address           withdrawalManagerFactory_,
        address[]  memory strategyFactories_,
        bytes[]    memory strategyDeploymentData_,
        address           asset_,
        address           poolPermissionManager_,
        string     memory name_,
        string     memory symbol_,
        uint256[7] memory configParams_
    )
        external override
        returns (address poolManager_)
    {
        require(strategyDeploymentData_.length == strategyFactories_.length, "PD:DP:MISMATCHING_ARRAYS");

        IGlobalsLike globals_ = IGlobalsLike(globals);

        require(globals_.isPoolDelegate(msg.sender), "PD:DP:INVALID_PD");

        require(globals_.isInstanceOf("POOL_MANAGER_FACTORY",             poolManagerFactory_),       "PD:DP:INVALID_PM_FACTORY");
        require(globals_.isInstanceOf("WITHDRAWAL_MANAGER_CYCLE_FACTORY", withdrawalManagerFactory_), "PD:DP:INVALID_WM_FACTORY");
        require(globals_.isInstanceOf("POOL_PERMISSION_MANAGER",          poolPermissionManager_),    "PD:DP:INVALID_PPM");

        // Deploy Pool Manager (and Pool).
        poolManager_ = IMapleProxyFactory(poolManagerFactory_).createInstance(
            abi.encode(msg.sender, asset_, configParams_[5], name_, symbol_),
            keccak256(abi.encode(msg.sender))
        );

        address pool_ = IPoolManagerLike(poolManager_).pool();

        // Deploy Withdrawal Manager.
        address withdrawalManager_ = IMapleProxyFactory(withdrawalManagerFactory_).createInstance(
            abi.encode(pool_, configParams_[6], configParams_[3], configParams_[4]),
            keccak256(abi.encode(poolManager_))
        );

        address[] memory strategies_ = new address[](strategyFactories_.length);

        for (uint256 i_; i_ < strategyFactories_.length; ++i_) {
            strategies_[i_] = IPoolManagerLike(poolManager_).addStrategy(strategyFactories_[i_], strategyDeploymentData_[i_]);
        }

        emit PoolDeployed(pool_, poolManager_, withdrawalManager_, strategies_);

        uint256 coverAmount_ = configParams_[2];

        require(
            coverAmount_ == 0 ||
            ERC20Helper.transferFrom(asset_, msg.sender, IPoolManagerLike(poolManager_).poolDelegateCover(), coverAmount_),
            "PD:DP:TRANSFER_FAILED"
        );

        IPoolManagerLike(poolManager_).setDelegateManagementFeeRate(configParams_[1]);
        IPoolManagerLike(poolManager_).setLiquidityCap(configParams_[0]);
        IPoolManagerLike(poolManager_).setPoolPermissionManager(poolPermissionManager_);
        IPoolManagerLike(poolManager_).setWithdrawalManager(withdrawalManager_);
        IPoolManagerLike(poolManager_).completeConfiguration();
    }

    function deployPool(
        address           poolManagerFactory_,
        address           withdrawalManagerFactory_,
        address[]  memory strategyFactories_,
        bytes[]    memory strategyDeploymentData_,
        address           asset_,
        address           poolPermissionManager_,
        string     memory name_,
        string     memory symbol_,
        uint256[4] memory configParams_
    )
        external override
        returns (address poolManager_)
    {
        require(strategyDeploymentData_.length == strategyFactories_.length, "PD:DP:MISMATCHING_ARRAYS");

        IGlobalsLike globals_ = IGlobalsLike(globals);

        require(globals_.isPoolDelegate(msg.sender), "PD:DP:INVALID_PD");

        require(globals_.isInstanceOf("POOL_MANAGER_FACTORY",             poolManagerFactory_),       "PD:DP:INVALID_PM_FACTORY");
        require(globals_.isInstanceOf("WITHDRAWAL_MANAGER_QUEUE_FACTORY", withdrawalManagerFactory_), "PD:DP:INVALID_WM_FACTORY");
        require(globals_.isInstanceOf("POOL_PERMISSION_MANAGER",          poolPermissionManager_),    "PD:DP:INVALID_PPM");

        // Deploy Pool Manager (and Pool).
        poolManager_ = IMapleProxyFactory(poolManagerFactory_).createInstance(
            abi.encode(msg.sender, asset_, configParams_[3], name_, symbol_),
            keccak256(abi.encode(msg.sender))
        );

        address pool_ = IPoolManagerLike(poolManager_).pool();

        // Deploy Withdrawal Manager.
        address withdrawalManager_ = IMapleProxyFactory(withdrawalManagerFactory_).createInstance(
            abi.encode(pool_),
            keccak256(abi.encode(poolManager_))
        );

        address[] memory strategies_ = new address[](strategyFactories_.length);

        for (uint256 i_; i_ < strategyFactories_.length; ++i_) {
            strategies_[i_] = IPoolManagerLike(poolManager_).addStrategy(strategyFactories_[i_], strategyDeploymentData_[i_]);
        }

        emit PoolDeployed(pool_, poolManager_, withdrawalManager_, strategies_);

        uint256 coverAmount_ = configParams_[2];

        require(
            coverAmount_ == 0 ||
            ERC20Helper.transferFrom(asset_, msg.sender, IPoolManagerLike(poolManager_).poolDelegateCover(), coverAmount_),
            "PD:DP:TRANSFER_FAILED"
        );

        IPoolManagerLike(poolManager_).setDelegateManagementFeeRate(configParams_[1]);
        IPoolManagerLike(poolManager_).setLiquidityCap(configParams_[0]);
        IPoolManagerLike(poolManager_).setPoolPermissionManager(poolPermissionManager_);
        IPoolManagerLike(poolManager_).setWithdrawalManager(withdrawalManager_);
        IPoolManagerLike(poolManager_).completeConfiguration();
    }

    function getDeploymentAddresses(
        address           poolDelegate_,
        address           poolManagerFactory_,
        address           withdrawalManagerFactory_,
        address[]  memory strategyFactories_,
        bytes[]    memory strategyDeploymentData_,
        address           asset_,
        string     memory name_,
        string     memory symbol_,
        uint256[7] memory configParams_
    )
        public view override
        returns (
            address          poolManager_,
            address          pool_,
            address          poolDelegateCover_,
            address          withdrawalManager_,
            address[] memory strategies_
        )
    {
        {
            bytes memory constructorArgs = abi.encode(poolDelegate_, asset_, configParams_[5], name_, symbol_);
            bytes32 salt = keccak256(abi.encode(poolDelegate_));
        
            poolManager_ = IMapleProxyFactory(poolManagerFactory_).getInstanceAddress(constructorArgs, salt);
        }

        pool_              = _addressFrom(poolManager_, 1);
        poolDelegateCover_ = _addressFrom(poolManager_, 2);

        withdrawalManager_ = IMapleProxyFactory(withdrawalManagerFactory_).getInstanceAddress(
            abi.encode(pool_, configParams_[6], configParams_[3], configParams_[4]),
            keccak256(abi.encode(poolManager_))
        );

        strategies_ = new address[](strategyFactories_.length);

        for (uint256 i_; i_ < strategyFactories_.length; ++i_) {
            strategies_[i_] = IMapleProxyFactory(strategyFactories_[i_]).getInstanceAddress(
                strategyDeploymentData_[i_],
                keccak256(abi.encode(poolManager_, i_))
            );
        }
    }

    function getDeploymentAddresses(
        address           poolDelegate_,
        address           poolManagerFactory_,
        address           withdrawalManagerFactory_,
        address[]  memory strategyFactories_,
        bytes[]    memory strategyDeploymentData_,
        address           asset_,
        string     memory name_,
        string     memory symbol_,
        uint256[4] memory configParams_
    )
        public view override
        returns (
            address          poolManager_,
            address          pool_,
            address          poolDelegateCover_,
            address          withdrawalManager_,
            address[] memory strategies_
        )
    {
        {
            bytes memory constructorArgs = abi.encode(poolDelegate_, asset_, configParams_[3], name_, symbol_);
            bytes32 salt = keccak256(abi.encode(poolDelegate_));
        
            poolManager_ = IMapleProxyFactory(poolManagerFactory_).getInstanceAddress(constructorArgs, salt);
        }

        pool_              = _addressFrom(poolManager_, 1);
        poolDelegateCover_ = _addressFrom(poolManager_, 2);

        withdrawalManager_ = IMapleProxyFactory(withdrawalManagerFactory_).getInstanceAddress(
            abi.encode(pool_),
            keccak256(abi.encode(poolManager_))
        );

        strategies_ = new address[](strategyFactories_.length);

        for (uint256 i_; i_ < strategyFactories_.length; ++i_) {
            strategies_[i_] = IMapleProxyFactory(strategyFactories_[i_]).getInstanceAddress(
                strategyDeploymentData_[i_],
                keccak256(abi.encode(poolManager_, i_))
            );
        }
    }

    function _addressFrom(address origin_, uint nonce_) internal pure returns (address address_) {
        address_ = address(
            uint160(
                uint256(
                    keccak256(
                        nonce_ == 0x00     ? abi.encodePacked(bytes1(0xd6), bytes1(0x94), origin_, bytes1(0x80))                 :
                        nonce_ <= 0x7f     ? abi.encodePacked(bytes1(0xd6), bytes1(0x94), origin_, uint8(nonce_))                :
                        nonce_ <= 0xff     ? abi.encodePacked(bytes1(0xd7), bytes1(0x94), origin_, bytes1(0x81), uint8(nonce_))  :
                        nonce_ <= 0xffff   ? abi.encodePacked(bytes1(0xd8), bytes1(0x94), origin_, bytes1(0x82), uint16(nonce_)) :
                        nonce_ <= 0xffffff ? abi.encodePacked(bytes1(0xd9), bytes1(0x94), origin_, bytes1(0x83), uint24(nonce_)) :
                                             abi.encodePacked(bytes1(0xda), bytes1(0x94), origin_, bytes1(0x84), uint32(nonce_))
                    )
                )
            )
        );
    }

}
