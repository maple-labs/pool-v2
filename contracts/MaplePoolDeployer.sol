// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { IMapleProxyFactory } from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";

import { IGlobalsLike, IPoolManagerLike } from "./interfaces/Interfaces.sol";

import {
    IMaplePoolDeployer,
    PoolConfigParams,
    PoolManagerInitParams,
    StrategyDeployParams,
    StrategyManagerParams
} from "./interfaces/IMaplePoolDeployer.sol";

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

    /**************************************************************************************************************************************/
    /*** Constructor                                                                                                                    ***/
    /**************************************************************************************************************************************/

    constructor(address globals_) {
        require(globals_ != address(0), "PD:C:ZERO_ADDRESS");

        globals = globals_;
    }

    /**************************************************************************************************************************************/
    /*** Pool deployment                                                                                                                ***/
    /**************************************************************************************************************************************/

    function deployPool(
        address                          poolManagerFactory_,
        address                          withdrawalManagerFactory_,
        PoolManagerInitParams   calldata poolManagerInitParams_,
        PoolConfigParams        calldata poolConfigParams_,
        StrategyDeployParams[]  calldata strategiesParams_,
        StrategyManagerParams[] calldata strategyManagersParams_
    )
        external override returns (address poolManager_)
    {
        address      poolPermissionManager_ = poolConfigParams_.poolPermissionManager;
        IGlobalsLike globals_               = IGlobalsLike(globals);

        require(globals_.isPoolDelegate(msg.sender), "PD:DP:INVALID_PD");

        require(globals_.isInstanceOf("POOL_MANAGER_FACTORY",             poolManagerFactory_),       "PD:DP:INVALID_PM_FACTORY");
        require(globals_.isInstanceOf("WITHDRAWAL_MANAGER_QUEUE_FACTORY", withdrawalManagerFactory_), "PD:DP:INVALID_WM_FACTORY");
        require(globals_.isInstanceOf("POOL_PERMISSION_MANAGER",          poolPermissionManager_),    "PD:DP:INVALID_PPM");

        poolManager_ = IMapleProxyFactory(poolManagerFactory_).createInstance(
            abi.encode(
                msg.sender,
                poolManagerInitParams_.asset,
                poolManagerInitParams_.initialSupply,
                poolManagerInitParams_.name,
                poolManagerInitParams_.symbol
            ),
            keccak256(abi.encode(msg.sender))
        );

        address pool_              = IPoolManagerLike(poolManager_).pool();
        address withdrawalManager_ = IMapleProxyFactory(withdrawalManagerFactory_).createInstance(
            abi.encode(pool_),
            keccak256(abi.encode(poolManager_))
        );

        address[] memory strategies_       = _deployStrategies(poolManager_, strategiesParams_);
        address[] memory strategyManagers_ = _addStrategyManagers(poolManager_, strategyManagersParams_);

        emit PoolDeployed(pool_, poolManager_, withdrawalManager_, strategies_, strategyManagers_);

        IPoolManagerLike(poolManager_).setDelegateManagementFeeRate(poolConfigParams_.delegateManagementFeeRate);
        IPoolManagerLike(poolManager_).setLiquidityCap(poolConfigParams_.liquidityCap);
        IPoolManagerLike(poolManager_).setPoolPermissionManager(poolPermissionManager_);
        IPoolManagerLike(poolManager_).setWithdrawalManager(withdrawalManager_);
        IPoolManagerLike(poolManager_).completeConfiguration();
    }

    /**************************************************************************************************************************************/
    /*** Pool deployment internal helper functions                                                                                      ***/
    /**************************************************************************************************************************************/

    function _addStrategyManagers(address poolManager_, StrategyManagerParams[] calldata strategyManagersParams_)
        internal returns (address[] memory strategyManagers_)
    {
        strategyManagers_ = new address[](strategyManagersParams_.length);

        for (uint256 i_; i_ < strategyManagersParams_.length; ++i_) {
            address strategyManager_ = strategyManagersParams_[i_].instance;
            uint256 cap_             = strategyManagersParams_[i_].cap;

            IPoolManagerLike(poolManager_).addStrategyManager(strategyManager_);

            if (cap_ != 0) IPoolManagerLike(poolManager_).setStrategyCap(strategyManager_, cap_);

            strategyManagers_[i_] = strategyManager_;
        }
    }

    function _deployStrategies(address poolManager_, StrategyDeployParams[] calldata strategiesParams_)
        internal returns (address[] memory strategies_)
    {
        strategies_ = new address[](strategiesParams_.length);

        for (uint256 i_; i_ < strategiesParams_.length; ++i_) {
            address factory_ = strategiesParams_[i_].factory;
            bytes32 salt_    = strategiesParams_[i_].salt;
            uint256 cap_     = strategiesParams_[i_].cap;

            address strategy_ = IPoolManagerLike(poolManager_).addStrategy(factory_, salt_, strategiesParams_[i_].deploymentData);

            if (cap_ != 0) IPoolManagerLike(poolManager_).setStrategyCap(strategy_, cap_);

            strategies_[i_] = strategy_;
        }
    }

    /**************************************************************************************************************************************/
    /*** Deployment getters                                                                                                             ***/
    /**************************************************************************************************************************************/

    function getPoolDeploymentAddresses(
        address poolManagerFactory_,
        address poolDelegate_,
        address asset_,
        uint256 initialSupply_,
        string memory name_,
        string memory symbol_
    )
        external view override returns (address poolManager_, address pool_)
    {
        ( pool_, poolManager_ ) = _getPoolAddresses(
            poolManagerFactory_, poolDelegate_, asset_, initialSupply_, name_, symbol_
        );
    }

    function getQueueWithdrawalManagerAddress(
        address withdrawalManagerFactory_,
        address pool_,
        address poolManager_
    )
        external view override returns (address withdrawalManager_)
    {
        return _getQueueWithdrawalManagerAddress(withdrawalManagerFactory_, pool_, poolManager_);
    }

    function getStrategiesAddresses(
        address          poolManager_,
        address[] memory strategyFactories_,
        bytes[]   memory strategyDeploymentData_,
        bytes32[] memory strategySalts_
    )
        external view returns (address[] memory strategies_)
    {
        return _getStrategiesAddresses(poolManager_, strategyFactories_, strategyDeploymentData_, strategySalts_);
    }

    /**************************************************************************************************************************************/
    /*** Deployment getter internal helper functions                                                                                    ***/
    /**************************************************************************************************************************************/

    function _getQueueWithdrawalManagerAddress(
        address withdrawalManagerFactory_,
        address pool_,
        address poolManager_
    )
        internal view
        returns (address queueWithdrawalManager_)
    {
        queueWithdrawalManager_ = IMapleProxyFactory(withdrawalManagerFactory_).getInstanceAddress(
            abi.encode(pool_),
            keccak256(abi.encode(poolManager_))
        );
    }

    function _getPoolAddresses(
        address poolManagerFactory_,
        address poolDelegate_,
        address asset_,
        uint256 initialSupply_,
        string memory name_,
        string memory symbol_
    )
        internal view returns (address pool_, address poolManager_)
    {
        bytes memory constructorArgs = abi.encode(poolDelegate_, asset_, initialSupply_, name_, symbol_);
        bytes32 salt                 = keccak256(abi.encode(poolDelegate_));

        poolManager_ = IMapleProxyFactory(poolManagerFactory_).getInstanceAddress(constructorArgs, salt);
        pool_        = _addressFrom(poolManager_, 1);
    }

    function _getStrategiesAddresses(
        address          poolManager_,
        address[] memory strategyFactories_,
        bytes[]   memory strategyDeploymentData_,
        bytes32[] memory strategySalts_
    )
        internal view
        returns (address[] memory strategiesAddresses_)
    {
        strategiesAddresses_ = new address[](strategyFactories_.length);

        for (uint256 i_; i_ < strategyFactories_.length; ++i_) {
            strategiesAddresses_[i_] = IMapleProxyFactory(strategyFactories_[i_]).getInstanceAddress(
                bytes.concat(abi.encode(poolManager_), strategyDeploymentData_[i_]),
                strategySalts_[i_]
            );
        }
    } 

    function _addressFrom(address origin_, uint256 nonce_) internal pure returns (address address_) {
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
