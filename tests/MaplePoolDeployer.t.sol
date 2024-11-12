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

    uint256 coverAmountRequired = 10e18;

    address[] strategyFactories;
    bytes[]   strategyDeploymentData;

    uint256[7] configParamsCycle = [
        1_000_000e18,
        0.1e6,
        coverAmountRequired,
        3 days,
        1 days,
        0,
        block.timestamp + 10 days
    ];

    uint256[4] configParamsQueue = [
        1_000_000e18,
        0.1e6,
        coverAmountRequired,
        0
    ];

    uint256[7] noCoverConfigParamsCycle = [
        1_000_000e18,
        0.1e6,
        0,
        3 days,
        1 days,
        0,
        block.timestamp + 10 days
    ];

    function setUp() public virtual {
        asset        = address(new MockERC20("Asset", "AT", 18));
        poolDelegate = makeAddr("poolDelegate");

        _deployAndBootstrapGlobals(asset, poolDelegate);


        poolManagerFactory       = address(new MapleProxyFactory(globals));
        withdrawalManagerFactory = address(new MapleProxyFactory(globals));

        // Get the pool manager address from the factory.
        address poolManagerDeployment = MapleProxyFactory(poolManagerFactory).getInstanceAddress(
            abi.encode(poolDelegate, asset, 0, name, symbol), // 0 is the initial supply
            keccak256(abi.encode(poolDelegate))
        );

        for (uint256 i; i < 2; ++i) {
            strategyFactories.push(address(new MapleProxyFactory(globals)));
            strategyDeploymentData.push(abi.encode(poolManagerDeployment));
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
        MockERC20(asset).mint(poolDelegate, coverAmountRequired);

        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);

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

    function test_deployPool_transferFailed() external {
        MockERC20(asset).mint(poolDelegate, coverAmountRequired - 1);

        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);

        vm.prank(poolDelegate);
        vm.expectRevert("PD:DP:TRANSFER_FAILED");
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
        MockERC20(asset).mint(poolDelegate, coverAmountRequired);

        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);

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

    function test_deployPool_success_withCoverRequired_cyclicalWM() external {
        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);
        MockERC20(asset).mint(poolDelegate, coverAmountRequired);

        (address expectedPoolManager_, address expectedPool_, address expectedPoolDelegateCover_) =
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
                configParamsCycle[6],
                configParamsCycle[3],
                configParamsCycle[4]
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
        assertEq(IMaplePoolManager(poolManager_).poolDelegateCover(), expectedPoolDelegateCover_);
        assertEq(IMaplePoolManager(poolManager_).withdrawalManager(), expectedWithdrawalManager_);

        for (uint256 i_; i_ < strategyFactories.length; ++i_) {
            assertEq(IMaplePoolManager(poolManager_).strategyList(i_), expectedStrategies_[i_]);
        }
    }

    function test_deployPool_success_withoutCoverRequired_cyclicalWM() external {
        (address expectedPoolManager_, address expectedPool_, address expectedPoolDelegateCover_) =
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
                configParamsCycle[6],
                configParamsCycle[3],
                configParamsCycle[4]
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
            noCoverConfigParamsCycle
        );

        assertEq(poolManager_,                                        expectedPoolManager_);
        assertEq(IMaplePoolManager(poolManager_).pool(),              expectedPool_);
        assertEq(IMaplePoolManager(poolManager_).poolDelegateCover(), expectedPoolDelegateCover_);
        assertEq(IMaplePoolManager(poolManager_).withdrawalManager(), expectedWithdrawalManager_);

        for (uint256 i_; i_ < strategyFactories.length; ++i_) {
            assertEq(IMaplePoolManager(poolManager_).strategyList(i_), expectedStrategies_[i_]);
        }
    }

    function test_deployPool_success_withCoverRequired_queueWM() external {
        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);
        MockERC20(asset).mint(poolDelegate, coverAmountRequired);

        (address expectedPoolManager_, address expectedPool_, address expectedPoolDelegateCover_) =
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
        assertEq(IMaplePoolManager(poolManager_).poolDelegateCover(), expectedPoolDelegateCover_);
        assertEq(IMaplePoolManager(poolManager_).withdrawalManager(), expectedWithdrawalManager_);

        for (uint256 i_; i_ < strategyFactories.length; ++i_) {
            assertEq(IMaplePoolManager(poolManager_).strategyList(i_), expectedStrategies_[i_]);
        }
    }

}
