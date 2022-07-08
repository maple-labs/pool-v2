// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                   from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolManager }            from "../contracts/PoolManager.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import { MockGlobals } from "./mocks/Mocks.sol";

contract PoolManagerBase is TestUtils {

    address GOVERNOR      = address(new Address());
    address POOL_DELEGATE = address(new Address());

    MockERC20          asset;
    MockGlobals        globals;
    PoolManager        poolManager;
    PoolManagerFactory factory;

    address implementation;
    address initializer;

    function setUp() public virtual {
        globals = new MockGlobals(GOVERNOR);
        factory = new PoolManagerFactory(address(globals));
        asset   = new MockERC20("Asset", "AT", 18);

        implementation = address(new PoolManager());
        initializer    = address(new PoolManagerInitializer());

        globals.setValidPoolDelegate(POOL_DELEGATE, true);

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "POOL1";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), POOL_DELEGATE, address(asset), poolName_, poolSymbol_);

        poolManager = PoolManager(PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(POOL_DELEGATE))));
    }

}

contract AcceptPendingPoolDelegate_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());
    address SET_ADDRESS       = address(new Address());

    function setUp() public override {
        super.setUp();
        vm.prank(POOL_DELEGATE);
        poolManager.setPendingAdmin(SET_ADDRESS);
    }

    function test_acceptPendingAdmin_notPendingAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:APA:NOT_PENDING_ADMIN");
        poolManager.acceptPendingAdmin();
    }

    function test_acceptPendingAdmin() external {
        assertEq(poolManager.pendingAdmin(), SET_ADDRESS);
        assertEq(poolManager.admin(),        POOL_DELEGATE);

        vm.prank(SET_ADDRESS);
        poolManager.acceptPendingAdmin();

        assertEq(poolManager.pendingAdmin(), address(0));
        assertEq(poolManager.admin(),        SET_ADDRESS);
    }

}

contract SetActive_SetterTests is PoolManagerBase {

    function test_setActive_notGovernor() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SA:NOT_GOVERNOR");
        poolManager.setActive(true);
    }

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

contract SetAllowedLender_SetterTests is PoolManagerBase {

    function test_setAllowedLender_notAdmin() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SAL:NOT_ADMIN");
        poolManager.setAllowedLender(address(this), true);
    }

    function test_setAllowedLender() external {
        assertTrue(!poolManager.isValidLender(address(this)));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(address(this), true);

        assertTrue(poolManager.isValidLender(address(this)));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(address(this), false);

        assertTrue(!poolManager.isValidLender(address(this)));
    }
}

contract SetLiquidityCap_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());

    function test_setLiquidityCap_notAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SLC:NOT_ADMIN");
        poolManager.setLiquidityCap(1000);
    }

    function test_setLiquidityCap() external {
        assertEq(poolManager.liquidityCap(), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1000);

        assertEq(poolManager.liquidityCap(), 1000);
    }

}

contract SetOpenToPublic_SetterTests is PoolManagerBase {

    function test_setOpenToPublic_notAdmin() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SOTP:NOT_ADMIN");
        poolManager.setOpenToPublic();
    }

    function test_setOpenToPublic() external {
        assertTrue(!poolManager.openToPublic());

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        assertTrue(poolManager.openToPublic());
    }
}

contract SetPendingPoolDelegate_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());
    address SET_ADDRESS       = address(new Address());

    function test_setPendingAdmin_notAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SPA:NOT_ADMIN");
        poolManager.setPendingAdmin(SET_ADDRESS);
    }

    function test_setPendingAdmin() external {
        assertEq(poolManager.pendingAdmin(), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setPendingAdmin(SET_ADDRESS);

        assertEq(poolManager.pendingAdmin(), SET_ADDRESS);
    }

}
