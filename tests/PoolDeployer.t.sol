// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { Address, TestUtils }                    from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                             from "../modules/erc20/contracts/test/mocks/MockERC20.sol";
import { IMapleProxyFactory, MapleProxyFactory } from "../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

import { PoolDeployer } from "../contracts/PoolDeployer.sol";

import {
    MockGlobals,
    MockLoanManagerInitializer,
    MockProxied,
    MockPoolManager,
    MockPoolManagerInitializer,
    MockWithdrawalManagerInitializer
} from "./mocks/Mocks.sol";

import { GlobalsBootstrapper } from "./bootstrap/GlobalsBootstrapper.sol";

contract PoolDeployerTests is TestUtils, GlobalsBootstrapper {

    address internal poolDelegate = address(new Address());

    address internal asset;

    address internal poolManagerFactory;
    address internal poolManagerImplementation;
    address internal poolManagerInitializer;

    address internal loanManagerFactory;
    address internal loanManagerImplementation;
    address internal loanManagerInitializer;

    address internal withdrawalManagerFactory;
    address internal withdrawalManagerImplementation;
    address internal withdrawalManagerInitializer;

    function setUp() public virtual {
        asset = address(new MockERC20("Asset", "AT", 18));
        _deployAndBootstrapGlobals(address(asset), poolDelegate);

        poolManagerFactory        = address(new MapleProxyFactory(globals));
        poolManagerImplementation = address(new MockPoolManager());
        poolManagerInitializer    = address(new MockPoolManagerInitializer());

        loanManagerFactory        = address(new MapleProxyFactory(globals));
        loanManagerImplementation = address(new MockProxied());
        loanManagerInitializer    = address(new MockLoanManagerInitializer());

        withdrawalManagerFactory        = address(new MapleProxyFactory(globals));
        withdrawalManagerImplementation = address(new MockProxied());
        withdrawalManagerInitializer    = address(new MockWithdrawalManagerInitializer());

        vm.startPrank(GOVERNOR);
        IMapleProxyFactory(poolManagerFactory).registerImplementation(1, poolManagerImplementation, poolManagerInitializer);
        IMapleProxyFactory(poolManagerFactory).setDefaultVersion(1);

        IMapleProxyFactory(loanManagerFactory).registerImplementation(1, loanManagerImplementation, loanManagerInitializer);
        IMapleProxyFactory(loanManagerFactory).setDefaultVersion(1);

        IMapleProxyFactory(withdrawalManagerFactory).registerImplementation(
            1,
            withdrawalManagerImplementation,
            withdrawalManagerInitializer
        );

        IMapleProxyFactory(withdrawalManagerFactory).setDefaultVersion(1);
        vm.stopPrank();
    }

    function test_deployPool_transferFailed() external {
        string memory name_   = "Pool";
        string memory symbol_ = "P2";

        address poolDeployer = address(new PoolDeployer(globals));
        MockGlobals(globals).setValidPoolDeployer(poolDeployer, true);

        address[3] memory factories_ = [
            poolManagerFactory,
            loanManagerFactory,
            withdrawalManagerFactory
        ];

        address[3] memory initializers_ = [
            poolManagerInitializer,
            loanManagerInitializer,
            withdrawalManagerInitializer
        ];

        uint256 coverAmountRequired = 10e18;
        uint256[6] memory configParams_ = [
            1_000_000e18,
            0.1e18,
            coverAmountRequired,
            3 days,
            1 days,
            0
        ];

        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);
        MockERC20(asset).mint(poolDelegate, coverAmountRequired - 1);

        vm.prank(poolDelegate);
        vm.expectRevert("PD:DP:TRANSFER_FAILED");
        PoolDeployer(poolDeployer).deployPool(
            factories_,
            initializers_,
            address(asset),
            name_,
            symbol_,
            configParams_
        );

        MockERC20(asset).mint(poolDelegate, 1);

        vm.prank(poolDelegate);
        PoolDeployer(poolDeployer).deployPool(
            factories_,
            initializers_,
            address(asset),
            name_,
            symbol_,
            configParams_
        );
    }

    function test_deployPool_invalidPoolDelegate() external {
        string memory name_   = "Pool";
        string memory symbol_ = "P2";

        address poolDeployer = address(new PoolDeployer(globals));
        MockGlobals(globals).setValidPoolDeployer(poolDeployer, true);

        address[3] memory factories_ = [
            poolManagerFactory,
            loanManagerFactory,
            withdrawalManagerFactory
        ];

        address[3] memory initializers_ = [
            poolManagerInitializer,
            loanManagerInitializer,
            withdrawalManagerInitializer
        ];

        uint256 coverAmountRequired = 10e18;
        uint256[6] memory configParams_ = [
            1_000_000e18,
            0.1e18,
            coverAmountRequired,
            3 days,
            1 days,
            0
        ];

        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);
        MockERC20(asset).mint(poolDelegate, coverAmountRequired);

        vm.expectRevert("PD:DP:INVALID_PD");
        PoolDeployer(poolDeployer).deployPool(
            factories_,
            initializers_,
            address(asset),
            name_,
            symbol_,
            configParams_
        );

        vm.prank(poolDelegate);
        PoolDeployer(poolDeployer).deployPool(
            factories_,
            initializers_,
            address(asset),
            name_,
            symbol_,
            configParams_
        );
    }

    function test_deployPool_invalidInitializers() external {
        string memory name_   = "Pool";
        string memory symbol_ = "P2";

        address poolDeployer = address(new PoolDeployer(globals));
        MockGlobals(globals).setValidPoolDeployer(poolDeployer, true);

        address[3] memory factories_ = [
            poolManagerFactory,
            loanManagerFactory,
            withdrawalManagerFactory
        ];

        address incorrectLoanManagerInitializer       = address(new Address());
        address incorrectPoolManagerInitializer       = address(new Address());
        address incorrectWithdrawalManagerInitializer = address(new Address());

        address[3] memory initializers_ = [
            incorrectPoolManagerInitializer,
            loanManagerInitializer,
            withdrawalManagerInitializer
        ];

        uint256 coverAmountRequired = 10e18;
        uint256[6] memory configParams_ = [
            1_000_000e18,
            0.1e18,
            coverAmountRequired,
            3 days,
            1 days,
            0
        ];

        vm.prank(poolDelegate);
        MockERC20(asset).approve(poolDeployer, coverAmountRequired);
        MockERC20(asset).mint(poolDelegate, coverAmountRequired);

        vm.expectRevert("PD:DP:INVALID_PM_INITIALIZER");
        vm.prank(poolDelegate);
        PoolDeployer(poolDeployer).deployPool(
            factories_,
            initializers_,
            address(asset),
            name_,
            symbol_,
            configParams_
        );

        initializers_ = [
            poolManagerInitializer,
            incorrectLoanManagerInitializer,
            withdrawalManagerInitializer
        ];

        vm.expectRevert("PD:DP:INVALID_LM_INITIALIZER");
        vm.prank(poolDelegate);
        PoolDeployer(poolDeployer).deployPool(
            factories_,
            initializers_,
            address(asset),
            name_,
            symbol_,
            configParams_
        );

        initializers_ = [
            poolManagerInitializer,
            loanManagerInitializer,
            incorrectWithdrawalManagerInitializer
        ];

        vm.expectRevert("PD:DP:INVALID_WM_INITIALIZER");
        vm.prank(poolDelegate);
        PoolDeployer(poolDeployer).deployPool(
            factories_,
            initializers_,
            address(asset),
            name_,
            symbol_,
            configParams_
        );

        initializers_ = [
            poolManagerInitializer,
            loanManagerInitializer,
            withdrawalManagerInitializer
        ];

        vm.prank(poolDelegate);
        PoolDeployer(poolDeployer).deployPool(
            factories_,
            initializers_,
            address(asset),
            name_,
            symbol_,
            configParams_
        );
    }

}

