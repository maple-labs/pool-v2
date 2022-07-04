// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { ConstructablePoolManager as PoolManager } from "./mocks/Mocks.sol";
import { MockGlobals } from "./mocks/Mocks.sol"; 

contract PoolManagerBase is TestUtils {

    address constant GOVERNOR = address(1);
    address constant PD       = address(2);

    MockERC20   asset;
    MockGlobals globals;
    PoolManager poolManager;

    function setUp() public virtual {
        asset       = new MockERC20("Asset", "MA", 18);
        globals     = new MockGlobals(GOVERNOR);
        poolManager = new PoolManager(address(globals), PD, address(asset));
    }
    
}

contract TestSetActive is PoolManagerBase {

    function test_setActive() external {
        assertTrue(!poolManager.active());

        vm.prank(GOVERNOR);
        poolManager.setActive(true);

        assertTrue(poolManager.active());

        vm.prank(GOVERNOR);
        poolManager.setActive(false);

        assertTrue(!poolManager.active());
    }

}

contract TestSetActiveFailure is PoolManagerBase {
    
    function test_setActive_failWithNotGovernor() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SA:NOT_GOVERNOR");
        poolManager.setActive(true);

        // Still false
        assertTrue(!poolManager.active());

        vm.prank(GOVERNOR);
        poolManager.setActive(true);

        assertTrue(poolManager.active());
    }

}
