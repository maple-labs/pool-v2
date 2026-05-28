// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { Test }                                  from "../modules/forge-std/src/Test.sol";
import { MockERC20 }                             from "../modules/erc20/contracts/test/mocks/MockERC20.sol";
import { IMapleProxyFactory, MapleProxyFactory } from "../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

import { MaplePoolDeployer }           from "../contracts/MaplePoolDeployer.sol";
import { MaplePoolManager }            from "../contracts/MaplePoolManager.sol";
import { MaplePoolManagerInitializer } from "../contracts/proxy/MaplePoolManagerInitializer.sol";

import { IMaplePoolManager } from "../contracts/interfaces/IMaplePoolManager.sol";

import { MockGlobals, MockMigrator, MockPoolPermissionManager, MockProxied } from "./mocks/Mocks.sol";

import { TestBase } from "./utils/TestBase.sol";

contract MaplePoolDeployerTests is TestBase {

    address asset;
    address poolDelegate;
    address poolDeployer;
    address poolManagerFactory;
    address poolPermissionManager;
    address withdrawalManagerFactory;

    string name   = "Pool";
    string symbol = "P2";

    address[] strategyFactories;
    bytes[]   strategyDeploymentData;

    uint256[6] configParamsCycle = [
        1_000_000e18,               // liquidityCap
        0.1e6,                      // delegateManagementFeeRate
        3 days,                     // cycleDuration
        1 days,                     // windowDuration
        0,                          // initialSupply
        block.timestamp + 10 days   // startTime
    ];

    uint256[3] configParamsQueue = [
        1_000_000e18,               // liquidityCap
        0.1e6,                      // delegateManagementFeeRate
        0                           // initialSupply
    ];

    function setUp() public virtual {
        asset        = address(new MockERC20("Asset", "AT", 18));
        poolDelegate = makeAddr("poolDelegate");

        _deployAndBootstrapGlobals(asset, poolDelegate);

        poolManagerFactory       = address(new MapleProxyFactory(globals));
        withdrawalManagerFactory = address(new MapleProxyFactory(globals));

        for (uint256 i; i < 2; ++i) {
            strategyFactories.push(address(new MapleProxyFactory(globals)));
            strategyDeploymentData.push(new bytes(0));
        }

        poolPermissionManager = address(new MockPoolPermissionManager());

        vm.startPrank(GOVERNOR);

        IMapleProxyFactory(poolManagerFactory).registerImplementation(
            1,
            deploy("MaplePoolManager"),
            deploy("MaplePoolManagerInitializer")
        );

        IMapleProxyFactory(poolManagerFactory).setDefaultVersion(1);

        for (uint256 i; i < strategyFactories.length; ++i) {
            IMapleProxyFactory(strategyFactories[i]).registerImplementation(1, address(new MockProxied()), address(new MockMigrator()));
            IMapleProxyFactory(strategyFactories[i]).setDefaultVersion(1);
        }

        IMapleProxyFactory(withdrawalManagerFactory).registerImplementation(1, address(new MockProxied()), address(new MockMigrator()));
        IMapleProxyFactory(withdrawalManagerFactory).setDefaultVersion(1);

        vm.stopPrank();

        poolDeployer = address(new MaplePoolDeployer(globals));
        MockGlobals(globals).setValidPoolDeployer(poolDeployer, true);
    }

    function test_deployPool_mismatchingArrays() external {
        strategyDeploymentData.push("");

        vm.prank(poolDelegate);
        vm.expectRevert("PD:DP:MISMATCHING_ARRAYS");
        MaplePoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            strategyFactories,
            strategyDeploymentData,
            asset,
            poolPermissionManager,
            name,
            symbol,
            configParamsCycle
        );
    }

    function test_deployPool_invalidPoolDelegate() external {
        vm.expectRevert("PD:DP:INVALID_PD");
        MaplePoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            strategyFactories,
            strategyDeploymentData,
            asset,
            poolPermissionManager,
            name,
            symbol,
            configParamsCycle
        );
    }

    function test_deployPool_success_cyclicalWM() external {
        (address expectedPoolManager_, address expectedPool_) =
            MaplePoolDeployer(poolDeployer).getPoolDeploymentAddresses(
                poolManagerFactory,
                poolDelegate,
                asset,
                0,
                name,
                symbol
            );

        address expectedWithdrawalManager_ =
            MaplePoolDeployer(poolDeployer).getCyclicalWithdrawalManagerAddress(
                withdrawalManagerFactory,
                expectedPool_,
                expectedPoolManager_,
                configParamsCycle[5],
                configParamsCycle[2],
                configParamsCycle[3]
            );

        address[] memory expectedStrategies_ =
            MaplePoolDeployer(poolDeployer).getStrategiesAddresses(
                expectedPoolManager_,
                strategyFactories,
                strategyDeploymentData
            );

        vm.prank(poolDelegate);
        address poolManager_ = MaplePoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            strategyFactories,
            strategyDeploymentData,
            asset,
            poolPermissionManager,
            name,
            symbol,
            configParamsCycle
        );

        assertEq(poolManager_,                                        expectedPoolManager_);
        assertEq(IMaplePoolManager(poolManager_).pool(),              expectedPool_);
        assertEq(IMaplePoolManager(poolManager_).withdrawalManager(), expectedWithdrawalManager_);

        for (uint256 i_; i_ < strategyFactories.length; ++i_) {
            assertEq(IMaplePoolManager(poolManager_).strategyList(i_), expectedStrategies_[i_]);
        }
    }

    function test_deployPool_success_queueWM() external {
        (address expectedPoolManager_, address expectedPool_) =
            MaplePoolDeployer(poolDeployer).getPoolDeploymentAddresses(
                poolManagerFactory,
                poolDelegate,
                asset,
                0,
                name,
                symbol
            );

        address expectedWithdrawalManager_ =
            MaplePoolDeployer(poolDeployer).getQueueWithdrawalManagerAddress(
                withdrawalManagerFactory,
                expectedPool_,
                expectedPoolManager_
            );

        address[] memory expectedStrategies_ =
            MaplePoolDeployer(poolDeployer).getStrategiesAddresses(
                expectedPoolManager_,
                strategyFactories,
                strategyDeploymentData
            );

        vm.prank(poolDelegate);
        address poolManager_ = MaplePoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            strategyFactories,
            strategyDeploymentData,
            asset,
            poolPermissionManager,
            name,
            symbol,
            configParamsQueue
        );

        assertEq(poolManager_,                                        expectedPoolManager_);
        assertEq(IMaplePoolManager(poolManager_).pool(),              expectedPool_);
        assertEq(IMaplePoolManager(poolManager_).withdrawalManager(), expectedWithdrawalManager_);

        for (uint256 i_; i_ < strategyFactories.length; ++i_) {
            assertEq(IMaplePoolManager(poolManager_).strategyList(i_), expectedStrategies_[i_]);
        }
    }

}
