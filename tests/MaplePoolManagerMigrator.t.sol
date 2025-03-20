// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { Test }      from "../modules/forge-std/src/Test.sol";
import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MaplePoolManager }            from "../contracts/MaplePoolManager.sol";
import { MaplePoolManagerFactory }     from "../contracts/proxy/MaplePoolManagerFactory.sol";
import { MaplePoolManagerInitializer } from "../contracts/proxy/MaplePoolManagerInitializer.sol";
import { MaplePoolManagerMigrator }    from "../contracts/proxy/MaplePoolManagerMigrator.sol";

import { MockGlobals, MockPoolPermissionManager } from "./mocks/Mocks.sol";

import { TestBase } from "./utils/TestBase.sol";

contract MaplePoolManagerMigratorTests is TestBase {

    address governor;
    address poolDelegate;

    address implementationV1;
    address implementationV2;
    address initializer;
    address migrator;

    MockERC20                 asset;
    MockGlobals               globals_;
    MockPoolPermissionManager ppm;

    MaplePoolManager        poolManager;
    MaplePoolManagerFactory factory;

    function setUp() public virtual {
        governor     = makeAddr("governor");
        poolDelegate = makeAddr("poolDelegate");

        implementationV1 = deploy("MaplePoolManager");
        implementationV2 = deploy("MaplePoolManager");
        initializer      = deploy("MaplePoolManagerInitializer");
        migrator         = deploy("MaplePoolManagerMigrator");

        asset    = new MockERC20("USD Coin", "USDC", 6);
        globals_ = new MockGlobals(governor);
        ppm      = new MockPoolPermissionManager();

        globals_.setValidPoolDeployer(address(this), true);
        globals_.setValidPoolAsset(address(asset), true);
        globals_.setValidPoolDelegate(poolDelegate, true);
        globals_.__setIsValidScheduledCall(true);

        factory = new MaplePoolManagerFactory(address(globals_));

        vm.startPrank(governor);
        factory.registerImplementation(100, implementationV1, initializer);
        factory.registerImplementation(200, implementationV2, initializer);
        factory.enableUpgradePath(100, 200, migrator);
        factory.setDefaultVersion(100);
        vm.stopPrank();

        poolManager = MaplePoolManager(MaplePoolManagerFactory(factory).createInstance(
            abi.encode(poolDelegate, address(asset), 0, "Maple Pool", "MP"),
            "salt"
        ));
    }

    function test_migrator_failure() external {
        globals_.setValidInstance("POOL_PERMISSION_MANAGER", address(ppm), false);

        vm.prank(poolDelegate);
        vm.expectRevert("MPF:UI:FAILED");
        poolManager.upgrade(200, abi.encode(address(ppm)));
    }

    function test_migrator_success() external {
        globals_.setValidInstance("POOL_PERMISSION_MANAGER", address(ppm), true);

        assertEq(factory.versionOf(poolManager.implementation()), 100);

        assertEq(poolManager.poolPermissionManager(), address(0));

        vm.prank(poolDelegate);
        poolManager.upgrade(200, abi.encode(address(ppm)));

        assertEq(factory.versionOf(poolManager.implementation()), 200);

        assertEq(poolManager.poolPermissionManager(), address(ppm));
    }

}
