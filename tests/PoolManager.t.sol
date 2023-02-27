// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolManager }            from "../contracts/PoolManager.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import {
    MockERC20Pool,
    MockFactory,
    MockLoanFactory,
    MockGlobals,
    MockLoan,
    MockLoanManager,
    MockOpenTermLoanManager,
    MockPoolManagerMigrator,
    MockPoolManagerMigratorInvalidPoolDelegateCover,
    MockWithdrawalManager
} from "./mocks/Mocks.sol";

import { PoolManagerHarness } from "./harnesses/PoolManagerHarness.sol";

import { GlobalsBootstrapper } from "./bootstrap/GlobalsBootstrapper.sol";

contract PoolManagerBase is TestUtils, GlobalsBootstrapper {

    address internal POOL_DELEGATE = address(new Address());

    MockERC20     internal asset;
    MockERC20Pool internal pool;
    MockFactory   internal liquidatorFactory;

    PoolManagerHarness internal poolManager;
    PoolManagerFactory internal factory;

    address internal implementation;
    address internal initializer;
    address internal withdrawalManager;

    function setUp() public virtual {
        asset = new MockERC20("Asset", "AT", 18);

        _deployAndBootstrapGlobals(address(asset), POOL_DELEGATE);

        factory = new PoolManagerFactory(address(globals));

        implementation = address(new PoolManagerHarness());
        initializer    = address(new PoolManagerInitializer());

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "POOL1";

        MockGlobals(globals).setValidPoolDeployer(address(this), true);

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(
            POOL_DELEGATE,
            address(asset),
            0,
            poolName_,
            poolSymbol_
        );

        poolManager = PoolManagerHarness(PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(POOL_DELEGATE))));

        withdrawalManager = address(new MockWithdrawalManager());

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

contract ConfigureTests is PoolManagerBase {

    address internal loanManager = address(new Address());

    uint256 internal liquidityCap      = 1_000_000e18;
    uint256 internal managementFeeRate = 0.1e6;

    function test_configure_notDeployer() public {
        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:CO:NOT_DEPLOYER");
        poolManager.configure(loanManager, withdrawalManager, liquidityCap, managementFeeRate);

        poolManager.configure(loanManager, withdrawalManager, liquidityCap, managementFeeRate);
    }

    function test_configure_delegateManagementFeeOOB() public {
        vm.expectRevert("PM:CO:OOB");
        poolManager.configure(loanManager, withdrawalManager, liquidityCap, 100_0001);

        poolManager.configure(loanManager, withdrawalManager, liquidityCap, 100_0000);
    }

    function test_configure_alreadyConfigured() public {
        poolManager.__setConfigured(true);

        vm.expectRevert("PM:CO:ALREADY_CONFIGURED");
        poolManager.configure(loanManager, withdrawalManager, liquidityCap, managementFeeRate);

        poolManager.__setConfigured(false);
        poolManager.configure(loanManager, withdrawalManager, liquidityCap, managementFeeRate);
    }

    function test_configure_success() public {
        assertTrue(!poolManager.configured());
        assertTrue(!poolManager.isLoanManager(loanManager));

        assertEq(poolManager.withdrawalManager(),         address(0));
        assertEq(poolManager.liquidityCap(),              uint256(0));
        assertEq(poolManager.delegateManagementFeeRate(), uint256(0));

        poolManager.configure(loanManager, withdrawalManager, liquidityCap, managementFeeRate);

        assertTrue(poolManager.configured());
        assertTrue(poolManager.isLoanManager(loanManager));

        assertEq(poolManager.withdrawalManager(),         withdrawalManager);
        assertEq(poolManager.liquidityCap(),              liquidityCap);
        assertEq(poolManager.delegateManagementFeeRate(), managementFeeRate);
        assertEq(poolManager.loanManagerList(0),          loanManager);
    }

}

contract MigrateTests is PoolManagerBase {

    address internal invalidMigrator = address(new MockPoolManagerMigratorInvalidPoolDelegateCover());
    address internal migrator        = address(new MockPoolManagerMigrator());

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

contract SetImplementationTests is PoolManagerBase {

    address internal newImplementation = address(new PoolManager());

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

contract UpgradeTests is PoolManagerBase {

    address internal newImplementation = address(new PoolManager());

    function setUp() public override {
        super.setUp();

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(2, newImplementation, address(0));
        factory.enableUpgradePath(1, 2, address(0));
        vm.stopPrank();
    }

    function test_upgrade_notPoolDelegate() external {
        vm.expectRevert("PM:U:NOT_AUTHORIZED");
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

    function test_upgrade_successWithGovernor() external {
        assertEq(poolManager.implementation(), implementation);

        // No need to schedule call
        vm.prank(GOVERNOR);
        poolManager.upgrade(2, "");

        assertEq(poolManager.implementation(), newImplementation);
    }

    function test_upgrade_success() external {
        assertEq(poolManager.implementation(), implementation);

        MockGlobals(globals).__setIsValidScheduledCall(true);
        vm.prank(POOL_DELEGATE);
        poolManager.upgrade(2, "");

        assertEq(poolManager.implementation(), newImplementation);
    }

}

contract AcceptPendingPoolDelegate_SetterTests is PoolManagerBase {

    address internal NOT_POOL_DELEGATE = address(new Address());
    address internal SET_ADDRESS       = address(new Address());

    function setUp() public override {
        super.setUp();
        vm.prank(POOL_DELEGATE);
        poolManager.setPendingPoolDelegate(SET_ADDRESS);
    }

    function test_acceptPendingPoolDelegate_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(SET_ADDRESS);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.acceptPendingPoolDelegate();
    }

    function test_acceptPendingPoolDelegate_notPendingPoolDelegate() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:APPD:NOT_PENDING_PD");
        poolManager.acceptPendingPoolDelegate();
    }

    function test_acceptPendingPoolDelegate_globalsTransferFails() external {
        MockGlobals(globals).__setFailTransferOwnedPoolManager(true);
        vm.prank(SET_ADDRESS);
        vm.expectRevert("MG:TOPM:FAILED");
        poolManager.acceptPendingPoolDelegate();
    }

    function test_acceptPendingPoolDelegate_success() external {
        MockGlobals(globals).__setFailTransferOwnedPoolManager(false);

        assertEq(poolManager.pendingPoolDelegate(), SET_ADDRESS);
        assertEq(poolManager.poolDelegate(),        POOL_DELEGATE);

        vm.prank(SET_ADDRESS);
        poolManager.acceptPendingPoolDelegate();

        assertEq(poolManager.pendingPoolDelegate(), address(0));
        assertEq(poolManager.poolDelegate(),        SET_ADDRESS);
    }

}

contract SetPendingPoolDelegate_SetterTests is PoolManagerBase {

    address internal NOT_POOL_DELEGATE = address(new Address());
    address internal SET_ADDRESS       = address(new Address());

    function test_setPendingPoolDelegate_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setPendingPoolDelegate(SET_ADDRESS);
    }

    function test_setPendingPoolDelegate_notPoolDelegate() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SPA:NOT_PD");
        poolManager.setPendingPoolDelegate(SET_ADDRESS);
    }

    function test_setPendingPoolDelegate_success() external {
        assertEq(poolManager.pendingPoolDelegate(), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setPendingPoolDelegate(SET_ADDRESS);

        assertEq(poolManager.pendingPoolDelegate(), SET_ADDRESS);
    }

}

contract SetActive_SetterTests is PoolManagerBase {

    function setUp() public override {
        super.setUp();
        vm.prank(globals);
        poolManager.setActive(false);
    }

    function test_setActive_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(address(globals));
        vm.expectRevert("PM:PROTOCOL_PAUSED");
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

contract SetAllowedLender_SetterTests is PoolManagerBase {

    function test_setAllowedLender_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(address(globals));
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setAllowedLender(address(this), true);
    }

    function test_setAllowedLender_notPoolDelegate() external {
        vm.expectRevert("PM:SAL:NOT_PD");
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

contract SetAllowedSlippage_SetterTests is PoolManagerBase {

    MockLoanManager internal loanManager;

    address internal collateralAsset = address(new Address());

    function setUp() public override {
        super.setUp();

        loanManager = new MockLoanManager(address(pool), address(0), POOL_DELEGATE);

        vm.prank(POOL_DELEGATE);
        poolManager.__setIsLoanManager(address(loanManager), true);
        poolManager.__pushToLoanManagerList(address(loanManager));
    }

    function test_setAllowedSlippage_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(address(globals));
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setAllowedSlippage(address(loanManager), collateralAsset, 1e6);
    }

    function test_setAllowedSlippage_notAuthorized() external {
        vm.expectRevert("PM:SAS:NOT_AUTHORIZED");
        poolManager.setAllowedSlippage(address(loanManager), collateralAsset, 1e6);
    }

    function test_setAllowedSlippage_invalidLoanManager() external {
        address fakeLoanManager = address(new Address());

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SAS:NOT_LM");
        poolManager.setAllowedSlippage(address(fakeLoanManager), collateralAsset, 1e6);
    }

    function test_setAllowedSlippage_success_asPoolDelegate() external {
        assertEq(loanManager.allowedSlippageFor(address(collateralAsset)), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedSlippage(address(loanManager), collateralAsset, 1e6);

        assertEq(loanManager.allowedSlippageFor(address(collateralAsset)), 1e6);

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedSlippage(address(loanManager), collateralAsset, 0);

        assertEq(loanManager.allowedSlippageFor(address(collateralAsset)), 0);
    }

    function test_setAllowedSlippage_success_asGovernor() external {
        assertEq(loanManager.allowedSlippageFor(address(collateralAsset)), 0);

        vm.prank(GOVERNOR);
        poolManager.setAllowedSlippage(address(loanManager), collateralAsset, 1e6);

        assertEq(loanManager.allowedSlippageFor(address(collateralAsset)), 1e6);

        vm.prank(GOVERNOR);
        poolManager.setAllowedSlippage(address(loanManager), collateralAsset, 0);

        assertEq(loanManager.allowedSlippageFor(address(collateralAsset)), 0);
    }

}

contract SetLiquidityCap_SetterTests is PoolManagerBase {

    address internal NOT_POOL_DELEGATE = address(new Address());

    function test_setLiquidityCap_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setLiquidityCap(1000);
    }

    function test_setLiquidityCap_notPoolDelegate() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SLC:NOT_PD");
        poolManager.setLiquidityCap(1000);
    }

    function test_setLiquidityCap_success() external {
        assertEq(poolManager.liquidityCap(), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1000);

        assertEq(poolManager.liquidityCap(), 1000);
    }

}

contract SetDelegateManagementFeeRate_SetterTests is PoolManagerBase {

    address internal NOT_POOL_DELEGATE = address(new Address());

    uint256 internal newManagementFeeRate = 10_0000;

    function test_setDelegateManagementFeeRate_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);
    }

    function test_setDelegateManagementFeeRate_notPoolDelegate() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SDMFR:NOT_PD");
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);
    }

    function test_setDelegateManagementFeeRate_oob() external {
        vm.startPrank(POOL_DELEGATE);
        vm.expectRevert("PM:SDMFR:OOB");
        poolManager.setDelegateManagementFeeRate(100_0001);

        poolManager.setDelegateManagementFeeRate(100_0000);
    }

    function test_setDelegateManagementFeeRate_success() external {
        assertEq(poolManager.delegateManagementFeeRate(), uint256(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);

        assertEq(poolManager.delegateManagementFeeRate(), newManagementFeeRate);
    }

}

contract SetIsLoanManager_SetterTests is PoolManagerBase {

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

    function test_setIsLoanManager_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setIsLoanManager(loanManager2, false);
    }

    function test_setIsLoanManager_notPoolDelegate() external {
        vm.expectRevert("PM:SILM:NOT_PD");
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

contract SetMinRatio_SetterTests is PoolManagerBase {

    MockLoanManager internal loanManager;

    address internal collateralAsset = address(new Address());

    function setUp() public override {
        super.setUp();

        loanManager = new MockLoanManager(address(pool), address(0), POOL_DELEGATE);

        vm.prank(POOL_DELEGATE);
        poolManager.__setIsLoanManager(address(loanManager), true);
        poolManager.__pushToLoanManagerList(address(loanManager));
    }

    function test_setMinRatio_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(address(globals));
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setMinRatio(address(loanManager), collateralAsset, 1e6);
    }

    function test_setMinRatio_notAuthorized() external {
        vm.expectRevert("PM:SMR:NOT_AUTHORIZED");
        poolManager.setMinRatio(address(loanManager), collateralAsset, 1e6);
    }

    function test_setMinRatio_invalidLoanManager() external {
        address fakeLoanManager = address(new Address());

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SMR:NOT_LM");
        poolManager.setMinRatio(address(fakeLoanManager), collateralAsset, 1e6);
    }

    function test_setMinRatio_success_asPoolDelegate() external {
        assertEq(loanManager.minRatioFor(address(collateralAsset)), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setMinRatio(address(loanManager), collateralAsset, 1e6);

        assertEq(loanManager.minRatioFor(address(collateralAsset)), 1e6);

        vm.prank(POOL_DELEGATE);
        poolManager.setMinRatio(address(loanManager), collateralAsset, 0);

        assertEq(loanManager.minRatioFor(address(collateralAsset)), 0);
    }

    function test_setMinRatio_success_asGovernor() external {
        assertEq(loanManager.minRatioFor(address(collateralAsset)), 0);

        vm.prank(GOVERNOR);
        poolManager.setMinRatio(address(loanManager), collateralAsset, 1e6);

        assertEq(loanManager.minRatioFor(address(collateralAsset)), 1e6);

        vm.prank(GOVERNOR);
        poolManager.setMinRatio(address(loanManager), collateralAsset, 0);

        assertEq(loanManager.minRatioFor(address(collateralAsset)), 0);
    }

}

contract SetOpenToPublic_SetterTests is PoolManagerBase {

    function test_setOpenToPublic_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setOpenToPublic();
    }

    function test_setOpenToPublic_notPoolDelegate() external {
        vm.expectRevert("PM:SOTP:NOT_PD");
        poolManager.setOpenToPublic();
    }

    function test_setOpenToPublic_success() external {
        assertTrue(!poolManager.openToPublic());

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        assertTrue(poolManager.openToPublic());
    }
}

contract TriggerDefault is PoolManagerBase {

    address internal AUCTIONEER = address(new Address());
    address internal BORROWER   = address(new Address());
    address internal LP         = address(new Address());

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
        MockGlobals(globals).setValidFactory(bytes32("LOAN"),         address(loanFactory),        true);
        MockGlobals(globals).setValidFactory(bytes32("LIQUIDATOR"),   address(liquidatorFactory),  true);
        MockGlobals(globals).setValidFactory(bytes32("LOAN_MANAGER"), address(loanManagerFactory), true);

        loanFactory.__setIsLoan(loan, true);

        vm.startPrank(POOL_DELEGATE);
        poolManager.__setIsLoanManager(address(loanManager), true);
        poolManager.__pushToLoanManagerList(address(loanManager));
        poolManager.setWithdrawalManager(address(new MockWithdrawalManager()));
        vm.stopPrank();
    }

    function test_triggerDefault_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));
    }

    function test_triggerDefault_notAuthorized() external {
        vm.expectRevert("PM:TD:NOT_AUTHORIZED");
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));
    }

    function test_triggerDefault_invalidFactory() external {
        MockGlobals(globals).setValidFactory("LIQUIDATOR", address(liquidatorFactory), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:TD:NOT_FACTORY");
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        MockGlobals(globals).setValidFactory("LIQUIDATOR", address(liquidatorFactory), true);

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

}

contract FinishCollateralLiquidation is PoolManagerBase {

    address internal BORROWER = address(new Address());
    address internal LOAN     = address(new Address());
    address internal LP       = address(new Address());

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

        MockGlobals(globals).setValidFactory(bytes32("LOAN_MANAGER"), address(loanManagerFactory), true);
        MockGlobals(globals).setValidFactory(bytes32("LOAN"),         address(loanFactory),        true);
        MockGlobals(globals).setValidFactory(bytes32("LIQUIDATOR"),   address(liquidatorFactory),  true);

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
        poolManager.setWithdrawalManager(address(new MockWithdrawalManager()));
        vm.stopPrank();
    }

    function test_finishCollateralLiquidation_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.finishCollateralLiquidation(loan);
    }

    function test_finishCollateralLiquidation_notAuthorized() external {
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), poolManager.HUNDRED_PERCENT());

        loanManager.__setTriggerDefaultReturn(2_000e18);

        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertEq(poolManager.unrealizedLosses(), 2_000e18);

        loanManager.__setFinishCollateralLiquidationReturn(1_000e18, 0);

        vm.expectRevert("PM:FCL:NOT_AUTHORIZED");
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

contract ProcessRedeemTests is PoolManagerBase {

    function setUp() public override {
        super.setUp();

        vm.prank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(withdrawalManager);
    }

    function test_processRedeem_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.processRedeem(1, address(1), address(1));
    }

    function test_processRedeem_notWithdrawalManager() external {
        vm.expectRevert("PM:PR:NOT_POOL");
        poolManager.processRedeem(1, address(1), address(1));
    }

    function test_processRedeem_noApproval() external {
        address user1 = address(new Address());
        address user2 = address(new Address());

        vm.prank(poolManager.pool());
        vm.expectRevert("PM:PR:NO_ALLOWANCE");
        poolManager.processRedeem(1, user1, user2);
    }

    function test_processRedeem_success() external {
        vm.prank(poolManager.pool());
        poolManager.processRedeem(1, address(1), address(1));
    }

    function test_processRedeem_success_notSender() external {
        address user1 = address(new Address());
        address user2 = address(new Address());

        vm.prank(user1);
        pool.approve(user2, 1);

        vm.prank(poolManager.pool());
        poolManager.processRedeem(1, user1, user2);
    }

}

contract AddLoanManager_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());

    address loanManagerFactory;

    function setUp() public override {
        super.setUp();

        loanManagerFactory = address(new MockFactory());

        MockGlobals(globals).setValidFactory("LOAN_MANAGER", loanManagerFactory, true);
    }

    function test_addLoanManager_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.addLoanManager(loanManagerFactory, "");
    }

    function test_addLoanManager_notPD() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:ALM:NOT_PD");
        poolManager.addLoanManager(loanManagerFactory, "");
    }

    function test_addLoanManager_invalidFactory() external {
        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:ALM:INVALID_FACTORY");
        poolManager.addLoanManager(address(0), "");
    }

    function test_addLoanManager() external {
        assertEq(poolManager.__getLoanManagerListLength(), 0);
        assertEq(poolManager.__getLoanManagerListValue(0), address(0));

        vm.startPrank(POOL_DELEGATE);
        poolManager.addLoanManager(loanManagerFactory, "");

        assertEq(poolManager.__getLoanManagerListLength(), 1);
    }

}

contract SetWithdrawalManager_SetterTests is PoolManagerBase {

    address WITHDRAWAL_MANAGER = address(new Address());
    address NOT_POOL_DELEGATE  = address(new Address());

    function test_setWithdrawalManager_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);
    }

    function test_setWithdrawalManager_notPD() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SWM:NOT_PD");
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);
    }

    function test_setWithdrawalManager() external {
        assertEq(poolManager.withdrawalManager(), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);

        assertEq(poolManager.withdrawalManager(), WITHDRAWAL_MANAGER);
    }

}

contract CanCallTests is PoolManagerBase {

    function test_canCall_deposit_notActive() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.prank(globals);
        poolManager.setActive(false);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:D:NOT_ACTIVE");
    }

    function test_canCall_deposit_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:D:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_deposit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:D:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_deposit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:D:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_depositWithPermit_notActive() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.prank(globals);
        poolManager.setActive(false);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DWP:NOT_ACTIVE");
    }

    function test_canCall_depositWithPermit_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_depositWithPermit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_depositWithPermit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DWP:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_mint_notActive() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.prank(globals);
        poolManager.setActive(false);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:M:NOT_ACTIVE");
    }

    function test_canCall_mint_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:M:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mint_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:M:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mint_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:M:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_mintWithPermit_notActive() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.prank(globals);
        poolManager.setActive(false);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:MWP:NOT_ACTIVE");
    }

    function test_canCall_mintWithPermit_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:MWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mintWithPermit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:MWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mintWithPermit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:MWP:DEPOSIT_GT_LIQ_CAP");
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

        bytes memory params = abi.encode(1_000e6);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(pool), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_requestRedeem() external {
        bytes32 functionId_ = bytes32("P:requestRedeem");

        bytes memory params = abi.encode(1_000e6);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(pool), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_requestWithdraw() external {
        bytes32 functionId_ = bytes32("P:requestWithdraw");

        bytes memory params = abi.encode(1_000e6);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(pool), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transfer_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:transfer");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:T:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transfer_recipientNotAllowed() external {
        bytes32 functionId_ = bytes32("P:transfer");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:T:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(recipient_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transferFrom_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:transferFrom");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(address(1), recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:TF:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transferFrom_recipientNotAllowed() external {
        bytes32 functionId_ = bytes32("P:transferFrom");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(address(1), recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:TF:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(recipient_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_withdraw() external {
        bytes32 functionId_ = bytes32("P:withdraw");

        bytes memory params = abi.encode(1_000e6);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(pool), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_protocolPaused_transfer() external {
        bytes32 functionId_ = bytes32("P:transfer");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).setProtocolPause(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PROTOCOL_PAUSED");
    }

    function test_canCall_protocolPaused_redeem() external {
        bytes32 functionId_ = bytes32("P:redeem");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).setProtocolPause(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PROTOCOL_PAUSED");
    }

    function test_canCall_protocolPaused_withdraw() external {
        bytes32 functionId_ = bytes32("P:withdraw");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).setProtocolPause(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PROTOCOL_PAUSED");
    }

    function test_canCall_protocolPaused_removeShares() external {
        bytes32 functionId_ = bytes32("P:removeShares");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).setProtocolPause(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PROTOCOL_PAUSED");
    }

    function test_canCall_protocolPaused_requestRedeem() external {
        bytes32 functionId_ = bytes32("P:requestRedeem");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).setProtocolPause(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PROTOCOL_PAUSED");
    }

    function test_canCall_protocolPaused_requestWithdraw() external {
        bytes32 functionId_ = bytes32("P:requestWithdraw");
        address recipient_  = address(this);
        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        // Set protocol paused
        MockGlobals(globals).setProtocolPause(true);

        // Call cannot be performed
        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:PROTOCOL_PAUSED");
    }

    function test_canCall_invalidFunctionId() external {
        address caller     = address(new Address());
        bytes32 functionId = bytes32("Fake Function");

        bytes memory data = new bytes(0);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId, caller, data);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "PM:CC:INVALID_FUNCTION_ID");
    }

}

contract DepositCoverTests is PoolManagerBase {

    function setUp() public override {
        super.setUp();

        asset.mint(POOL_DELEGATE, 1_000e18);
    }

    function test_depositCover_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.expectRevert("PM:PROTOCOL_PAUSED");
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

contract HandleCoverTests is PoolManagerBase {

    address loanManager;

    function setUp() public override {
        super.setUp();

        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), 1e6);

        loanManager = address(new Address());

        poolManager.__setIsLoanManager(loanManager, true);
        poolManager.__pushToLoanManagerList(loanManager);
    }

    function test_handleCover_noCover() external {
        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 0);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18);
        assertEq(asset.balanceOf(TREASURY),                        0);

        vm.prank(loanManager);
        poolManager.handleCover(5_000e18, 1_000e18);

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
        poolManager.handleCover(5_000e18, 1_000e18);

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
        poolManager.handleCover(5_000e18, 1_000e18);

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
        poolManager.handleCover(5_000e18, 1_000e18);

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
        poolManager.handleCover(5_000e18, 1_000e18);

        assertEq(asset.balanceOf(poolManager.poolDelegateCover()), 6_100e18 / 2);
        assertEq(asset.balanceOf(address(pool)),                   1_000_000e18 + 2_050e18);
        assertEq(asset.balanceOf(TREASURY),                        1_000e18);
    }

}

contract WithdrawCoverTests is PoolManagerBase {

    function test_withdrawCover_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.withdrawCover(1_000e18, POOL_DELEGATE);
    }

    function test_withdrawCover_notPoolDelegate() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1_000e18);

        asset.mint(poolManager.poolDelegateCover(), 2_000e18);

        vm.expectRevert("PM:WC:NOT_PD");
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

contract MaxDepositTests is PoolManagerBase {

    function setUp() public override {
        super.setUp();

        asset.burn(address(pool), 1_000_000e18);
    }

    function test_maxDeposit_privatePool() external {
        address lp = address(new Address());

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(1);

        assertEq(poolManager.maxDeposit(lp), 0);

        poolManager.setAllowedLender(lp, true);

        assertEq(poolManager.maxDeposit(lp), 1);

        poolManager.setAllowedLender(lp, false);

        assertEq(poolManager.maxDeposit(lp), 0);
    }

    function test_maxDeposit_publicPool() external {
        address lp = address(new Address());

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(1);

        assertEq(poolManager.maxDeposit(lp), 0);

        poolManager.setOpenToPublic();

        assertEq(poolManager.maxDeposit(lp), 1);
    }

    function test_maxDeposit_liquidityCap() external {
        address lp1 = address(new Address());
        address lp2 = address(new Address());

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(1);
        poolManager.setOpenToPublic();

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
        poolManager.setOpenToPublic();

        asset.mint(address(pool), totalAssets);

        uint256 expectedMaxDeposit = totalAssets > liquidityCap ? 0 : liquidityCap - totalAssets;

        assertEq(poolManager.maxDeposit(lp1), expectedMaxDeposit);
        assertEq(poolManager.maxDeposit(lp2), expectedMaxDeposit);
    }

}

contract MaxMintTests is PoolManagerBase {

    function setUp() public override {
        super.setUp();

        asset.burn(address(pool), 1_000_000e18);
        pool.burn(address(1), 1);  // Revert setup mint
    }

    function _doInitialDeposit() internal {
        address lp = address(this);

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(100);
        poolManager.setAllowedLender(lp, true);

        vm.stopPrank();

        // Set a non-zero totalAssets and totalSupply at 1:1
        asset.mint(address(this), 100);
        asset.approve(address(pool), 100);
        pool.deposit(100, address(this));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(lp, false);
    }

    function test_maxMint_privatePool() external {
        _doInitialDeposit();

        address lp = address(new Address());

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(101);

        assertEq(poolManager.maxMint(lp), 0);

        poolManager.setAllowedLender(lp, true);

        assertEq(poolManager.maxMint(lp), 1);

        poolManager.setAllowedLender(lp, false);

        assertEq(poolManager.maxMint(lp), 0);
    }

    function test_maxMint_publicPool() external {
        _doInitialDeposit();

        address lp = address(new Address());

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(101);

        assertEq(poolManager.maxMint(lp), 0);

        poolManager.setOpenToPublic();

        assertEq(poolManager.maxMint(lp), 1);
    }

    function test_maxMint_liquidityCap_exchangeRateOneToOne() external {
        _doInitialDeposit();

        address lp1 = address(new Address());
        address lp2 = address(new Address());

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(100);
        poolManager.setOpenToPublic();

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

        address lp1 = address(new Address());
        address lp2 = address(new Address());

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(200);
        poolManager.setOpenToPublic();

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
        liquidityCap  = constrictToRange(liquidityCap,  1,             1e29);
        initialDeposit = constrictToRange(initialDeposit, 1,             liquidityCap);
        totalAssets   = constrictToRange(totalAssets,   initialDeposit, 1e29);

        vm.startPrank(POOL_DELEGATE);

        poolManager.setLiquidityCap(liquidityCap);
        poolManager.setOpenToPublic();

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

contract MaxWithdrawTests is PoolManagerBase {

    function test_maxWithdraw() external {
        uint256 assets_ = pool.maxWithdraw(address(this));

        assertEq(assets_, 0);
    }

    function testFuzz_maxWithdraw(address user_) external {
        uint256 assets_ = pool.maxWithdraw(user_);

        assertEq(assets_, 0);
    }

}

contract RequestFundsTests is PoolManagerBase {

    address loanManager;
    address loanManagerFactory;

    function setUp() public override {
        super.setUp();

        loanManager        = address(new MockLoanManager(address(pool), address(0), POOL_DELEGATE));
        loanManagerFactory = address(new MockFactory());

        MockGlobals(globals).setValidFactory("LOAN_MANAGER", loanManagerFactory, true);

        MockLoanManager(loanManager).__setFactory(loanManagerFactory);

        poolManager.__setIsLoanManager(loanManager, true);

        vm.prank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(withdrawalManager);
    }

    function test_requestFunds_protocolPaused() external {
        MockGlobals(globals).setProtocolPause(true);

        vm.expectRevert("PM:PROTOCOL_PAUSED");
        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_invalidFactory() external {
        MockLoanManager(loanManager).__setFactory(address(0));

        vm.prank(loanManager);
        vm.expectRevert("PM:RF:INVALID_FACTORY");
        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_notLM() external {
        poolManager.__setIsLoanManager(loanManager, false);

        vm.prank(loanManager);
        vm.expectRevert("PM:RF:NOT_LM");
        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_zeroSupply() external {
        pool.burn(address(1), 1);

        vm.prank(loanManager);
        vm.expectRevert("PM:RF:ZERO_SUPPLY");
        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_insufficientCoverBoundary() external {
        MockGlobals(globals).setMinCoverAmount(address(poolManager), 1000e18);

        asset.mint(poolManager.poolDelegateCover(), 1000e18 - 1);

        vm.startPrank(loanManager);
        vm.expectRevert("PM:RF:INSUFFICIENT_COVER");
        poolManager.requestFunds(loanManager, 1);

        asset.mint(poolManager.poolDelegateCover(), 1);

        poolManager.requestFunds(loanManager, 1);
    }

    function test_requestFunds_lockedLiquidityBoundary() external {
        MockWithdrawalManager(withdrawalManager).__setLockedLiquidity(1_000_000e18);

        vm.startPrank(loanManager);
        vm.expectRevert("PM:RF:LOCKED_LIQUIDITY");
        poolManager.requestFunds(loanManager, 1);

        asset.mint(poolManager.pool(), 1);

        poolManager.requestFunds(loanManager, 1);
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
