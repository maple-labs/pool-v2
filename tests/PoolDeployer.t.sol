// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { Address, TestUtils }                    from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                             from "../modules/erc20/contracts/test/mocks/MockERC20.sol";
import { IMapleProxyFactory, MapleProxyFactory } from "../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

import { PoolDeployer } from "../contracts/PoolDeployer.sol";

import {
    MockGlobals,
    MockMigrator,
    MockProxied,
    MockPoolManager
} from "./mocks/Mocks.sol";

import { GlobalsBootstrapper } from "./bootstrap/GlobalsBootstrapper.sol";

contract PoolDeployerTests is TestUtils, GlobalsBootstrapper {

    address asset;
    address poolDelegate;
    address poolDeployer;
    address poolManagerFactory;
    address withdrawalManagerFactory;

    address[] loanManagerFactories;

    uint256 constant coverAmountRequired = 10e18;

    string name   = "Pool";
    string symbol = "P2";

    uint256[6] configParams_ = [
        1_000_000e18,
        0.1e18,
        coverAmountRequired,
        3 days,
        1 days,
        0
    ];

    function setUp() public virtual {
        asset        = address(new MockERC20("Asset", "AT", 18));
        poolDelegate = address(new Address());

        _deployAndBootstrapGlobals(address(asset), poolDelegate);

        for (uint256 i; i < 2; ++i) {
            loanManagerFactories.push(address(new MapleProxyFactory(globals)));
        }

        poolManagerFactory       = address(new MapleProxyFactory(globals));
        withdrawalManagerFactory = address(new MapleProxyFactory(globals));

        vm.startPrank(GOVERNOR);

        IMapleProxyFactory(poolManagerFactory).registerImplementation(1, address(new MockPoolManager()), address(new MockMigrator()));
        IMapleProxyFactory(poolManagerFactory).setDefaultVersion(1);

        for (uint256 i; i < loanManagerFactories.length; ++i) {
            IMapleProxyFactory(loanManagerFactories[i]).registerImplementation(1, address(new MockProxied()), address(new MockMigrator()));
            IMapleProxyFactory(loanManagerFactories[i]).setDefaultVersion(1);
        }

        IMapleProxyFactory(withdrawalManagerFactory).registerImplementation(1, address(new MockProxied()), address(new MockMigrator()));
        IMapleProxyFactory(withdrawalManagerFactory).setDefaultVersion(1);

        vm.stopPrank();

        poolDeployer = address(new PoolDeployer(globals));
        MockGlobals(globals).setValidPoolDeployer(poolDeployer, true);
    }

    function test_deployPool_transferFailed() external {
        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);
        MockERC20(asset).mint(poolDelegate, coverAmountRequired - 1);

        vm.prank(poolDelegate);
        vm.expectRevert("PD:DP:TRANSFER_FAILED");
        PoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            loanManagerFactories,
            address(asset),
            name,
            symbol,
            configParams_
        );
    }

    function test_deployPool_invalidPoolDelegate() external {
        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);
        MockERC20(asset).mint(poolDelegate, coverAmountRequired);

        vm.expectRevert("PD:DP:INVALID_PD");
        PoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            loanManagerFactories,
            address(asset),
            name,
            symbol,
            configParams_
        );
    }

    function test_deployPool_success_withCoverRequired() external {
        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);
        MockERC20(asset).mint(poolDelegate, coverAmountRequired);

        vm.prank(poolDelegate);
        PoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            loanManagerFactories,
            address(asset),
            name,
            symbol,
            configParams_
        );
    }

    function test_deployPool_success_withoutCoverRequired() external {
        uint256[6] memory noCoverConfigParams_ = [
            uint256(1_000_000e18),
            0.1e18,
            0,
            3 days,
            1 days,
            0
        ];

        vm.prank(poolDelegate);
        PoolDeployer(poolDeployer).deployPool(
            poolManagerFactory,
            withdrawalManagerFactory,
            loanManagerFactories,
            address(asset),
            name,
            symbol,
            noCoverConfigParams_
        );
    }

}

