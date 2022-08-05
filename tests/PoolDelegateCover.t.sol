// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolDelegateCover }      from "../contracts/PoolDelegateCover.sol";

contract PoolDelegateCoverTests is TestUtils {

    address pool         = address(new Address());
    address poolManager  = address(new Address());
    address poolDelegate = address(new Address());

    address asset;
    address poolDelegateCover;

    function setUp() public virtual {
        asset             = address(new MockERC20("Asset", "AT", 18));
        poolDelegateCover = address(new PoolDelegateCover(poolManager, asset));

        MockERC20(asset).mint(poolDelegateCover, 1_000e18);
    }

    function test_moveFunds_notManager() public {
        vm.expectRevert("PDC:MF:NOT_MANAGER");
        PoolDelegateCover(poolDelegateCover).moveFunds(1_000e18, pool);

        vm.prank(poolManager);
        PoolDelegateCover(poolDelegateCover).moveFunds(1_000e18, pool);
    }

    function test_moveFunds_badTransfer() public {
        vm.startPrank(poolManager);
        vm.expectRevert("PDC:MF:TRANSFER_FAILED");
        PoolDelegateCover(poolDelegateCover).moveFunds(1_000e18 + 1, pool);

        PoolDelegateCover(poolDelegateCover).moveFunds(1_000e18, pool);
    }

    function test_moveFunds_success() public {
        assertEq(MockERC20(asset).balanceOf(pool),              0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);

        vm.startPrank(poolManager);
        PoolDelegateCover(poolDelegateCover).moveFunds(600e18, pool);

        assertEq(MockERC20(asset).balanceOf(pool),              600e18);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 400e18);
    }

}
