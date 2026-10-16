// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MaplePoolManagerFactory } from "../contracts/proxy/MaplePoolManagerFactory.sol";
import { IMaplePoolManagerInitializer } from "../contracts/interfaces/IMaplePoolManagerInitializer.sol";

import { MaplePool } from "../contracts/MaplePool.sol";

import { MaplePoolManagerInitializerHarness } from "./utils/Harnesses.sol";

import { MockGlobals } from "./utils/Mocks.sol";

import { TestBase } from "./utils/TestBase.sol";

contract PoolManagerInitializerTestBase is TestBase {

    address internal poolDelegate = makeAddr("poolDelegate");

    MockERC20 internal asset;
    MaplePoolManagerFactory internal factory;

    MaplePoolManagerInitializerHarness internal initializer;

    function setUp() public virtual {
        asset = new MockERC20("Asset", "AT", 18);

        _deployAndBootstrapGlobals(address(asset), poolDelegate);

        factory     = new MaplePoolManagerFactory(address(globals));
        initializer = new MaplePoolManagerInitializerHarness();
    }

}

contract InitializeTests is PoolManagerInitializerTestBase {

    function test_initialize_revert_zeroPoolDelegate() external {
        vm.prank(address(factory));
        vm.expectRevert("PMI:I:ZERO_PD");
        initializer.__initialize(address(0), address(asset), 0, "Pool", "P2");
    }

    function test_initialize_revert_zeroAsset() external {
        vm.prank(address(factory));
        vm.expectRevert("PMI:I:ZERO_ASSET");
        initializer.__initialize(poolDelegate, address(0), 0, "Pool", "P2");
    }

    function test_initialize_revert_notPoolDelegate() external {
        address invalidPoolDelegate = makeAddr("invalidPoolDelegate");

        vm.prank(address(factory));
        vm.expectRevert("PMI:I:NOT_PD");
        initializer.__initialize(invalidPoolDelegate, address(asset), 0, "Pool", "P2");
    }

    function test_initialize_revert_poolOwner() external {
        MockGlobals(globals).__setOwnedPoolManager(poolDelegate, address(13));

        vm.prank(address(factory));
        vm.expectRevert("PMI:I:POOL_OWNER");
        initializer.__initialize(poolDelegate, address(asset), 0, "Pool", "P2");
    }

    function test_initialize_revert_assetNotAllowed() external {
        MockGlobals(globals).setValidPoolAsset(address(asset), false);

        vm.prank(address(factory));
        vm.expectRevert("PMI:I:ASSET_NOT_ALLOWED");
        initializer.__initialize(poolDelegate, address(asset), 0, "Pool", "P2");
    }

    function test_initialize_revert_invalidPoolParams() external {
        vm.prank(address(factory));
        vm.expectRevert("PMI:I:INVALID_POOL_PARAMS");
        initializer.__initialize(poolDelegate, address(asset), 1, "Pool", "P2");
    }

    function test_initialize_success() external {
        address expectedPool = computeCreateAddress(address(initializer), vm.getNonce(address(initializer)));

        vm.expectEmit(address(initializer));
        emit IMaplePoolManagerInitializer.Initialized(poolDelegate, address(asset), expectedPool);

        vm.prank(address(factory));
        initializer.__initialize(poolDelegate, address(asset), 0, "Pool", "P2");

        assertEq(initializer.poolDelegate(),              poolDelegate);
        assertEq(initializer.asset(),                     address(asset));
        assertEq(initializer.pool(),                      expectedPool);
        assertEq(initializer.pendingPoolDelegate(),       address(0));
        assertEq(initializer.withdrawalManager(),         address(0));
        assertEq(initializer.poolPermissionManager(),     address(0));
        assertEq(initializer.liquidityCap(),              0);
        assertEq(initializer.delegateManagementFeeRate(), 0);

        assertTrue(!initializer.active());
        assertTrue(!initializer.configured());

        MaplePool pool = MaplePool(initializer.pool());

        assertEq(pool.manager(), address(initializer));
        assertEq(pool.asset(),   address(asset));
    }

}
