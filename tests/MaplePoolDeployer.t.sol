// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { Test }                                  from "../modules/forge-std/src/Test.sol";
import { MockERC20 }                             from "../modules/erc20/contracts/test/mocks/MockERC20.sol";
import { IMapleProxyFactory, MapleProxyFactory } from "../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

import { MaplePoolDeployer }           from "../contracts/MaplePoolDeployer.sol";
import { MaplePoolManager }            from "../contracts/MaplePoolManager.sol";
import { MaplePoolManagerInitializer } from "../contracts/proxy/MaplePoolManagerInitializer.sol";

import { IMaplePoolManager } from "../contracts/interfaces/IMaplePoolManager.sol";

import { MockGlobals, MockMigrator, MockPoolPermissionManager, MockProxied } from "./mocks/Mocks.sol";

import { GlobalsBootstrapper } from "./bootstrap/GlobalsBootstrapper.sol";

contract MaplePoolDeployerTests is Test, GlobalsBootstrapper {

    address asset;
    address poolDelegate;
    address poolDeployer;
    address poolManagerFactory;
    address poolPermissionManager;
    address withdrawalManagerFactory;

    string name   = "Pool";
    string symbol = "P2";

    uint256 coverAmountRequired = 10e18;

    address[] loanManagerFactories;

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

    function setUp() public virtual {
        asset        = address(new MockERC20("Asset", "AT", 18));
        poolDelegate = makeAddr("poolDelegate");

        _deployAndBootstrapGlobals(asset, poolDelegate);

        for (uint256 i; i < 2; ++i) {
            loanManagerFactories.push(address(new MapleProxyFactory(globals)));
        }

        poolManagerFactory       = address(new MapleProxyFactory(globals));
        withdrawalManagerFactory = address(new MapleProxyFactory(globals));

        poolPermissionManager = address(new MockPoolPermissionManager());

        vm.startPrank(GOVERNOR);

        IMapleProxyFactory(poolManagerFactory).registerImplementation(
            1,
            address(new MaplePoolManager()),
            address(new MaplePoolManagerInitializer())
        );

        IMapleProxyFactory(poolManagerFactory).setDefaultVersion(1);

        for (uint256 i; i < loanManagerFactories.length; ++i) {
            IMapleProxyFactory(loanManagerFactories[i]).registerImplementation(1, address(new MockProxied()), address(new MockMigrator()));
            IMapleProxyFactory(loanManagerFactories[i]).setDefaultVersion(1);
        }

        IMapleProxyFactory(withdrawalManagerFactory).registerImplementation(1, address(new MockProxied()), address(new MockMigrator()));
        IMapleProxyFactory(withdrawalManagerFactory).setDefaultVersion(1);

        vm.stopPrank();

        poolDeployer = address(new MaplePoolDeployer(globals));
        MockGlobals(globals).setValidPoolDeployer(poolDeployer, true);
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
            loanManagerFactories,
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
            loanManagerFactories,
            asset,
            poolPermissionManager,
            name,
            symbol,
            configParamsCycle
        );
    }

    function test_deployPool_success_withCoverRequired() external {
        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);
        MockERC20(asset).mint(poolDelegate, coverAmountRequired);

        (
            address          expectedPoolManager_,
            address          expectedPool_,
            address          expectedPoolDelegateCover_,
            address          expectedWithdrawalManager_,
            address[] memory expectedLoanManagers_
        ) = MaplePoolDeployer(poolDeployer).getDeploymentAddresses(
            poolDelegate,
            poolManagerFactory,
            withdrawalManagerFactory,
            loanManagerFactories,
            asset,
            name,
            symbol,
            configParamsCycle
        );

        vm.prank(poolDelegate);
        address poolManager_ = MaplePoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            loanManagerFactories,
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

        for (uint256 i_; i_ < loanManagerFactories.length; ++i_) {
            assertEq(IMaplePoolManager(poolManager_).loanManagerList(i_), expectedLoanManagers_[i_]);
        }
    }

    function test_deployPool_success_withoutCoverRequired() external {
        uint256[7] memory noCoverConfigParamsCycle = [
            uint256(1_000_000e18),
            0.1e6,
            0,
            3 days,
            1 days,
            0,
            block.timestamp + 10 days
        ];

        (
            address          expectedPoolManager_,
            address          expectedPool_,
            address          expectedPoolDelegateCover_,
            address          expectedWithdrawalManager_,
            address[] memory expectedLoanManagers_
        ) = MaplePoolDeployer(poolDeployer).getDeploymentAddresses(
            poolDelegate,
            poolManagerFactory,
            withdrawalManagerFactory,
            loanManagerFactories,
            asset,
            name,
            symbol,
            configParamsCycle
        );

        vm.prank(poolDelegate);
        address poolManager_ = MaplePoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            loanManagerFactories,
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

        for (uint256 i_; i_ < loanManagerFactories.length; ++i_) {
            assertEq(IMaplePoolManager(poolManager_).loanManagerList(i_), expectedLoanManagers_[i_]);
        }
    }

    function test_deployPool_success_withCoverRequired_queueWM() external {
        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);
        MockERC20(asset).mint(poolDelegate, coverAmountRequired);

        (
            address          expectedPoolManager_,
            address          expectedPool_,
            address          expectedPoolDelegateCover_,
            address          expectedWithdrawalManager_,
            address[] memory expectedLoanManagers_
        ) = MaplePoolDeployer(poolDeployer).getDeploymentAddresses(
            poolDelegate,
            poolManagerFactory,
            withdrawalManagerFactory,
            loanManagerFactories,
            asset,
            name,
            symbol,
            configParamsQueue
        );

        vm.prank(poolDelegate);
        address poolManager_ = MaplePoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            loanManagerFactories,
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

        for (uint256 i_; i_ < loanManagerFactories.length; ++i_) {
            assertEq(IMaplePoolManager(poolManager_).loanManagerList(i_), expectedLoanManagers_[i_]);
        }
    }

}
