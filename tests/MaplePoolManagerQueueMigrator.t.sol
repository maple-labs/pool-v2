// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { Test }      from "../modules/forge-std/src/Test.sol";
import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MaplePoolManager }            from "../contracts/MaplePoolManager.sol";
import { MaplePoolManagerFactory }     from "../contracts/proxy/MaplePoolManagerFactory.sol";
import { MaplePoolManagerInitializer } from "../contracts/proxy/MaplePoolManagerInitializer.sol";
import { MaplePoolManagerWMMigrator }  from "../contracts/proxy/MaplePoolManagerWMMigrator.sol";

import { MockFactory, MockGlobals, MockWithdrawalManager } from "./mocks/Mocks.sol";

contract MaplePoolManagerWMMigratorTests is Test {

    address governor;
    address poolDelegate;

    address implementationV1;
    address implementationV2;
    address initializer;
    address migrator;

    MockERC20             asset;
    MockFactory           withdrawalManagerfactory;
    MockGlobals           globals;
    MockWithdrawalManager withdrawalManager;

    MaplePoolManager        poolManager;
    MaplePoolManagerFactory factory;

    function setUp() public virtual {
        governor          = makeAddr("governor");
        poolDelegate      = makeAddr("poolDelegate");

        implementationV1 = address(new MaplePoolManager());
        implementationV2 = address(new MaplePoolManager());
        initializer      = address(new MaplePoolManagerInitializer());
        migrator         = address(new MaplePoolManagerWMMigrator());

        asset                    = new MockERC20("USD Coin", "USDC", 6);
        globals                  = new MockGlobals(governor);
        withdrawalManager        = new MockWithdrawalManager();
        withdrawalManagerfactory = new MockFactory();

        globals.setValidPoolDeployer(address(this), true);
        globals.setValidPoolAsset(address(asset), true);
        globals.setValidPoolDelegate(poolDelegate, true);
        globals.__setIsValidScheduledCall(true);

        withdrawalManager.__setFactory(address(withdrawalManagerfactory));

        factory = new MaplePoolManagerFactory(address(globals));

        vm.startPrank(governor);
        factory.registerImplementation(200, implementationV1, initializer);
        factory.registerImplementation(300, implementationV2, initializer);
        factory.enableUpgradePath(200, 300, migrator);
        factory.setDefaultVersion(200);
        vm.stopPrank();

        poolManager = MaplePoolManager(MaplePoolManagerFactory(factory).createInstance(
            abi.encode(poolDelegate, address(asset), 0, "Maple Pool", "MP"),
            "salt"
        ));
    }

    function test_migrator_invalidPoolManager() external {
        globals.setValidInstance("QUEUE_POOL_MANAGER", address(poolManager), false);

        vm.prank(poolDelegate);
        vm.expectRevert("MPF:UI:FAILED");
        poolManager.upgrade(300, abi.encode(address(withdrawalManager)));
    }

    function test_migrator_invalidFactory() external {
        globals.setValidInstance("QUEUE_POOL_MANAGER",               address(poolManager),              true);
        globals.setValidInstance("WITHDRAWAL_MANAGER_QUEUE_FACTORY", address(withdrawalManagerfactory), false);

        vm.prank(poolDelegate);
        vm.expectRevert("MPF:UI:FAILED");
        poolManager.upgrade(300, abi.encode(address(withdrawalManager)));
    }

    function test_migrator_invalidInstance() external {
        globals.setValidInstance("QUEUE_POOL_MANAGER",               address(poolManager),              true);
        globals.setValidInstance("WITHDRAWAL_MANAGER_QUEUE_FACTORY", address(withdrawalManagerfactory), true);

        withdrawalManagerfactory.__setIsInstance(address(withdrawalManager), false);

        vm.prank(poolDelegate);
        vm.expectRevert("MPF:UI:FAILED");
        poolManager.upgrade(300, abi.encode(address(withdrawalManager)));
    }

    function test_migrator_success() external {
        globals.setValidInstance("QUEUE_POOL_MANAGER",               address(poolManager),              true);
        globals.setValidInstance("WITHDRAWAL_MANAGER_QUEUE_FACTORY", address(withdrawalManagerfactory), true);

        withdrawalManagerfactory.__setIsInstance(address(withdrawalManager), true);

        assertEq(factory.versionOf(poolManager.implementation()), 200);

        assertEq(poolManager.withdrawalManager(), address(0));

        vm.prank(poolDelegate);
        poolManager.upgrade(300, abi.encode(address(withdrawalManager)));

        assertEq(factory.versionOf(poolManager.implementation()), 300);

        assertEq(poolManager.withdrawalManager(), address(withdrawalManager));
    }

}
