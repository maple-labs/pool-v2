// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { Test }      from "../modules/forge-std/src/Test.sol";
import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MaplePoolManager }            from "../contracts/MaplePoolManager.sol";
import { MaplePoolManagerFactory }     from "../contracts/proxy/MaplePoolManagerFactory.sol";
import { MaplePoolManagerInitializer } from "../contracts/proxy/MaplePoolManagerInitializer.sol";

import {
    MockERC20Pool,
    MockFactory,
    MockLoanFactory,
    MockGlobals,
    MockLoan,
    MockLoanManager,
    MockPoolManagerMigrator,
    MockPoolManagerMigratorInvalidPoolDelegateCover,
    MockPoolPermissionManager,
    MockWithdrawalManager
} from "./mocks/Mocks.sol";

import { MaplePoolManagerHarness } from "./harnesses/MaplePoolManagerHarness.sol";

import { TestBase } from "./utils/TestBase.sol";

contract PoolManagerTestBase is TestBase {

    address internal POOL_DELEGATE = makeAddr("POOL_DELEGATE");

    MockERC20                 internal asset;
    MockERC20Pool             internal pool;
    MockFactory               internal liquidatorFactory;
    MockFactory               internal withdrawalManagerFactory;
    MockPoolPermissionManager internal mockPoolPermissionManager;

    MaplePoolManagerHarness internal poolManager;
    MaplePoolManagerFactory internal factory;

    address internal implementation;
    address internal initializer;
    address internal withdrawalManager;

    function setUp() public virtual {
        asset = new MockERC20("Asset", "AT", 18);

        _deployAndBootstrapGlobals(address(asset), POOL_DELEGATE);

        factory = new MaplePoolManagerFactory(address(globals));

        implementation = address(new MaplePoolManagerHarness());
        initializer    = address(new MaplePoolManagerInitializer());

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "POOL1";

        MockGlobals(globals).setValidPoolDeployer(address(this), true);

        bytes memory arguments = abi.encode(POOL_DELEGATE, address(asset), 0, poolName_, poolSymbol_);

        poolManager = MaplePoolManagerHarness(MaplePoolManagerFactory(factory).createInstance(
            arguments,
            keccak256(abi.encode(POOL_DELEGATE))
        ));

        mockPoolPermissionManager = new MockPoolPermissionManager();
        mockPoolPermissionManager.__setAllowed(true);

        poolManager.__setPoolPermissionManager(address(mockPoolPermissionManager));

        withdrawalManagerFactory = new MockFactory();
        withdrawalManager        = address(new MockWithdrawalManager());

        withdrawalManagerFactory.__setIsInstance(withdrawalManager, true);
        MockWithdrawalManager(withdrawalManager).__setFactory(address(withdrawalManagerFactory));

        MockERC20Pool mockPool = new MockERC20Pool(address(poolManager), address(asset), poolName_, poolSymbol_);

        address poolAddress = poolManager.pool();

        vm.etch(poolAddress, address(mockPool).code);

        // Mint ERC20 to pool
        asset.mint(poolAddress, 1_000_000e18);

        pool = MockERC20Pool(poolAddress);

        // Get past zero supply check
        pool.mint(address(1), 1);

        vm.prank(globals);
        poolManager.setActive(true);

        liquidatorFactory = new MockFactory();
    }

}

contract CompleteConfigurationTests is PoolManagerTestBase {

    function test_completeConfiguration_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.expectRevert("PM:PAUSED");
        poolManager.completeConfiguration();
    }

    function test_completeConfiguration_alreadyConfigured() external {
        poolManager.__setConfigured(true);

        vm.expectRevert("PM:ALREADY_CONFIGURED");
        poolManager.completeConfiguration();
    }

    function test_completeConfiguration_success() external {
        poolManager.completeConfiguration();

        assertTrue(poolManager.configured());
    }

}

contract MigrateTests is PoolManagerTestBase {

    address internal invalidMigrator = address(new MockPoolManagerMigratorInvalidPoolDelegateCover());
    address internal migrator        = address(new MockPoolManagerMigrator());

    function test_migrate_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.expectRevert("PM:PAUSED");
        poolManager.migrate(migrator, "");
    }

    function test_migrate_notFactory() external {
        vm.expectRevert("PM:M:NOT_FACTORY");
        poolManager.migrate(migrator, "");
    }

    function test_migrate_internalFailure() external {
        vm.prank(poolManager.factory());
        vm.expectRevert("PM:M:FAILED");
        poolManager.migrate(migrator, "");
    }

    function test_migrate_invalidPoolDelegateCover() external {
        vm.prank(poolManager.factory());
        vm.expectRevert("PM:M:DELEGATE_NOT_SET");
        poolManager.migrate(invalidMigrator, "");
    }

    function test_migrate_success() external {
        assertEq(poolManager.poolDelegate(), POOL_DELEGATE);

        vm.prank(poolManager.factory());
        poolManager.migrate(migrator, abi.encode(address(0)));

        assertEq(poolManager.poolDelegate(), address(0));
    }

}

contract SetImplementationTests is PoolManagerTestBase {

    address internal newImplementation = deploy("MaplePoolManager");

    function test_setImplementation_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.expectRevert("PM:PAUSED");
        poolManager.setImplementation(newImplementation);
    }

    function test_setImplementation_notFactory() external {
        vm.expectRevert("PM:SI:NOT_FACTORY");
        poolManager.setImplementation(newImplementation);
    }

    function test_setImplementation_success() external {
        assertEq(poolManager.implementation(), implementation);

        vm.prank(poolManager.factory());
        poolManager.setImplementation(newImplementation);

        assertEq(poolManager.implementation(), newImplementation);
    }

}

contract UpgradeTests is PoolManagerTestBase {

    address internal SECURITY_ADMIN = makeAddr("SECURITY_ADMIN");

    address internal newImplementation = deploy("MaplePoolManager");

    function setUp() public override {
        super.setUp();

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(2, newImplementation, address(0));
        factory.enableUpgradePath(1, 2, address(0));
        vm.stopPrank();
    }

    function test_upgrade_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.expectRevert("PM:PAUSED");
        poolManager.upgrade(2, "");
    }

    function test_upgrade_noAuth() external {
        vm.expectRevert("PM:U:NO_AUTH");
        poolManager.upgrade(2, "");
    }

    function test_upgrade_notScheduled() external {
        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:U:INVALID_SCHED_CALL");
        poolManager.upgrade(2, "");
    }

    function test_upgrade_upgradeFailed() external {
        MockGlobals(globals).__setIsValidScheduledCall(true);
        vm.prank(POOL_DELEGATE);
        vm.expectRevert("MPF:UI:FAILED");
        poolManager.upgrade(2, "1");
    }

    function test_upgrade_successWithSecurityAdmin() external {
        MockGlobals(globals).__setSecurityAdmin(SECURITY_ADMIN);

        assertEq(poolManager.implementation(), implementation);

        // No need to schedule call
        vm.prank(SECURITY_ADMIN);
        poolManager.upgrade(2, "");

        assertEq(poolManager.implementation(), newImplementation);
    }

    function test_upgrade_successWithPoolDelegate() external {
        assertEq(poolManager.implementation(), implementation);

        MockGlobals(globals).__setIsValidScheduledCall(true);
        vm.prank(POOL_DELEGATE);
        poolManager.upgrade(2, "");

        assertEq(poolManager.implementation(), newImplementation);
    }

}

contract AcceptPoolDelegate_SetterTests is PoolManagerTestBase {

    address internal SET_ADDRESS = makeAddr("SET_ADDRESS");

    function setUp() public override {
        super.setUp();
        vm.prank(POOL_DELEGATE);
        poolManager.setPendingPoolDelegate(SET_ADDRESS);
    }

    function test_acceptPoolDelegate_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(SET_ADDRESS);
        vm.expectRevert("PM:PAUSED");
        poolManager.acceptPoolDelegate();
    }

    function test_acceptPoolDelegate_notPendingPoolDelegate() external {
        vm.expectRevert("PM:APD:NOT_PENDING_PD");
        poolManager.acceptPoolDelegate();
    }

    function test_acceptPoolDelegate_globalsTransferFails() external {
        MockGlobals(globals).__setFailTransferOwnedPoolManager(true);
        vm.prank(SET_ADDRESS);
        vm.expectRevert("MG:TOPM:FAILED");
        poolManager.acceptPoolDelegate();
    }

    function test_acceptPoolDelegate_success() external {
        MockGlobals(globals).__setFailTransferOwnedPoolManager(false);

        assertEq(poolManager.pendingPoolDelegate(), SET_ADDRESS);
        assertEq(poolManager.poolDelegate(),        POOL_DELEGATE);

        vm.prank(SET_ADDRESS);
        poolManager.acceptPoolDelegate();

        assertEq(poolManager.pendingPoolDelegate(), address(0));
        assertEq(poolManager.poolDelegate(),        SET_ADDRESS);
    }

}

contract SetPendingPoolDelegate_SetterTests is PoolManagerTestBase {

    address internal SET_ADDRESS = makeAddr("SET_ADDRESS");

    function test_setPendingPoolDelegate_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PAUSED");
        poolManager.setPendingPoolDelegate(SET_ADDRESS);
    }

    function test_setPendingPoolDelegate_notPoolDelegateOrProtocolAdmins() external {
        vm.expectRevert("PM:NOT_PD_OR_GOV_OR_OA");
        poolManager.setPendingPoolDelegate(SET_ADDRESS);
    }

    function test_setPendingPoolDelegate_asPoolDelegate_success() external {
        assertEq(poolManager.pendingPoolDelegate(), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setPendingPoolDelegate(SET_ADDRESS);

        assertEq(poolManager.pendingPoolDelegate(), SET_ADDRESS);
    }

    function test_setPendingPoolDelegate_asGovernor_success() external {
        assertEq(poolManager.pendingPoolDelegate(), address(0));

        vm.prank(GOVERNOR);
        poolManager.setPendingPoolDelegate(SET_ADDRESS);

        assertEq(poolManager.pendingPoolDelegate(), SET_ADDRESS);
    }

    function test_setPendingPoolDelegate_asOperationalAdmin_success() external {
        assertEq(poolManager.pendingPoolDelegate(), address(0));

        vm.prank(MockGlobals(globals).operationalAdmin());
        poolManager.setPendingPoolDelegate(SET_ADDRESS);

        assertEq(poolManager.pendingPoolDelegate(), SET_ADDRESS);
    }

}

contract SetActive_SetterTests is PoolManagerTestBase {

    function setUp() public override {
        super.setUp();
        vm.prank(globals);
        poolManager.setActive(false);
    }

    function test_setActive_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(address(globals));
        vm.expectRevert("PM:PAUSED");
        poolManager.setActive(true);
    }

    function test_setActive_notGlobals() external {
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

contract SetLiquidityCap_SetterTests is PoolManagerTestBase {

    function test_setLiquidityCap_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PAUSED");
        poolManager.setLiquidityCap(1000);
    }

    function test_setLiquidityCap_notPoolDelegate() external {
        poolManager.__setConfigured(true);

        vm.expectRevert("PM:NO_AUTH");
        poolManager.setLiquidityCap(1000);
    }

    function test_setLiquidityCap_success_whenNotConfigured() external {
        poolManager.setLiquidityCap(1000);

        assertEq(poolManager.liquidityCap(), 1000);
    }

    function test_setLiquidityCap_success_asPoolDelegate() external {
        poolManager.__setConfigured(true);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1000);

        assertEq(poolManager.liquidityCap(), 1000);
    }

}

contract SetDelegateManagementFeeRate_SetterTests is PoolManagerTestBase {

    uint256 internal newManagementFeeRate = 10_0000;

    function test_setDelegateManagementFeeRate_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PAUSED");
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);
    }

    function test_setDelegateManagementFeeRate_notPoolDelegate() external {
        poolManager.__setConfigured(true);

        vm.expectRevert("PM:NO_AUTH");
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);
    }

    function test_setDelegateManagementFeeRate_oob() external {
        vm.expectRevert("PM:SDMFR:OOB");
        poolManager.setDelegateManagementFeeRate(100_0001);

        poolManager.setDelegateManagementFeeRate(100_0000);
    }

    function test_setDelegateManagementFeeRate_success_whenNotConfigured() external {
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);

        assertEq(poolManager.delegateManagementFeeRate(), newManagementFeeRate);
    }

    function test_setDelegateManagementFeeRate_success_asPoolDelegate() external {
        poolManager.__setConfigured(true);

        vm.prank(POOL_DELEGATE);
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);

        assertEq(poolManager.delegateManagementFeeRate(), newManagementFeeRate);
    }

}

contract SetIsLoanManager_SetterTests is PoolManagerTestBase {

    address loanManager1;
    address loanManager2;

    function setUp() public override {
        super.setUp();

        loanManager1 = address(new MockLoanManager(address(pool), address(0), POOL_DELEGATE));
        loanManager2 = address(new MockLoanManager(address(pool), address(0), POOL_DELEGATE));

        poolManager.__setIsLoanManager(loanManager1, true);
        poolManager.__setIsLoanManager(loanManager2, true);
        poolManager.__pushToLoanManagerList(loanManager1);
        poolManager.__pushToLoanManagerList(loanManager2);
    }

    function test_setIsLoanManager_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.expectRevert("PM:PAUSED");
        poolManager.setIsLoanManager(loanManager2, false);
    }

    function test_setIsLoanManager_notPoolDelegate() external {
        vm.expectRevert("PM:NOT_PD");
        poolManager.setIsLoanManager(loanManager2, false);
    }

    function test_setIsLoanManager_invalidLM() external {
        address invalidLoanManager = address(new MockLoanManager(address(pool), address(0), POOL_DELEGATE));

        vm.startPrank(POOL_DELEGATE);
        vm.expectRevert("PM:SILM:INVALID_LM");
        poolManager.setIsLoanManager(invalidLoanManager, false);
    }

    function test_setIsLoanManager_success() external {
        assertTrue(poolManager.isLoanManager(loanManager2));

        vm.startPrank(POOL_DELEGATE);
        poolManager.setIsLoanManager(loanManager2, false);

        assertTrue(!poolManager.isLoanManager(loanManager2));

        poolManager.setIsLoanManager(loanManager2, true);

        assertTrue(poolManager.isLoanManager(loanManager2));
    }

}

contract TriggerDefault is PoolManagerTestBase {

    address internal AUCTIONEER        = makeAddr("AUCTIONEER");
    address internal BORROWER          = makeAddr("BORROWER");
    address internal LP                = makeAddr("LP");
    address internal OPERATIONAL_ADMIN = makeAddr("OPERATIONAL_ADMIN");

    address internal loan;
    address internal poolDelegateCover;

    MockLoanManager internal loanManager;

    function setUp() public override {
        super.setUp();

        loanManager = new MockLoanManager(address(pool), TREASURY, POOL_DELEGATE);

        poolDelegateCover = poolManager.poolDelegateCover();

        MockLoanFactory loanFactory = new MockLoanFactory();

        MockFactory loanManagerFactory = new MockFactory();

        loanManager.__setFactory(address(loanManagerFactory));

        loan = address(new MockLoan(address(asset), address(asset)));
        MockLoan(loan).__setBorrower(BORROWER);
        MockLoan(loan).__setFactory(address(loanFactory));
        MockLoan(loan).__setLender(address(loanManager));
        MockLoan(loan).__setPaymentsRemaining(3);
        MockGlobals(globals).setValidBorrower(BORROWER, true);
        MockGlobals(globals).setValidInstance("LOAN",                       address(loanFactory),              true);
        MockGlobals(globals).setValidInstance("LIQUIDATOR_FACTORY",         address(liquidatorFactory),        true);
        MockGlobals(globals).setValidInstance("LOAN_MANAGER_FACTORY",       address(loanManagerFactory),       true);
        MockGlobals(globals).setValidInstance("WITHDRAWAL_MANAGER_FACTORY", address(withdrawalManagerFactory), true);

        loanFactory.__setIsLoan(loan, true);

        vm.startPrank(POOL_DELEGATE);
        poolManager.__setIsLoanManager(address(loanManager), true);
        poolManager.__pushToLoanManagerList(address(loanManager));
        poolManager.setWithdrawalManager(withdrawalManager);
        vm.stopPrank();
    }

    function test_triggerDefault_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PAUSED");
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));
    }

    function test_triggerDefault_notAuthorized() external {
        vm.expectRevert("PM:NOT_PD_OR_GOV_OR_OA");
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));
    }

    function test_triggerDefault_invalidFactory() external {
        MockGlobals(globals).setValidInstance("LIQUIDATOR_FACTORY", address(liquidatorFactory), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:TD:NOT_FACTORY");
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        MockGlobals(globals).setValidInstance("LIQUIDATOR_FACTORY", address(liquidatorFactory), true);

        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));
    }

    function test_triggerDefault_success_asPoolDelegate() external {
        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));
    }

    function test_triggerDefault_success_asGovernor() external {
        vm.prank(GOVERNOR);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));
    }

    function test_triggerDefault_success_asOperationalAdmin() external {
        MockGlobals(globals).__setOperationalAdmin(OPERATIONAL_ADMIN);

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));
    }

}

contract FinishCollateralLiquidation is PoolManagerTestBase {

    address internal BORROWER          = makeAddr("BORROWER");
    address internal LOAN              = makeAddr("LOAN");
    address internal LP                = makeAddr("LP");
    address internal OPERATIONAL_ADMIN = makeAddr("OPERATIONAL_ADMIN");

    address internal loan;
    address internal poolDelegateCover;

    MockLoanManager loanManager;

    function setUp() public override {
        super.setUp();

        loanManager = new MockLoanManager(address(pool), TREASURY, POOL_DELEGATE);

        poolDelegateCover = poolManager.poolDelegateCover();

        _bootstrapGlobals(address(asset), POOL_DELEGATE);

        MockLoanFactory loanFactory = new MockLoanFactory();

        MockFactory loanManagerFactory = new MockFactory();

        loanManager.__setFactory(address(loanManagerFactory));

        MockGlobals(globals).setValidInstance("LOAN_MANAGER_FACTORY",       address(loanManagerFactory),       true);
        MockGlobals(globals).setValidInstance("LOAN",                       address(loanFactory),              true);
        MockGlobals(globals).setValidInstance("LIQUIDATOR_FACTORY",         address(liquidatorFactory),        true);
        MockGlobals(globals).setValidInstance("WITHDRAWAL_MANAGER_FACTORY", address(withdrawalManagerFactory), true);

        loan = address(new MockLoan(address(asset), address(asset)));
        MockLoan(loan).__setBorrower(BORROWER);
        MockLoan(loan).__setFactory(address(loanFactory));
        MockLoan(loan).__setLender(address(loanManager));
        MockLoan(loan).__setPaymentsRemaining(3);
        MockGlobals(globals).setValidBorrower(BORROWER, true);

        loanFactory.__setIsLoan(loan, true);

        vm.startPrank(POOL_DELEGATE);
        poolManager.__setIsLoanManager(address(loanManager), true);
        poolManager.__pushToLoanManagerList(address(loanManager));
        poolManager.setWithdrawalManager(withdrawalManager);
        vm.stopPrank();
    }

    function test_finishCollateralLiquidation_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.expectRevert("PM:PAUSED");
        poolManager.finishCollateralLiquidation(loan);
    }

    function test_finishCollateralLiquidation_notAuthorized() external {
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), poolManager.HUNDRED_PERCENT());

        loanManager.__setTriggerDefaultReturn(2_000e18);

        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18, 0);

        vm.expectRevert("PM:NOT_PD_OR_GOV_OR_OA");
        poolManager.finishCollateralLiquidation(loan);
    }

    function test_finishCollateralLiquidation_success_noCover_asPoolDelegate() external {
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), poolManager.HUNDRED_PERCENT());

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
        assertEq(poolManager.unrealizedLosses(),                0);

        loanManager.__setTriggerDefaultReturn(2_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn({ remainingLosses_: 1_000e18, serviceFee_: 100e18 });

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
        assertEq(MockERC20(asset).balanceOf(TREASURY),          0);  // No cover, no fees paid to treasury.
    }

    function test_finishCollateralLiquidation_success_noCover_asGovernor() external {
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), poolManager.HUNDRED_PERCENT());

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
        assertEq(poolManager.unrealizedLosses(),                0);

        loanManager.__setTriggerDefaultReturn(2_000e18);
        vm.prank(GOVERNOR);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn({ remainingLosses_: 1_000e18, serviceFee_: 100e18 });

        vm.prank(GOVERNOR);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
        assertEq(MockERC20(asset).balanceOf(TREASURY),          0);  // No cover, no fees paid to treasury.
    }

    function test_finishCollateralLiquidation_success_noCover_asOperationalAdmin() external {
        MockGlobals(globals).__setOperationalAdmin(OPERATIONAL_ADMIN);

        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), poolManager.HUNDRED_PERCENT());

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
        assertEq(poolManager.unrealizedLosses(),                0);

        loanManager.__setTriggerDefaultReturn(2_000e18);
        vm.prank(OPERATIONAL_ADMIN);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn({ remainingLosses_: 1_000e18, serviceFee_: 100e18 });

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
        assertEq(MockERC20(asset).balanceOf(TREASURY),          0);  // No cover, no fees paid to treasury.
    }

    function test_finishCollateralLiquidation_success_noRemainingLossAfterCollateralLiquidation() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1_000e18);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), poolManager.HUNDRED_PERCENT());
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);
        assertEq(poolManager.unrealizedLosses(),                0);

        loanManager.__setTriggerDefaultReturn(2_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn({ remainingLosses_: 0, serviceFee_: 0 });

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);
    }

    function test_finishCollateralLiquidation_success_coverLeftOver() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 2_000e18);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), poolManager.HUNDRED_PERCENT());
        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 2_000e18);
        assertEq(poolManager.unrealizedLosses(),                0);

        loanManager.__setTriggerDefaultReturn(3_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertEq(poolManager.unrealizedLosses(), 3_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18, 0);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);
    }

    function test_finishCollateralLiquidation_success_noCoverLeftOver() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1_000e18);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), poolManager.HUNDRED_PERCENT());
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);
        assertEq(poolManager.unrealizedLosses(),                0);

        loanManager.__setTriggerDefaultReturn(2_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18, 0);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
    }

    function test_finishCollateralLiquidation_success_fullCoverLiquidation_preexistingLoss() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1_000e18);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), poolManager.HUNDRED_PERCENT());
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        // There could be unrealizedLosses from a previous ongoing loan default.
        loanManager.__setUnrealizedLosses(2_000e18);

        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 1_000e18);
        assertEq(poolManager.unrealizedLosses(),                2_000e18);

        loanManager.__setTriggerDefaultReturn(3_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertEq(poolManager.unrealizedLosses(), 5_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18, 0);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                2_000e18);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 0);
    }

    function test_finishCollateralLiquidation_success_exceedMaxCoverLiquidationPercentAmount() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1_000e18);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), 50_0000);
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        assertEq(poolManager.unrealizedLosses(), 0);

        loanManager.__setTriggerDefaultReturn(3_000e18);
        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertEq(poolManager.unrealizedLosses(), 3_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18, 0);

        vm.prank(POOL_DELEGATE);
        poolManager.finishCollateralLiquidation(loan);

        assertEq(poolManager.unrealizedLosses(),                0);
        assertEq(MockERC20(asset).balanceOf(poolDelegateCover), 500e18);
    }

}

contract ProcessRedeemTests is PoolManagerTestBase {

    function setUp() public override {
        super.setUp();

        vm.prank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(withdrawalManager);
    }

    function test_processRedeem_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);
        vm.expectRevert("PM:PAUSED");
        poolManager.processRedeem(1, address(1), address(1));
    }

    function test_processRedeem_notWithdrawalManager() external {
        vm.expectRevert("PM:NOT_POOL");
        poolManager.processRedeem(1, address(1), address(1));
    }

    function test_processRedeem_noApproval() external {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        vm.prank(poolManager.pool());
        vm.expectRevert("PM:PR:NO_ALLOWANCE");
        poolManager.processRedeem(1, user1, user2);
    }

    function test_processRedeem_success() external {
        vm.prank(poolManager.pool());
        poolManager.processRedeem(1, address(1), address(1));
    }

    function test_processRedeem_success_notSender() external {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        vm.prank(user1);
        pool.approve(user2, 1);

        vm.prank(poolManager.pool());
        poolManager.processRedeem(1, user1, user2);
    }

}

contract AddLoanManager_SetterTests is PoolManagerTestBase {

    address loanManagerFactory;

    function setUp() public override {
        super.setUp();

        loanManagerFactory = address(new MockFactory());

        MockGlobals(globals).setValidInstance("LOAN_MANAGER_FACTORY", loanManagerFactory, true);
    }

    function test_addLoanManager_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PAUSED");
        poolManager.addLoanManager(address(0));
    }

    function test_addLoanManager_notPoolDelegate() external {
        poolManager.__setConfigured(true);

        vm.expectRevert("PM:NO_AUTH");
        poolManager.addLoanManager(address(0));
    }

    function test_addLoanManager_invalidFactory() external {
        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:ALM:INVALID_FACTORY");
        poolManager.addLoanManager(address(0));
    }

    function test_addLoanManager_success_whenNotConfigured() external {
        address loanManager_ = poolManager.addLoanManager(loanManagerFactory);

        assertTrue(loanManager_ == poolManager.__getLoanManagerListValue(0));
        assertTrue(poolManager.__getLoanManagerListValue(0) != address(0));

        assertEq(poolManager.loanManagerListLength(), 1);
    }

    function test_addLoanManager_success_asPoolDelegate() external {
        poolManager.__setConfigured(true);

        vm.startPrank(POOL_DELEGATE);
        address loanManager_ = poolManager.addLoanManager(loanManagerFactory);

        assertTrue(loanManager_ == poolManager.__getLoanManagerListValue(0));
        assertTrue(poolManager.__getLoanManagerListValue(0) != address(0));

        assertEq(poolManager.loanManagerListLength(), 1);
    }

}

contract SetWithdrawalManager_SetterTests is PoolManagerTestBase {

    function test_setWithdrawalManager_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PAUSED");
        poolManager.setWithdrawalManager(withdrawalManager);
    }

    function test_setWithdrawalManager_configured() external {
        poolManager.__setConfigured(true);

        vm.expectRevert("PM:ALREADY_CONFIGURED");
        poolManager.setWithdrawalManager(withdrawalManager);
    }

    function test_setWithdrawalManager_invalidFactory() external {
        MockGlobals(globals).setValidInstance("WITHDRAWAL_MANAGER_FACTORY", address(withdrawalManagerFactory), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SWM:INVALID_FACTORY");
        poolManager.setWithdrawalManager(withdrawalManager);
    }

    function test_setWithdrawalManager_invalidInstance() external {
        withdrawalManagerFactory.__setIsInstance(address(withdrawalManager), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SWM:INVALID_INSTANCE");
        poolManager.setWithdrawalManager(withdrawalManager);
    }

    function test_setWithdrawalManager_success_asPoolDelegate() external {
        poolManager.__setConfigured(false);
        poolManager.setWithdrawalManager(withdrawalManager);

        assertEq(poolManager.withdrawalManager(), withdrawalManager);
    }

}

contract CanCallTests is PoolManagerTestBase {

    function test_canCall_deposit_notActive() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.prank(globals);
        poolManager.setActive(false);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:NOT_ACTIVE");
    }

    function test_canCall_deposit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        mockPoolPermissionManager.__setAllowed(false);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:NOT_ALLOWED");

        mockPoolPermissionManager.__setAllowed(true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_deposit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_depositWithPermit_notActive() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.prank(globals);
        poolManager.setActive(false);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:NOT_ACTIVE");
    }

    function test_canCall_depositWithPermit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        mockPoolPermissionManager.__setAllowed(false);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:NOT_ALLOWED");

        mockPoolPermissionManager.__setAllowed(true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_depositWithPermit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1_000e6);

        bytes memory params = abi.encode(1_000e6 + 1, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_mint_notActive() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.prank(globals);
        poolManager.setActive(false);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:NOT_ACTIVE");
    }

    function test_canCall_mint_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        mockPoolPermissionManager.__setAllowed(false);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:NOT_ALLOWED");

        mockPoolPermissionManager.__setAllowed(true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mint_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1_000e6);

        bytes memory params = abi.encode(1_000e6 + 1, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_mintWithPermit_notActive() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.prank(globals);
        poolManager.setActive(false);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:NOT_ACTIVE");
    }

    function test_canCall_mintWithPermit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        mockPoolPermissionManager.__setAllowed(false);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:NOT_ALLOWED");

        mockPoolPermissionManager.__setAllowed(true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mintWithPermit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1_000e6);

        bytes memory params = abi.encode(1_000e6 + 1, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_redeem() external {
        bytes32 functionId_ = bytes32("P:redeem");

        bytes memory params = abi.encode(1_000e6, address(this), address(this));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(pool), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_removeShares() external {
        bytes32 functionId_ = bytes32("P:removeShares");

        bytes memory params = abi.encode(1_000e6, address(1));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(pool), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_requestRedeem() external {
        bytes32 functionId_ = bytes32("P:requestRedeem");

        bytes memory params = abi.encode(1_000e6, address(1));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(pool), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_requestWithdraw() external {
        bytes32 functionId_ = bytes32("P:requestWithdraw");

        bytes memory params = abi.encode(1_000e6, address(1));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(pool), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transfer_recipientNotAllowed() external {
        bytes32 functionId_ = bytes32("P:transfer");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        mockPoolPermissionManager.__setAllowed(false);

        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:NOT_ALLOWED");

        mockPoolPermissionManager.__setAllowed(true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transferFrom_recipientNotAllowed() external {
        bytes32 functionId_ = bytes32("P:transferFrom");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        mockPoolPermissionManager.__setAllowed(false);

        bytes memory params = abi.encode(address(1), recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:NOT_ALLOWED");

        mockPoolPermissionManager.__setAllowed(true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_withdraw() external {
        bytes32 functionId_ = bytes32("P:withdraw");

        bytes memory params = abi.encode(1_000e6, address(1), address(2));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(pool), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_paused_transfer() external {
        bytes32 functionId_ = bytes32("P:transfer");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).__setFunctionPaused(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PAUSED");
    }

    function test_canCall_paused_redeem() external {
        bytes32 functionId_ = bytes32("P:redeem");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).__setFunctionPaused(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PAUSED");
    }

    function test_canCall_paused_withdraw() external {
        bytes32 functionId_ = bytes32("P:withdraw");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).__setFunctionPaused(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PAUSED");
    }

    function test_canCall_paused_removeShares() external {
        bytes32 functionId_ = bytes32("P:removeShares");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).__setFunctionPaused(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PAUSED");
    }

    function test_canCall_paused_requestRedeem() external {
        bytes32 functionId_ = bytes32("P:requestRedeem");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).__setFunctionPaused(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PAUSED");
    }

    function test_canCall_paused_requestWithdraw() external {
        bytes32 functionId_ = bytes32("P:requestWithdraw");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).__setFunctionPaused(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PAUSED");
    }

    function test_canCall_invalidFunctionId() external {
        address caller     = makeAddr("caller");
        bytes32 functionId = bytes32("Fake Function");

        bytes memory data = abi.encode(caller, caller);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId, caller, data);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:INVALID_FUNCTION_ID");
    }

}

contract DepositCoverTests is PoolManagerTestBase {

    function setUp() public override {
        super.setUp();

        asset.mint(POOL_DELEGATE, 1_000e18);
    }

    function test_depositCover_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.expectRevert("PM:PAUSED");
        poolManager.depositCover(1_000e18);
    }

    function test_depositCover_insufficientApproval() external {
        vm.startPrank(POOL_DELEGATE);
        asset.approve(address(poolManager), 1_000e18 - 1);

        vm.expectRevert("PM:DC:TRANSFER_FAIL");
        poolManager.depositCover(1_000e18);

        asset.approve(address(poolManager), 1_000e18);
        poolManager.depositCover(1_000e18);
    }

    function test_depositCover_success() external {
        assertEq(asset.balanceOf(POOL_DELEGATE),                       1_000e18);
        assertEq(asset.balanceOf(poolManager.poolDelegateCover()),     0);
        assertEq(asset.allowance(POOL_DELEGATE, address(poolManager)), 0);

        vm.startPrank(POOL_DELEGATE);

        asset.approve(address(poolManager), 1_000e18);

        assertEq(asset.allowance(POOL_DELEGATE, address(poolManager)), 1_000e18);

        poolManager.depositCover(1_000e18);
        assertEq(asset.balanceOf(POOL_DELEGATE),                       0);
        assertEq(asset.balanceOf(poolManager.poolDelegateCover()),     1_000e18);
        assertEq(asset.allowance(POOL_DELEGATE, address(poolManager)), 0);
    }

}

contract HandleCoverTests is PoolManagerTestBase {

    address loanManager;

    function setUp() public override {
        super.setUp();

        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), 1e6);

        loanManager = makeAddr("loanManager");

        poolManager.__setIsLoanManager(loanManager, true);
        poolManager.__pushToLoanManagerList(loanManager);
    }

    function test_handleCover_noCover() external {
        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 0);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18);
        assertEq(asset.balanceOf(TREASURY),                        0);

        vm.prank(loanManager);
        poolManager.__handleCover(5_000e18, 1_000e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 0);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18);
        assertEq(asset.balanceOf(TREASURY),                        0);
    }

    function test_handleCover_onlyFees() external {
        asset.mint(poolManager.poolDelegateCover(), 800e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 800e18);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18);
        assertEq(asset.balanceOf(TREASURY),                        0);

        vm.prank(loanManager);
        poolManager.__handleCover(5_000e18, 1_000e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 0);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18);
        assertEq(asset.balanceOf(TREASURY),                        800e18);
    }

    function test_handleCover_feesAndSomeLosses() external {
        asset.mint(poolManager.poolDelegateCover(), 1_800e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 1_800e18);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18);
        assertEq(asset.balanceOf(TREASURY),                        0);

        vm.prank(loanManager);
        poolManager.__handleCover(5_000e18, 1_000e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 0);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18 + 800e18);
        assertEq(asset.balanceOf(TREASURY),                        1_000e18);
    }

    function test_handleCover_fullCoverage() external {
        asset.mint(poolManager.poolDelegateCover(), 6_100e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 6_100e18);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18);
        assertEq(asset.balanceOf(TREASURY),                        0);

        vm.prank(loanManager);
        poolManager.__handleCover(5_000e18, 1_000e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 100e18);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18 + 5_000e18);
        assertEq(asset.balanceOf(TREASURY),                        1_000e18);
    }

    function test_handleCover_halfCoverage() external {
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), 0.5e6);

        asset.mint(poolManager.poolDelegateCover(), 6_100e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 6_100e18);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18);
        assertEq(asset.balanceOf(TREASURY),                        0);

        vm.prank(loanManager);
        poolManager.__handleCover(5_000e18, 1_000e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 6_100e18 / 2);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18 + 2_050e18);
        assertEq(asset.balanceOf(TREASURY),                        1_000e18);
    }

}

contract WithdrawCoverTests is PoolManagerTestBase {

    function test_withdrawCover_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PAUSED");
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);
    }

    function test_withdrawCover_notPoolDelegate() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1_000e18);

        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        vm.expectRevert("PM:NOT_PD");
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);

        vm.prank(POOL_DELEGATE);
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);
    }

    function test_withdrawCover_tryWithdrawBelowRequired() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1_000e18);

        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:WC:BELOW_MIN");
        poolManager.withdrawCover(1_000e18 + 1, POOL_DELEGATE);

        vm.prank(POOL_DELEGATE);
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);
    }

    function test_withdrawCover_noRequirement() external {
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        // Withdraw all cover, for example in the scenario that a pool closes.
        vm.prank(POOL_DELEGATE);
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);
    }

    function test_withdrawCover_withdrawMoreThanBalance() external {
        asset.mint(poolManager.poolDelegateCover(), 1_000e18);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PDC:MF:TRANSFER_FAILED");
        poolManager.withdrawCover(1_000e18 + 1, POOL_DELEGATE);
    }

    function test_withdrawCover_success() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1_000e18);

        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 2_000e18);
        assertEq(asset.balanceOf(POOL_DELEGATE),                   0);

        vm.prank(POOL_DELEGATE);
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 1_000e18);
        assertEq(asset.balanceOf(POOL_DELEGATE),                   1_000e18);
    }

    function test_withdrawCover_success_zeroRecipient() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1_000e18);

        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 2_000e18);
        assertEq(asset.balanceOf(POOL_DELEGATE),                   0);

        vm.prank(POOL_DELEGATE);
        poolManager.withdrawCover(1_000e18, address(0));

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 1_000e18);
        assertEq(asset.balanceOf(POOL_DELEGATE),                   1_000e18);
    }

}

contract MaxDepositTests is PoolManagerTestBase {

    function setUp() public override {
        super.setUp();

        asset.burn(address(pool), 1_000_000e18);
    }

    function test_maxDeposit_withPermission() external {
        address lp = makeAddr("lp");

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(1);

        assertEq(poolManager.maxDeposit(lp), 1);

        mockPoolPermissionManager.__setAllowed(false);

        assertEq(poolManager.maxDeposit(lp), 0);
    }

    function test_maxDeposit_withoutPermission() external {
        address lp = makeAddr("lp");

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1);

        assertEq(poolManager.maxDeposit(lp), 1);
    }

    function test_maxDeposit_liquidityCap() external {
        address lp1 = makeAddr("lp1");
        address lp2 = makeAddr("lp2");

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(1);

        asset.mint(address(pool), 1);  // Set totalAssets to 1

        assertEq(poolManager.maxDeposit(lp1), 0);
        assertEq(poolManager.maxDeposit(lp2), 0);

        poolManager.setLiquidityCap(2);

        assertEq(poolManager.maxDeposit(lp1), 1);
        assertEq(poolManager.maxDeposit(lp2), 1);

        poolManager.setLiquidityCap(100);

        assertEq(poolManager.maxDeposit(lp1), 99);
        assertEq(poolManager.maxDeposit(lp2), 99);

        asset.mint(address(pool), 100);  // Set totalAssets to 101, higher than liquidity cap

        assertEq(poolManager.maxDeposit(lp1), 0);
        assertEq(poolManager.maxDeposit(lp2), 0);
    }

    function test_maxDeposit_liquidityCap(address lp1, address lp2, uint256 liquidityCap, uint256 totalAssets) external {
        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(liquidityCap);

        asset.mint(address(pool), totalAssets);

        uint256 expectedMaxDeposit = totalAssets > liquidityCap ? 0 : liquidityCap - totalAssets;

        assertEq(poolManager.maxDeposit(lp1), expectedMaxDeposit);
        assertEq(poolManager.maxDeposit(lp2), expectedMaxDeposit);
    }

}

contract MaxMintTests is PoolManagerTestBase {

    function setUp() public override {
        super.setUp();

        asset.burn(address(pool), 1_000_000e18);
        pool.burn(address(1), 1);  // Revert setup mint
    }

    function _doInitialDeposit() internal {
        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(100);

        // Set a non-zero totalAssets and totalSupply at 1:1
        asset.mint(address(this), 100);
        asset.approve(address(pool), 100);
        pool.deposit(100, address(this));

        mockPoolPermissionManager.__setAllowed(false);
    }

    function test_maxMint_withPermission() external {
        _doInitialDeposit();

        address lp = makeAddr("lp");

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(101);

        assertEq(poolManager.maxMint(lp), 0);

        mockPoolPermissionManager.__setAllowed(true);

        assertEq(poolManager.maxMint(lp), 1);

        mockPoolPermissionManager.__setAllowed(false);

        assertEq(poolManager.maxMint(lp), 0);
    }

    function test_maxMint_withoutPermission() external {
        _doInitialDeposit();

        address lp = makeAddr("lp");

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(101);

        assertEq(poolManager.maxMint(lp), 0);

        mockPoolPermissionManager.__setAllowed(true);

        assertEq(poolManager.maxMint(lp), 1);
    }

    function test_maxMint_liquidityCap_exchangeRateOneToOne() external {
        _doInitialDeposit();

        address lp1 = makeAddr("lp1");
        address lp2 = makeAddr("lp2");

        mockPoolPermissionManager.__setAllowed(true);

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(100);

        assertEq(poolManager.maxMint(lp1), 0);
        assertEq(poolManager.maxMint(lp2), 0);

        poolManager.setLiquidityCap(101);

        assertEq(poolManager.maxMint(lp1), 1);
        assertEq(poolManager.maxMint(lp2), 1);

        poolManager.setLiquidityCap(200);

        assertEq(poolManager.maxMint(lp1), 100);
        assertEq(poolManager.maxMint(lp2), 100);

        poolManager.setLiquidityCap(99);  // Set totalAssets to 99, lower than totalAssets

        assertEq(poolManager.maxMint(lp1), 0);
        assertEq(poolManager.maxMint(lp2), 0);
    }

    function test_maxMint_liquidityCap_exchangeRateGtOne() external {
        _doInitialDeposit();

        address lp1 = makeAddr("lp1");
        address lp2 = makeAddr("lp2");

        mockPoolPermissionManager.__setAllowed(true);

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(200);

        assertEq(poolManager.maxMint(lp1), 100);
        assertEq(poolManager.maxMint(lp2), 100);

        asset.mint(address(pool), 100);  // Set totalAssets to 200 so 2:1

        assertEq(poolManager.maxMint(lp1), 0);
        assertEq(poolManager.maxMint(lp2), 0);

        poolManager.setLiquidityCap(300);

        assertEq(poolManager.maxMint(lp1), 50);
        assertEq(poolManager.maxMint(lp2), 50);
    }

    function testFuzz_maxMint_liquidityCap(address lp1, address lp2, uint256 liquidityCap, uint256 initialDeposit, uint256 totalAssets) external {
        liquidityCap   = bound(liquidityCap,   1,              1e29);
        initialDeposit = bound(initialDeposit, 1,              liquidityCap);
        totalAssets    = bound(totalAssets,    initialDeposit, 1e29);

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(liquidityCap);

        vm.stopPrank();

        // Set a non-zero totalAssets and totalSupply at 1:1

        asset.mint(address(this), initialDeposit);
        asset.approve(address(pool), initialDeposit);
        pool.deposit(initialDeposit, address(this));

        asset.mint(address(pool), totalAssets - initialDeposit);  // Account for initial deposit

        uint256 expectedMaxDeposit = totalAssets > liquidityCap ? 0 : liquidityCap - totalAssets;

        uint256 maxMint = expectedMaxDeposit * initialDeposit / totalAssets;

        assertEq(poolManager.maxMint(lp1), maxMint);
        assertEq(poolManager.maxMint(lp2), maxMint);
    }

}

contract MaxWithdrawTests is PoolManagerTestBase {

    function test_maxWithdraw() external {
        uint256 assets_ = pool.maxWithdraw(address(this));

        assertEq(assets_, 0);
    }

    function testFuzz_maxWithdraw(address user_) external {
        uint256 assets_ = pool.maxWithdraw(user_);

        assertEq(assets_, 0);
    }

}

contract RequestFundsTests is PoolManagerTestBase {

    address loanManager;
    address loanManagerFactory;

    function setUp() public override {
        super.setUp();

        loanManager        = address(new MockLoanManager(address(pool), address(0), POOL_DELEGATE));
        loanManagerFactory = address(new MockFactory());

        MockGlobals(globals).setValidInstance("LOAN_MANAGER_FACTORY",       loanManagerFactory,                true);
        MockGlobals(globals).setValidInstance("WITHDRAWAL_MANAGER_FACTORY", address(withdrawalManagerFactory), true);

        MockLoanManager(loanManager).__setFactory(loanManagerFactory);

        poolManager.__setIsLoanManager(loanManager, true);

        MockFactory(loanManagerFactory).__setIsInstance(address(loanManager), true);

        vm.prank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(withdrawalManager);
    }

    function test_requestFunds_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.expectRevert("PM:PAUSED");
        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_zeroPrincipal() external {
        vm.expectRevert("PM:RF:INVALID_PRINCIPAL");
        vm.prank(loanManager);
        poolManager.requestFunds(loanManager, 0);
    }

    function test_requestFunds_invalidFactory() external {
        MockLoanManager(loanManager).__setFactory(address(0));

        vm.expectRevert("PM:RF:INVALID_FACTORY");
        vm.prank(loanManager);
        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_invalidInstance() external {
        MockFactory(loanManagerFactory).__setIsInstance(address(loanManager), false);

        vm.expectRevert("PM:RF:INVALID_INSTANCE");
        vm.prank(loanManager);
        poolManager.requestFunds(address(loanManager), 1);
    }

    function test_requestFunds_notLM() external {
        poolManager.__setIsLoanManager(loanManager, false);

        vm.expectRevert("PM:RF:NOT_LM");
        vm.prank(loanManager);
        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_zeroSupply() external {
        pool.burn(address(1), 1);

        vm.expectRevert("PM:RF:ZERO_SUPPLY");
        vm.prank(loanManager);
        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_insufficientCoverBoundary() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1000e18);

        asset.mint(poolManager.poolDelegateCover(), 1000e18 - 1);

        vm.expectRevert("PM:RF:INSUFFICIENT_COVER");
        vm.startPrank(loanManager);
        poolManager.requestFunds(loanManager, 1);

        asset.mint(poolManager.poolDelegateCover(), 1);

        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_lockedLiquidityBoundary() external {
        MockWithdrawalManager(withdrawalManager).__setLockedLiquidity(1_000_000e18);

        vm.expectRevert("PM:RF:LOCKED_LIQUIDITY");
        vm.startPrank(loanManager);
        poolManager.requestFunds(loanManager, 1);

        asset.mint(poolManager.pool(), 1);

        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_zeroAddress() external {
        vm.expectRevert("PM:RF:INVALID_DESTINATION");
        vm.prank(loanManager);
        poolManager.requestFunds(address(0), 1000e18);
    }

    function test_requestFunds_success() external {
        assertEq(asset.balanceOf(address(pool)), 1_000_000e18);
        assertEq(asset.balanceOf(loanManager),   0);

        vm.prank(loanManager);
        poolManager.requestFunds(loanManager, 1000e18);

        assertEq(asset.balanceOf(address(pool)), 1_000_000e18 - 1000e18);
        assertEq(asset.balanceOf(loanManager),   1000e18);
    }

}
