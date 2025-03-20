// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { Test }      from "../modules/forge-std/src/Test.sol";
import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MaplePoolDelegateCover } from "../contracts/MaplePoolDelegateCover.sol";

contract MaplePoolDelegateCoverTests is Test {

    address pool         = makeAddr("pool");
    address poolManager  = makeAddr("poolManager");
    address poolDelegate = makeAddr("poolDelegate");

    address asset;
    address poolDelegateCover;

    function setUp() public virtual {
        asset             = address(new MockERC20("Asset", "AT", 18));
        poolDelegateCover = address(new MaplePoolDelegateCover(poolManager, asset));

        MockERC20(asset).mint(poolDelegateCover, 1_000e18);
    }

    function test_moveFunds_notManager() public {
        vm.expectRevert("PDC:MF:NOT_MANAGER");
        MaplePoolDelegateCover(poolDelegateCover).moveFunds(1_000e18, pool);

        vm.prank(poolManager);
        MaplePoolDelegateCover(poolDelegateCover).moveFunds(1_000e18, pool);
    }

    function test_moveFunds_badTransfer() public {
        vm.startPrank(poolManager);
        vm.expectRevert("PDC:MF:TRANSFER_FAILED");
        MaplePoolDelegateCover(poolDelegateCover).moveFunds(1_000e18 + 1, pool);

        MaplePoolDelegateCover(poolDelegateCover).moveFunds(1_000e18, pool);
    }

    function test_moveFunds_success() public {
        assertEq(MockERC20(asset).balanceOf(pool),              0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);

        vm.startPrank(poolManager);
        MaplePoolDelegateCover(poolDelegateCover).moveFunds(600e18, pool);

        assertEq(MockERC20(asset).balanceOf(pool),              600e18);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 400e18);
    }

}
