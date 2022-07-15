// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                   from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolManager }            from "../contracts/PoolManager.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import { MockERC20Pool, MockGlobals, MockLoan, MockLoanManager } from "./mocks/Mocks.sol";

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

contract AcceptPendingAdmin_SetterTests is PoolManagerBase {

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

    function test_acceptPendingAdmin_success() external {
        assertEq(poolManager.pendingAdmin(), SET_ADDRESS);
        assertEq(poolManager.admin(),        POOL_DELEGATE);

        vm.prank(SET_ADDRESS);
        poolManager.acceptPendingAdmin();

        assertEq(poolManager.pendingAdmin(), address(0));
        assertEq(poolManager.admin(),        SET_ADDRESS);
    }

}

contract SetPendingAdmin_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());
    address SET_ADDRESS       = address(new Address());

    function test_setPendingAdmin_notAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SPA:NOT_ADMIN");
        poolManager.setPendingAdmin(SET_ADDRESS);
    }

    function test_setPendingAdmin_success() external {
        assertEq(poolManager.pendingAdmin(), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setPendingAdmin(SET_ADDRESS);

        assertEq(poolManager.pendingAdmin(), SET_ADDRESS);
    }

}

contract SetActive_SetterTests is PoolManagerBase {

    function test_setActive_notGovernor() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SA:NOT_GLOBALS");
        poolManager.setActive(true);
    }

    function test_setActive_success() external {
        assertTrue(!poolManager.active());

        vm.prank(address(globals));
        poolManager.setActive(true);

        assertTrue(poolManager.active());

        vm.prank(address(globals));
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

    function test_setAllowedLender_success() external {
        assertTrue(!poolManager.isValidLender(address(this)));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(address(this), true);

        assertTrue(poolManager.isValidLender(address(this)));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(address(this), false);

        assertTrue(!poolManager.isValidLender(address(this)));
    }
}

contract SetCoverFee_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());

    uint256 newFee = uint256(0.1e18);

    function test_setCoverFee_notAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SCF:NOT_ADMIN");
        poolManager.setCoverFee(newFee);
    }

    function test_setCoverFee_success() external {
        assertEq(poolManager.coverFee(), uint256(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setCoverFee(newFee);

        assertEq(poolManager.coverFee(), newFee);
    }

}

contract SetLiquidityCap_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());

    function test_setLiquidityCap_notAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SLC:NOT_ADMIN");
        poolManager.setLiquidityCap(1000);
    }

    function test_setLiquidityCap_success() external {
        assertEq(poolManager.liquidityCap(), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1000);

        assertEq(poolManager.liquidityCap(), 1000);
    }

}

contract SetManagementFee_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());

    uint256 newFee = uint256(0.1e18);

    function test_setManagementFee_notAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SMF:NOT_ADMIN");
        poolManager.setManagementFee(newFee);
    }

    function test_setManagementFee_success() external {
        assertEq(poolManager.managementFee(), uint256(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setManagementFee(newFee);

        assertEq(poolManager.managementFee(), newFee);
    }

}

contract SetOpenToPublic_SetterTests is PoolManagerBase {

    function test_setOpenToPublic_notAdmin() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SOTP:NOT_ADMIN");
        poolManager.setOpenToPublic();
    }

    function test_setOpenToPublic_success() external {
        assertTrue(!poolManager.openToPublic());

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        assertTrue(poolManager.openToPublic());
    }
}

contract ClaimTests is PoolManagerBase {

    // TODO: Refactor claim function first.

}

contract FundTests is PoolManagerBase {

    MockLoan        loan;
    MockLoanManager loanManager;
    MockERC20Pool   pool;

    uint256 principalRequested = 1_000_000e18;
    uint256 collateralRequired = 0;

    function setUp() public override {
        super.setUp();

        loanManager = new MockLoanManager();
        loan        = new MockLoan(address(asset), address(asset), principalRequested, collateralRequired);
        pool        = new MockERC20Pool(address(poolManager), address(asset), "Pool", "Pool");

        // Replace the pool in the poolManager
        address currentPool_ = poolManager.pool();
        vm.etch(currentPool_, address(pool).code);

        pool = MockERC20Pool(currentPool_);

        vm.prank(POOL_DELEGATE);
        poolManager.setLoanManager(address(loanManager), true);
    }

    function test_fund_notAdmin() external {
        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), principalRequested);

        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        vm.expectRevert("PM:F:NOT_ADMIN");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_zeroSupply() external {
        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), principalRequested);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:F:ZERO_SUPPLY");
        poolManager.fund(principalRequested, address(loan), address(loanManager));

    }

    function test_fund_transferFail() external {
        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("P:F:TRANSFER_FAIL");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_invalidLoanManager() external {
        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), principalRequested);

        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        // Remove the loanManager from the poolManager (added on setUp)
        vm.prank(POOL_DELEGATE);
        poolManager.setLoanManager(address(loanManager), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:F:INVALID_LOAN_MANAGER");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_success() external {
        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), principalRequested);

        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        assertEq(poolManager.loanManagers(address(loan)), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.fund(principalRequested, address(loan), address(loanManager));

        assertEq(poolManager.loanManagers(address(loan)), address(loanManager));
    }

}

contract RedeemTests is PoolManagerBase {

    function test_redeem_notWithdrawalManager() external {
        // TODO
    }

    function test_redeem_success() external {
        // TODO
    }

}

contract SetLoanManager_SetterTests is PoolManagerBase {

    address LOAN_MANAGER      = address(new Address());
    address NOT_POOL_DELEGATE = address(new Address());

    function test_setLoanManager_notPD() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SIM:NOT_ADMIN");
        poolManager.setLoanManager(LOAN_MANAGER, true);
    }

    function test_setLoanManager() external {
        assertTrue(!poolManager.isLoanManager(LOAN_MANAGER));

        vm.prank(POOL_DELEGATE);
        poolManager.setLoanManager(LOAN_MANAGER, true);

        assertTrue(poolManager.isLoanManager(LOAN_MANAGER));

        vm.prank(POOL_DELEGATE);
        poolManager.setLoanManager(LOAN_MANAGER, false);

        assertTrue(!poolManager.isLoanManager(LOAN_MANAGER));
    }

}

contract SetWithdrawalManager_SetterTests is PoolManagerBase {

    address WITHDRAWAL_MANAGER = address(new Address());
    address NOT_POOL_DELEGATE  = address(new Address());

    function test_setWithdrawalManager_notPD() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SWM:NOT_ADMIN");
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);
    }

    function test_setWithdrawalManager() external {
        assertEq(poolManager.withdrawalManager(), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);

        assertEq(poolManager.withdrawalManager(), WITHDRAWAL_MANAGER);
    }

}
