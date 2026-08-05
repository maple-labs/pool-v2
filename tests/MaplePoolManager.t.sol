// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { Test }      from "../modules/forge-std/src/Test.sol";
import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MaplePoolManager }            from "../contracts/MaplePoolManager.sol";
import { MaplePoolManagerFactory }     from "../contracts/proxy/MaplePoolManagerFactory.sol";
import { MaplePoolManagerInitializer } from "../contracts/proxy/MaplePoolManagerInitializer.sol";

import { IMaplePoolManager } from "../contracts/interfaces/IMaplePoolManager.sol";

import {
    MockERC20Pool,
    MockFactory,
    MockGlobals,
    MockLoan,
    MockLoanManager,
    MockPoolManagerMigrator,
    MockPoolPermissionManager,
    MockStrategy,
    MockWithdrawalManager
} from "./utils/Mocks.sol";

import { MaplePoolManagerHarness } from "./utils/Harnesses.sol";

import { TestBase } from "./utils/TestBase.sol";

contract PoolManagerTestBase is TestBase {

    address internal POOL_DELEGATE = makeAddr("POOL_DELEGATE");

    MockERC20                 internal asset;
    MockERC20Pool             internal pool;
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
    }

    function array(address a_) internal pure returns (address[] memory arr_) {
        arr_    = new address[](1);
        arr_[0] = a_;
    }

    function array(address a_, address b_) internal pure returns (address[] memory arr_) {
        arr_    = new address[](2);
        arr_[0] = a_;
        arr_[1] = b_;
    }

    function array(address a_, address b_, address c_) internal pure returns (address[] memory arr_) {
        arr_    = new address[](3);
        arr_[0] = a_;
        arr_[1] = b_;
        arr_[2] = c_;
    }

    function assertStrategyList(address[] memory expected_) internal {
        assertEq(poolManager.strategyListLength(), expected_.length);

        for (uint256 i_; i_ < expected_.length; ++i_) {
            assertEq(poolManager.strategyList(i_), expected_[i_]);
        }
    }

    function assertStrategyList_Empty() internal {
        assertEq(poolManager.strategyListLength(), 0);
    }

    function addStrategyManager(MockStrategy strategyManager_) internal {
        vm.prank(GOVERNOR);
        poolManager.addStrategyManager(address(strategyManager_));
    }

    function createStrategyManager(MockFactory strategyManagerFactory_) internal returns (MockStrategy strategyManager_) {
        strategyManager_ = new MockStrategy(address(pool), address(0), POOL_DELEGATE);

        strategyManager_.__setFactory(address(strategyManagerFactory_));
        strategyManager_.__setIsAssetSupported(address(asset), true);

        strategyManagerFactory_.__setIsInstance(address(strategyManager_), true);
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

    address internal migrator = address(new MockPoolManagerMigrator());

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

        vm.expectRevert("PM:NOT_PA_OR_NOT_CONFIGURED");
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

    function test_setLiquidityCap_success_asGovernor() external {
        poolManager.__setConfigured(true);

        vm.prank(GOVERNOR);
        poolManager.setLiquidityCap(1000);
    }

    function test_setLiquidityCap_success_asOperationalAdmin() external {
        poolManager.__setConfigured(true);

        vm.prank(MockGlobals(globals).operationalAdmin());
        poolManager.setLiquidityCap(1000);
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

        vm.expectRevert("PM:NOT_PA_OR_NOT_CONFIGURED");
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

    function test_setDelegateManagementFeeRate_success_asGovernor() external {
        poolManager.__setConfigured(true);

        vm.prank(GOVERNOR);
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);
    }

    function test_setDelegateManagementFeeRate_success_asOperationalAdmin() external {
        poolManager.__setConfigured(true);

        vm.prank(MockGlobals(globals).operationalAdmin());
        poolManager.setDelegateManagementFeeRate(newManagementFeeRate);
    }

}

contract SetStrategyCap_SetterTests is PoolManagerTestBase {

    MockFactory  internal strategyFactory;          // registered under STRATEGY_FACTORY
    MockFactory  internal strategyManagerFactory;   // registered under STRATEGY_MANAGER_FACTORY
    MockStrategy internal strategy;                 // valid instance of strategyFactory
    MockStrategy internal strategyManager;          // valid instance of strategyManagerFactory

    uint256 internal newCap = 1_000_000e18;

    function setUp() public override {
        super.setUp();

        strategyFactory        = new MockFactory();
        strategyManagerFactory = new MockFactory();

        strategy        = new MockStrategy(address(pool), address(0), POOL_DELEGATE);
        strategyManager = new MockStrategy(address(pool), address(0), POOL_DELEGATE);

        strategy.__setFactory(address(strategyFactory));
        strategyManager.__setFactory(address(strategyManagerFactory));

        poolManager.__setIsStrategy(address(strategy),               true);
        poolManager.__setIsStrategyManager(address(strategyManager), true);
        poolManager.__setConfigured(true);

        MockGlobals(globals).setValidInstance("STRATEGY_FACTORY",         address(strategyFactory),        true);
        MockGlobals(globals).setValidInstance("STRATEGY_MANAGER_FACTORY", address(strategyManagerFactory), true);

        strategyFactory.__setIsInstance(address(strategy),               true);
        strategyManagerFactory.__setIsInstance(address(strategyManager), true);
    }

    function test_setStrategyCap_revert_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PAUSED");
        poolManager.setStrategyCap(address(strategy), newCap);
    }

    function test_setStrategyCap_revert_notPoolDelegate() external {
        poolManager.__setConfigured(true);

        vm.expectRevert("PM:NOT_PA_OR_NOT_CONFIGURED");
        poolManager.setStrategyCap(address(strategy), newCap);
    }

    function test_setStrategyCap_revert_noChange() external {
        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NO_CHANGE");
        poolManager.setStrategyCap(address(strategy), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategy), newCap);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NO_CHANGE");
        poolManager.setStrategyCap(address(strategy), newCap);
    }

    function test_setStrategyCap_revert_notStrategyOrManager() external {
        address unregisteredStrategy = makeAddr("unregisteredStrategy");

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NOT_STRATEGY_OR_MANAGER");
        poolManager.setStrategyCap(unregisteredStrategy, newCap);
    }

    function test_setStrategyCap_revert_strategy_factoryNotRegistered() external {
        MockGlobals(globals).setValidInstance("STRATEGY_FACTORY", address(strategyFactory), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NOT_STRATEGY_OR_MANAGER");
        poolManager.setStrategyCap(address(strategy), newCap);
    }

    function test_setStrategyCap_revert_strategy_factoryRegisteredAsManagerOnly() external {
        strategy.__setFactory(address(strategyManagerFactory));

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NOT_STRATEGY_OR_MANAGER");
        poolManager.setStrategyCap(address(strategy), newCap);
    }

    function test_setStrategyCap_revert_strategy_invalidInstance() external {
        strategyFactory.__setIsInstance(address(strategy), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NOT_STRATEGY_OR_MANAGER");
        poolManager.setStrategyCap(address(strategy), newCap);
    }

    function test_setStrategyCap_revert_strategyManager_factoryNotRegistered() external {
        MockGlobals(globals).setValidInstance("STRATEGY_MANAGER_FACTORY", address(strategyManagerFactory), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NOT_STRATEGY_OR_MANAGER");
        poolManager.setStrategyCap(address(strategyManager), newCap);
    }

    function test_setStrategyCap_revert_strategyManager_factoryRegisteredAsStrategyOnly() external {
        strategyManager.__setFactory(address(strategyFactory));

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NOT_STRATEGY_OR_MANAGER");
        poolManager.setStrategyCap(address(strategyManager), newCap);
    }

    function test_setStrategyCap_revert_strategyManager_invalidInstance() external {
        strategyManagerFactory.__setIsInstance(address(strategyManager), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NOT_STRATEGY_OR_MANAGER");
        poolManager.setStrategyCap(address(strategyManager), newCap);
    }

    function test_setStrategyCap_revert_bothMappingsTrue_strategyManagerTakesPrecedence() external {
        poolManager.__setIsStrategyManager(address(strategy), true);

        assertEq(poolManager.isStrategy(address(strategy)),        true);
        assertEq(poolManager.isStrategyManager(address(strategy)), true);

        assertEq(MockGlobals(globals).isInstanceOf("STRATEGY_FACTORY",         address(strategyFactory)), true);
        assertEq(MockGlobals(globals).isInstanceOf("STRATEGY_MANAGER_FACTORY", address(strategyFactory)), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NOT_STRATEGY_OR_MANAGER");
        poolManager.setStrategyCap(address(strategy), newCap);
    }

    function test_setStrategyCap_revert_zeroAddress_isStrategyTrue() external {
        poolManager.__setIsStrategy(address(0), true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NOT_STRATEGY_OR_MANAGER");
        poolManager.setStrategyCap(address(0), newCap);
    }

    function test_setStrategyCap_revert_zeroAddress_isStrategyManagerTrue() external {
        poolManager.__setIsStrategyManager(address(0), true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:SSC:NOT_STRATEGY_OR_MANAGER");
        poolManager.setStrategyCap(address(0), newCap);
    }

    function test_setStrategyCap_success_asPoolDelegate() external {
        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), 0);

        vm.expectEmit();
        emit IMaplePoolManager.StrategyCapSet(address(strategy), newCap);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategy), newCap);

        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), newCap);
    }

    function test_setStrategyCap_success_asGovernor() external {
        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), 0);

        vm.prank(GOVERNOR);
        poolManager.setStrategyCap(address(strategy), newCap);

        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), newCap);
    }

    function test_setStrategyCap_success_asOperationalAdmin() external {
        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), 0);

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.setStrategyCap(address(strategy), newCap);

        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), newCap);
    }

    function test_setStrategyCap_success_strategy_whenNotConfigured_asAnyone() external {
        poolManager.__setConfigured(false);

        address anyone = makeAddr("anyone");

        assertEq(poolManager.configured(),                     false);
        assertEq(poolManager.strategyCapOf(address(strategy)), 0);

        vm.prank(anyone);
        poolManager.setStrategyCap(address(strategy), newCap);

        assertEq(poolManager.configured(),                     false);
        assertEq(poolManager.strategyCapOf(address(strategy)), newCap);
    }

    function test_setStrategyCap_success_strategyManager_whenNotConfigured_asAnyone() external {
        poolManager.__setConfigured(false);

        address anyone = makeAddr("anyone");

        assertEq(poolManager.configured(),                            false);
        assertEq(poolManager.strategyCapOf(address(strategyManager)), 0);

        vm.prank(anyone);
        poolManager.setStrategyCap(address(strategyManager), newCap);

        assertEq(poolManager.configured(),                            false);
        assertEq(poolManager.strategyCapOf(address(strategyManager)), newCap);
    }

    function test_setStrategyCap_success_strategyManager() external {
        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);
        assertEq(poolManager.strategyCapOf(address(strategyManager)),     0);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategyManager), newCap);

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);
        assertEq(poolManager.strategyCapOf(address(strategyManager)),     newCap);
    }

    function test_setStrategyCap_success_bothMappings() external {
        poolManager.__setIsStrategy(address(strategyManager), true);

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);
        assertEq(poolManager.strategyCapOf(address(strategyManager)),     0);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategyManager), newCap);

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);
        assertEq(poolManager.strategyCapOf(address(strategyManager)),     newCap);
    }

    function test_setStrategyCap_success_overwrite() external {
        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategy), newCap);

        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), newCap);

        uint256 updatedCap = 2_000_000e18;

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategy), updatedCap);

        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), updatedCap);
    }

    function test_setStrategyCap_success_zeroCap_bypassesValidation() external {
        assertEq(poolManager.configured(), true);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategy), newCap);

        assertEq(poolManager.strategyCapOf(address(strategy)), newCap);

        poolManager.__setIsStrategy(address(strategy), false);
        MockGlobals(globals).setValidInstance("STRATEGY_FACTORY", address(strategyFactory), false);
        strategyFactory.__setIsInstance(address(strategy), false);

        vm.expectEmit();
        emit IMaplePoolManager.StrategyCapSet(address(strategy), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategy), 0);

        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), 0);
    }

    function test_setStrategyCap_success_capMax() external {
        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategy), type(uint256).max);

        assertEq(poolManager.configured(),                     true);
        assertEq(poolManager.strategyCapOf(address(strategy)), type(uint256).max);
    }

    function test_setStrategyCap_success_multipleStrategies_isolation() external {
        uint256 strategyManagerCap = 5_000_000e18;

        assertEq(poolManager.configured(),                            true);
        assertEq(poolManager.strategyCapOf(address(strategy)),        0);
        assertEq(poolManager.strategyCapOf(address(strategyManager)), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategy), newCap);

        assertEq(poolManager.configured(),                            true);
        assertEq(poolManager.strategyCapOf(address(strategy)),        newCap);
        assertEq(poolManager.strategyCapOf(address(strategyManager)), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategyManager), strategyManagerCap);

        assertEq(poolManager.configured(),                            true);
        assertEq(poolManager.strategyCapOf(address(strategy)),        newCap);
        assertEq(poolManager.strategyCapOf(address(strategyManager)), strategyManagerCap);
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

    function test_processRedeem_revert_reentrancy() external {
        poolManager.__setLocked(2);

        vm.expectRevert("PM:LOCKED");
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

    function test_processWithdraw_revert_reentrancy() external {
        poolManager.__setLocked(2);

        vm.expectRevert("PM:LOCKED");
        poolManager.processWithdraw(1, address(1), address(1));
    }

    function test_processWithdraw_notEnabled() external {
        vm.expectRevert("PM:PW:NOT_ENABLED");
        poolManager.processWithdraw(0, address(0), address(0));
    }

}

contract HasSufficientCoverTests is PoolManagerTestBase {

    function test_hasSufficientCover_alwaysTrue() external {
        assertTrue(poolManager.hasSufficientCover());
    }

}

contract AddStrategy_SetterTests is PoolManagerTestBase {

    address loanManagerFactory;

    bytes deploymentData;

    function setUp() public override {
        super.setUp();

        loanManagerFactory = address(new MockFactory());

        MockGlobals(globals).setValidInstance("STRATEGY_FACTORY", loanManagerFactory, true);

        deploymentData = abi.encode(address(poolManager));
    }

    function test_addStrategy_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PAUSED");
        poolManager.addStrategy(address(0), bytes32("salt"), deploymentData);
    }

    function test_addStrategy_notGovernor() external {
        poolManager.__setConfigured(true);

        vm.expectRevert("PM:NOT_GOV_OR_NOT_CONFIGURED");
        poolManager.addStrategy(address(0), bytes32("salt"), deploymentData);
    }

    function test_addStrategy_asPoolDelegate_whenConfigured_reverts() external {
        poolManager.__setConfigured(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:NOT_GOV_OR_NOT_CONFIGURED");
        poolManager.addStrategy(loanManagerFactory, bytes32("salt"), deploymentData);
    }

    function test_addStrategy_asOperationalAdmin_whenConfigured_reverts() external {
        poolManager.__setConfigured(true);

        vm.prank(OPERATIONAL_ADMIN);
        vm.expectRevert("PM:NOT_GOV_OR_NOT_CONFIGURED");
        poolManager.addStrategy(loanManagerFactory, bytes32("salt"), deploymentData);
    }

    function test_addStrategy_invalidFactory() external {
        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:AS:INVALID_FACTORY");
        poolManager.addStrategy(address(0), bytes32("salt"), deploymentData);
    }

    function test_addStrategy_aumFailure() external {
        MockFactory(loanManagerFactory).__setReverts(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:AS:AUM_FAILURE");
        poolManager.addStrategy(loanManagerFactory, bytes32("salt"), deploymentData);
    }

    function test_addStrategy_success_whenNotConfigured() external {
        address expectedStrategy = MockFactory(loanManagerFactory).getNextStrategyAddress();

        vm.expectEmit();
        emit IMaplePoolManager.StrategyAdded(expectedStrategy);

        address strategy_ = poolManager.addStrategy(loanManagerFactory, bytes32("salt"), deploymentData);

        assertEq(strategy_,                         expectedStrategy);
        assertEq(poolManager.strategyList(0),       strategy_);
        assertEq(poolManager.strategyListLength(),  1);
        assertEq(poolManager.isStrategy(strategy_), true);
    }

    function test_addStrategy_success_asGovernor() external {
        poolManager.__setConfigured(true);

        address expectedStrategy = MockFactory(loanManagerFactory).getNextStrategyAddress();

        vm.expectEmit();
        emit IMaplePoolManager.StrategyAdded(expectedStrategy);

        vm.prank(GOVERNOR);
        address strategy_ = poolManager.addStrategy(loanManagerFactory, bytes32("salt"), deploymentData);

        assertEq(strategy_,                         expectedStrategy);
        assertEq(poolManager.strategyList(0),       strategy_);
        assertEq(poolManager.strategyListLength(),  1);
        assertEq(poolManager.isStrategy(strategy_), true);
    }

}

contract AddStrategyManager_SetterTests is PoolManagerTestBase {

    MockFactory  internal strategyManagerFactory;
    MockStrategy internal strategyManager;

    function setUp() public override {
        super.setUp();

        strategyManagerFactory = new MockFactory();
        strategyManager        = new MockStrategy(address(pool), address(0), POOL_DELEGATE);

        strategyManager.__setFactory(address(strategyManagerFactory));
        strategyManager.__setIsAssetSupported(address(asset), true);

        MockGlobals(globals).setValidInstance("STRATEGY_MANAGER_FACTORY", address(strategyManagerFactory), true);

        strategyManagerFactory.__setIsInstance(address(strategyManager), true);
    }

    function test_addStrategyManager_revert_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(GOVERNOR);
        vm.expectRevert("PM:PAUSED");
        poolManager.addStrategyManager(address(strategyManager));
    }

    function test_addStrategyManager_revert_notGovernor_whenConfigured() external {
        poolManager.__setConfigured(true);

        vm.expectRevert("PM:NOT_GOV_OR_NOT_CONFIGURED");
        poolManager.addStrategyManager(address(strategyManager));
    }

    function test_addStrategyManager_revert_alreadyStrategy() external {
        poolManager.__setIsStrategy(address(strategyManager), true);

        vm.prank(GOVERNOR);
        vm.expectRevert("PM:ASM:ALREADY_STRATEGY");
        poolManager.addStrategyManager(address(strategyManager));
    }

    function test_addStrategyManager_revert_alreadyStrategyManager() external {
        vm.prank(GOVERNOR);
        poolManager.addStrategyManager(address(strategyManager));

        vm.prank(GOVERNOR);
        vm.expectRevert("PM:ASM:ALREADY_STRATEGY_MANAGER");
        poolManager.addStrategyManager(address(strategyManager));
    }

    function test_addStrategyManager_revert_invalidStrategyManager_factoryNotRegistered() external {
        MockGlobals(globals).setValidInstance("STRATEGY_MANAGER_FACTORY", address(strategyManagerFactory), false);

        vm.prank(GOVERNOR);
        vm.expectRevert("PM:ASM:INVALID_STRATEGY_MANAGER");
        poolManager.addStrategyManager(address(strategyManager));
    }

    function test_addStrategyManager_revert_invalidStrategyManager_factoryRegisteredAsStrategyOnly() external {
        MockFactory strategyFactory = new MockFactory();

        MockGlobals(globals).setValidInstance("STRATEGY_FACTORY", address(strategyFactory), true);

        strategyManager.__setFactory(address(strategyFactory));

        vm.prank(GOVERNOR);
        vm.expectRevert("PM:ASM:INVALID_STRATEGY_MANAGER");
        poolManager.addStrategyManager(address(strategyManager));
    }

    function test_addStrategyManager_revert_invalidStrategyManager_invalidInstance() external {
        strategyManagerFactory.__setIsInstance(address(strategyManager), false);

        vm.prank(GOVERNOR);
        vm.expectRevert("PM:ASM:INVALID_STRATEGY_MANAGER");
        poolManager.addStrategyManager(address(strategyManager));
    }

    function test_addStrategyManager_revert_zeroAddress() external {
        vm.prank(GOVERNOR);
        vm.expectRevert("PM:ASM:INVALID_STRATEGY_MANAGER");
        poolManager.addStrategyManager(address(0));
    }

    function test_addStrategyManager_revert_assetNotSupported() external {
        strategyManager.__setIsAssetSupported(address(asset), false);

        vm.prank(GOVERNOR);
        vm.expectRevert("PM:ASM:ASSET_NOT_SUPPORTED");
        poolManager.addStrategyManager(address(strategyManager));
    }

    function test_addStrategyManager_revert_assetsOfFailure() external {
        strategyManager.__setRevertOnAssetsOf(true);

        vm.prank(GOVERNOR);
        vm.expectRevert("PM:ASM:ASSETS_OF_FAILURE");
        poolManager.addStrategyManager(address(strategyManager));
    }

    function test_addStrategyManager_success_emptyStrategyManager() external {
        uint256 initialPoolBalance = asset.balanceOf(address(pool));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), false);
        assertEq(poolManager.totalAssets(),                               initialPoolBalance);

        assertStrategyList_Empty();

        vm.expectEmit();
        emit IMaplePoolManager.StrategyManagerAdded(address(strategyManager));

        vm.prank(GOVERNOR);
        poolManager.addStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);
        assertEq(poolManager.totalAssets(),                               initialPoolBalance);

        assertStrategyList(array(address(strategyManager)));
    }

    function test_addStrategyManager_success_whenNotConfigured_asAnyCaller() external {
        assertEq(poolManager.configured(), false);

        vm.prank(makeAddr("anyone"));
        poolManager.addStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);

        assertStrategyList(array(address(strategyManager)));
    }

    function test_addStrategyManager_success_whenConfigured_asGovernor() external {
        poolManager.__setConfigured(true);

        assertEq(poolManager.configured(), true);

        vm.prank(GOVERNOR);
        poolManager.addStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);

        assertStrategyList(array(address(strategyManager)));
    }

    function test_addStrategyManager_success_nonEmptyStrategyManager() external {
        uint256 strategyManagerAssets = 500_000e18;
        uint256 initialPoolBalance    = asset.balanceOf(address(pool));

        strategyManager.__setAssetsOf(address(poolManager), strategyManagerAssets);

        assertEq(poolManager.isStrategyManager(address(strategyManager)), false);
        assertEq(poolManager.totalAssets(),                               initialPoolBalance);

        assertStrategyList_Empty();

        vm.expectEmit();
        emit IMaplePoolManager.StrategyManagerAdded(address(strategyManager));

        vm.prank(GOVERNOR);
        poolManager.addStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);
        assertEq(poolManager.totalAssets(),                               initialPoolBalance + strategyManagerAssets);

        assertStrategyList(array(address(strategyManager)));
    }

    function test_addStrategyManager_success_multipleStrategyManagers() external {
        MockStrategy strategyManager2 = new MockStrategy(address(pool), address(0), POOL_DELEGATE);

        strategyManager2.__setFactory(address(strategyManagerFactory));
        strategyManager2.__setIsAssetSupported(address(asset), true);
        strategyManagerFactory.__setIsInstance(address(strategyManager2), true);

        uint256 initialPoolBalance = asset.balanceOf(address(pool));

        assertEq(poolManager.isStrategyManager(address(strategyManager)),  false);
        assertEq(poolManager.isStrategyManager(address(strategyManager2)), false);
        assertEq(poolManager.totalAssets(),                                initialPoolBalance);

        assertStrategyList_Empty();

        vm.prank(GOVERNOR);
        poolManager.addStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)),  true);
        assertEq(poolManager.isStrategyManager(address(strategyManager2)), false);
        assertEq(poolManager.totalAssets(),                                initialPoolBalance);

        assertStrategyList(array(address(strategyManager)));

        vm.prank(GOVERNOR);
        poolManager.addStrategyManager(address(strategyManager2));

        assertEq(poolManager.isStrategyManager(address(strategyManager)),  true);
        assertEq(poolManager.isStrategyManager(address(strategyManager2)), true);
        assertEq(poolManager.totalAssets(),                                initialPoolBalance);

        assertStrategyList(array(address(strategyManager), address(strategyManager2)));
    }

    function test_addStrategyManager_success_appendsAfterExistingStrategy() external {
        MockStrategy strategy = new MockStrategy(address(pool), address(0), POOL_DELEGATE);

        poolManager.__setIsStrategy(address(strategy), true);
        poolManager.__pushToStrategyList(address(strategy));

        uint256 strategyAssets     = 100_000e18;
        uint256 initialPoolBalance = asset.balanceOf(address(pool));

        strategy.__setAssetsUnderManagement(strategyAssets);

        assertEq(poolManager.isStrategyManager(address(strategyManager)), false);
        assertEq(poolManager.totalAssets(),                               initialPoolBalance + strategyAssets);

        assertStrategyList(array(address(strategy)));

        vm.prank(GOVERNOR);
        poolManager.addStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);
        assertEq(poolManager.totalAssets(),                               initialPoolBalance + strategyAssets);

        assertStrategyList(array(address(strategy), address(strategyManager)));
    }

    function test_addStrategyManager_success_interleavedWithStrategies() external {
        MockStrategy strategy1 = new MockStrategy(address(pool), address(0), POOL_DELEGATE);
        MockStrategy strategy2 = new MockStrategy(address(pool), address(0), POOL_DELEGATE);

        poolManager.__setIsStrategy(address(strategy1), true);
        poolManager.__setIsStrategy(address(strategy2), true);

        uint256 strategy1Assets    = 100_000e18;
        uint256 strategy2Assets    = 150_000e18;
        uint256 initialPoolBalance = asset.balanceOf(address(pool));

        strategy1.__setAssetsUnderManagement(strategy1Assets);
        strategy2.__setAssetsUnderManagement(strategy2Assets);

        poolManager.__pushToStrategyList(address(strategy1));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), false);
        assertEq(poolManager.totalAssets(),                               initialPoolBalance + strategy1Assets);

        assertStrategyList(array(address(strategy1)));

        vm.prank(GOVERNOR);
        poolManager.addStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);
        assertEq(poolManager.totalAssets(),                               initialPoolBalance + strategy1Assets);

        assertStrategyList(array(address(strategy1), address(strategyManager)));

        poolManager.__pushToStrategyList(address(strategy2));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);
        assertEq(poolManager.totalAssets(),                               initialPoolBalance + strategy1Assets + strategy2Assets);

        assertStrategyList(array(address(strategy1), address(strategyManager), address(strategy2)));
    }

}

contract RemoveStrategyManager_SetterTests is PoolManagerTestBase {

    MockFactory  strategyManagerFactory;
    MockStrategy strategyManager;

    function setUp() public override {
        super.setUp();

        strategyManagerFactory = new MockFactory();
        strategyManager        = createStrategyManager(strategyManagerFactory);

        MockGlobals(globals).setValidInstance("STRATEGY_MANAGER_FACTORY", address(strategyManagerFactory), true);
    }

    function test_removeStrategyManager_revert_paused() external {
        addStrategyManager(strategyManager);

        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(OPERATIONAL_ADMIN);
        vm.expectRevert("PM:PAUSED");
        poolManager.removeStrategyManager(address(strategyManager));
    }

    function test_removeStrategyManager_revert_notOperationalAdmin() external {
        addStrategyManager(strategyManager);

        // Default caller
        vm.expectRevert("PM:RSM:NOT_OPERATIONAL_ADMIN");
        poolManager.removeStrategyManager(address(strategyManager));

        // Pool delegate cannot remove
        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:RSM:NOT_OPERATIONAL_ADMIN");
        poolManager.removeStrategyManager(address(strategyManager));

        // Governor cannot remove
        vm.prank(GOVERNOR);
        vm.expectRevert("PM:RSM:NOT_OPERATIONAL_ADMIN");
        poolManager.removeStrategyManager(address(strategyManager));
    }

    function test_removeStrategyManager_revert_notStrategyManager() external {
        vm.prank(OPERATIONAL_ADMIN);
        vm.expectRevert("PM:RSM:NOT_STRATEGY_MANAGER");
        poolManager.removeStrategyManager(address(strategyManager));
    }

    function test_removeStrategyManager_revert_nonZeroAssets() external {
        uint256 managerAssets = 100_000e18;

        addStrategyManager(strategyManager);

        strategyManager.__setAssetsOf(address(poolManager), managerAssets);

        vm.prank(OPERATIONAL_ADMIN);
        vm.expectRevert("PM:RSM:NON_ZERO_ASSETS");
        poolManager.removeStrategyManager(address(strategyManager));
    }

    function test_removeStrategyManager_revert_notStrategyManager_afterRemoval() external {
        addStrategyManager(strategyManager);

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.removeStrategyManager(address(strategyManager));

        vm.prank(OPERATIONAL_ADMIN);
        vm.expectRevert("PM:RSM:NOT_STRATEGY_MANAGER");
        poolManager.removeStrategyManager(address(strategyManager));
    }

    function test_removeStrategyManager_success() external {
        addStrategyManager(strategyManager);

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);

        assertStrategyList(array(address(strategyManager)));

        vm.expectEmit();
        emit IMaplePoolManager.StrategyManagerRemoved(address(strategyManager));

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.removeStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), false);

        assertStrategyList_Empty();
    }

    function test_removeStrategyManager_success_clearsStrategyCap() external {
        uint256 managerCap = 100_000e18;

        addStrategyManager(strategyManager);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(address(strategyManager), managerCap);

        assertEq(poolManager.strategyCapOf(address(strategyManager)), managerCap);

        vm.expectEmit();
        emit IMaplePoolManager.StrategyCapSet(address(strategyManager), 0);

        vm.expectEmit();
        emit IMaplePoolManager.StrategyManagerRemoved(address(strategyManager));

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.removeStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), false);
        assertEq(poolManager.strategyCapOf(address(strategyManager)),     0);

        addStrategyManager(strategyManager);

        assertEq(poolManager.isStrategyManager(address(strategyManager)), true);
        assertEq(poolManager.strategyCapOf(address(strategyManager)),     0);

        vm.prank(address(strategyManager));
        vm.expectRevert("PM:RF:STRATEGY_CAP");
        poolManager.requestFunds(makeAddr("destination"), 1);
    }

    function test_removeStrategyManager_success_otherPoolManagerHasAssets() external {
        address otherPoolManager = makeAddr("otherPoolManager");
        uint256 managerAssets    = 100_000e18;

        addStrategyManager(strategyManager);

        strategyManager.__setAssetsOf(otherPoolManager, managerAssets);

        assertEq(strategyManager.assetsOf(address(poolManager)), 0);
        assertEq(strategyManager.assetsOf(otherPoolManager),     managerAssets);

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.removeStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), false);
        assertEq(strategyManager.assetsOf(otherPoolManager),              managerAssets);

        assertStrategyList_Empty();
    }

    function test_removeStrategyManager_success_otherPoolManagerHasLosses() external {
        address otherPoolManager = makeAddr("otherPoolManager");
        uint256 managerLosses    = 100_000e18;

        addStrategyManager(strategyManager);

        strategyManager.__setUnrealizedLossesOf(otherPoolManager, managerLosses);

        assertEq(strategyManager.unrealizedLossesOf(address(poolManager)), 0);
        assertEq(strategyManager.unrealizedLossesOf(otherPoolManager),     managerLosses);

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.removeStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), false);
        assertEq(strategyManager.unrealizedLossesOf(otherPoolManager),    managerLosses);

        assertStrategyList_Empty();
    }

    function test_removeStrategyManager_success_nonZeroLosses() external {
        uint256 managerLosses = 100_000e18;

        addStrategyManager(strategyManager);

        strategyManager.__setUnrealizedLossesOf(address(poolManager), managerLosses);

        assertStrategyList(array(address(strategyManager)));

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.removeStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)), false);

        assertStrategyList_Empty();
    }

    function test_removeStrategyManager_success_unorderedRemoval_middleAndLast() external {
        MockStrategy strategy         = new MockStrategy(address(pool), address(0), POOL_DELEGATE);
        MockStrategy strategyManager2 = createStrategyManager(strategyManagerFactory);

        poolManager.__setIsStrategy(address(strategy), true);
        poolManager.__pushToStrategyList(address(strategy));

        addStrategyManager(strategyManager);
        addStrategyManager(strategyManager2);

        assertEq(poolManager.isStrategy(address(strategy)),                true);
        assertEq(poolManager.isStrategyManager(address(strategyManager)),  true);
        assertEq(poolManager.isStrategyManager(address(strategyManager2)), true);

        assertStrategyList(array(address(strategy), address(strategyManager), address(strategyManager2)));

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.removeStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategy(address(strategy)),                true);
        assertEq(poolManager.isStrategyManager(address(strategyManager)),  false);
        assertEq(poolManager.isStrategyManager(address(strategyManager2)), true);

        assertStrategyList(array(address(strategy), address(strategyManager2)));

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.removeStrategyManager(address(strategyManager2));

        assertEq(poolManager.isStrategy(address(strategy)),                true);
        assertEq(poolManager.isStrategyManager(address(strategyManager)),  false);
        assertEq(poolManager.isStrategyManager(address(strategyManager2)), false);

        assertStrategyList(array(address(strategy)));
    }

    function test_removeStrategyManager_success_unorderedRemoval_first() external {
        MockStrategy strategyManager2 = createStrategyManager(strategyManagerFactory);
        MockStrategy strategyManager3 = createStrategyManager(strategyManagerFactory);

        addStrategyManager(strategyManager);
        addStrategyManager(strategyManager2);
        addStrategyManager(strategyManager3);

        assertStrategyList(array(address(strategyManager), address(strategyManager2), address(strategyManager3)));

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.removeStrategyManager(address(strategyManager));

        assertEq(poolManager.isStrategyManager(address(strategyManager)),  false);
        assertEq(poolManager.isStrategyManager(address(strategyManager2)), true);
        assertEq(poolManager.isStrategyManager(address(strategyManager3)), true);

        assertStrategyList(array(address(strategyManager3), address(strategyManager2)));
    }

    function test_removeStrategyManager_success_unorderedRemoval_last() external {
        MockStrategy strategyManager2 = createStrategyManager(strategyManagerFactory);
        MockStrategy strategyManager3 = createStrategyManager(strategyManagerFactory);

        addStrategyManager(strategyManager);
        addStrategyManager(strategyManager2);
        addStrategyManager(strategyManager3);

        assertStrategyList(array(address(strategyManager), address(strategyManager2), address(strategyManager3)));

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.removeStrategyManager(address(strategyManager3));

        assertEq(poolManager.isStrategyManager(address(strategyManager)),  true);
        assertEq(poolManager.isStrategyManager(address(strategyManager2)), true);
        assertEq(poolManager.isStrategyManager(address(strategyManager3)), false);

        assertStrategyList(array(address(strategyManager), address(strategyManager2)));
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
        MockGlobals(globals).setValidInstance("WITHDRAWAL_MANAGER_QUEUE_FACTORY", address(withdrawalManagerFactory), false);

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

contract TriggerDefaultTests is PoolManagerTestBase {

    MockLoan        internal loan;
    MockLoanManager internal loanManager;

    function setUp() public override {
        super.setUp();

        loanManager = new MockLoanManager();
        loan        = new MockLoan();

        loan.__setLender(address(loanManager));
    }

    function test_triggerDefault_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:PAUSED");
        poolManager.triggerDefault(address(loan));
    }

    function test_triggerDefault_revert_reentrancy() external {
        poolManager.__setLocked(2);

        vm.expectRevert("PM:LOCKED");
        poolManager.triggerDefault(address(loan));
    }

    function test_triggerDefault_notAuthorized() external {
        vm.expectRevert("PM:NOT_PD_OR_GOV_OR_OA");
        poolManager.triggerDefault(address(loan));
    }

    function test_triggerDefault_success_asPoolDelegate() external {
        loanManager.__setTriggerDefaultReturn(1_000e18);

        vm.expectEmit();
        emit IMaplePoolManager.CollateralLiquidationFinished(address(loan), 1_000e18);

        vm.prank(POOL_DELEGATE);
        poolManager.triggerDefault(address(loan));
    }

    function test_triggerDefault_success_asGovernor() external {
        loanManager.__setTriggerDefaultReturn(1_000e18);

        vm.expectEmit();
        emit IMaplePoolManager.CollateralLiquidationFinished(address(loan), 1_000e18);

        vm.prank(GOVERNOR);
        poolManager.triggerDefault(address(loan));
    }

    function test_triggerDefault_success_asOperationalAdmin() external {
        loanManager.__setTriggerDefaultReturn(1_000e18);

        vm.expectEmit();
        emit IMaplePoolManager.CollateralLiquidationFinished(address(loan), 1_000e18);

        vm.prank(OPERATIONAL_ADMIN);
        poolManager.triggerDefault(address(loan));
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

contract TotalAssetsTests is PoolManagerTestBase {

    MockStrategy internal strategy;
    MockStrategy internal strategyManager;

    function setUp() public override {
        super.setUp();

        strategy        = new MockStrategy(address(pool), address(0), POOL_DELEGATE);
        strategyManager = new MockStrategy(address(pool), address(0), POOL_DELEGATE);

        poolManager.__setIsStrategyManager(address(strategyManager), true);
        poolManager.__setIsStrategy(address(strategy), true);

        asset.burn(address(pool), asset.balanceOf(address(pool)));
    }

    function test_totalAssets_singleStrategy() external {
        uint256 strategyAssets = 250_000e18;

        assertEq(poolManager.totalAssets(), 0);

        poolManager.__pushToStrategyList(address(strategy));
        strategy.__setAssetsUnderManagement(strategyAssets);

        assertEq(poolManager.totalAssets(), strategyAssets);
    }

    function test_totalAssets_singleStrategyManager() external {
        uint256 managerAssets = 400_000e18;

        assertEq(poolManager.totalAssets(), 0);

        poolManager.__pushToStrategyList(address(strategyManager));
        strategyManager.__setAssetsOf(address(poolManager), managerAssets);

        assertEq(poolManager.totalAssets(), managerAssets);
    }

    function test_totalAssets_mixed() external {
        uint256 strategyAssets = 250_000e18;
        uint256 managerAssets  = 400_000e18;

        assertEq(poolManager.totalAssets(), 0);

        poolManager.__pushToStrategyList(address(strategy));
        poolManager.__pushToStrategyList(address(strategyManager));

        strategy.__setAssetsUnderManagement(strategyAssets);
        strategyManager.__setAssetsOf(address(poolManager), managerAssets);

        assertEq(poolManager.totalAssets(), strategyAssets + managerAssets);
    }

    function test_totalAssets_mixed_partialThenFullLoss() external {
        uint256 strategyAssets = 1_600e18;
        uint256 managerAssets  = 800e18;

        /**********************************************************************************************************************************/
        /*** Step 1: Baseline                                                                                                           ***/
        /**********************************************************************************************************************************/

        assertEq(poolManager.totalAssets(), 0);

        /**********************************************************************************************************************************/
        /*** Step 2: Full exposure                                                                                                      ***/
        /**********************************************************************************************************************************/

        poolManager.__pushToStrategyList(address(strategy));
        poolManager.__pushToStrategyList(address(strategyManager));

        strategy.__setAssetsUnderManagement(strategyAssets);
        strategyManager.__setAssetsOf(address(poolManager), managerAssets);

        assertEq(poolManager.totalAssets(), strategyAssets + managerAssets);

        /**********************************************************************************************************************************/
        /*** Step 3: Partial loss                                                                                                       ***/
        /**********************************************************************************************************************************/

        strategy.__setAssetsUnderManagement(strategyAssets / 16);
        strategyManager.__setAssetsOf(address(poolManager), managerAssets / 19);

        assertEq(poolManager.totalAssets(), strategyAssets / 16 + managerAssets / 19);

        /**********************************************************************************************************************************/
        /*** Step 4: Full loss                                                                                                          ***/
        /**********************************************************************************************************************************/

        strategy.__setAssetsUnderManagement(0);
        strategyManager.__setAssetsOf(address(poolManager), 0);

        assertEq(poolManager.totalAssets(), 0);
    }

    function test_totalAssets_managerWithZeroExposure() external {
        assertEq(poolManager.totalAssets(), 0);

        poolManager.__pushToStrategyList(address(strategy));
        poolManager.__pushToStrategyList(address(strategyManager));

        assertEq(strategy.assetsUnderManagement(),               0);
        assertEq(strategyManager.assetsOf(address(poolManager)), 0);

        assertEq(poolManager.totalAssets(), 0);
    }

}

contract UnrealizedLossesTests is PoolManagerTestBase {

    MockStrategy internal strategy;
    MockStrategy internal strategyManager;

    function setUp() public override {
        super.setUp();

        strategy        = new MockStrategy(address(pool), address(0), POOL_DELEGATE);
        strategyManager = new MockStrategy(address(pool), address(0), POOL_DELEGATE);

        poolManager.__setIsStrategyManager(address(strategyManager), true);
        poolManager.__setIsStrategy(address(strategy), true);

        asset.burn(address(pool), asset.balanceOf(address(pool)));
    }

    function test_unrealizedLosses_emptyStrategyList() external {
        assertEq(poolManager.unrealizedLosses(), 0);
    }

    function test_unrealizedLosses_singleStrategy() external {
        uint256 strategyAssets = 1_000_000e18;
        uint256 strategyLosses =   100_000e18;

        assertEq(poolManager.unrealizedLosses(), 0);

        poolManager.__pushToStrategyList(address(strategy));
        strategy.__setAssetsUnderManagement(strategyAssets);
        strategy.__setUnrealizedLosses(strategyLosses);

        assertEq(poolManager.totalAssets(),      strategyAssets);
        assertEq(poolManager.unrealizedLosses(), strategyLosses);
    }

    function test_unrealizedLosses_singleStrategyManager() external {
        uint256 managerAssets = 1_000_000e18;
        uint256 managerLosses =   175_000e18;

        assertEq(poolManager.unrealizedLosses(), 0);

        poolManager.__pushToStrategyList(address(strategyManager));
        strategyManager.__setAssetsOf(address(poolManager), managerAssets);
        strategyManager.__setUnrealizedLossesOf(address(poolManager), managerLosses);

        assertEq(poolManager.totalAssets(),      managerAssets);
        assertEq(poolManager.unrealizedLosses(), managerLosses);
    }

    function test_unrealizedLosses_mixed() external {
        uint256 strategyAssets = 1_000_000e18;
        uint256 managerAssets  = 1_000_000e18;
        uint256 strategyLosses =   100_000e18;
        uint256 managerLosses  =   175_000e18;

        assertEq(poolManager.unrealizedLosses(), 0);

        poolManager.__pushToStrategyList(address(strategy));
        poolManager.__pushToStrategyList(address(strategyManager));

        strategy.__setAssetsUnderManagement(strategyAssets);
        strategyManager.__setAssetsOf(address(poolManager), managerAssets);

        strategy.__setUnrealizedLosses(strategyLosses);
        strategyManager.__setUnrealizedLossesOf(address(poolManager), managerLosses);

        assertEq(poolManager.totalAssets(),      strategyAssets + managerAssets);
        assertEq(poolManager.unrealizedLosses(), strategyLosses + managerLosses);
    }

    function test_unrealizedLosses_mixed_partialThenFullRecovery() external {
        uint256 strategyAssets = 100_000e18;
        uint256 managerAssets  = 100_000e18;
        uint256 strategyLosses =   1_600e18;
        uint256 managerLosses  =     800e18;

        /**********************************************************************************************************************************/
        /*** Step 1: Baseline                                                                                                           ***/
        /**********************************************************************************************************************************/

        assertEq(poolManager.unrealizedLosses(), 0);

        /**********************************************************************************************************************************/
        /*** Step 2: Full impairment                                                                                                    ***/
        /**********************************************************************************************************************************/

        poolManager.__pushToStrategyList(address(strategy));
        poolManager.__pushToStrategyList(address(strategyManager));

        strategy.__setAssetsUnderManagement(strategyAssets);
        strategyManager.__setAssetsOf(address(poolManager), managerAssets);

        strategy.__setUnrealizedLosses(strategyLosses);
        strategyManager.__setUnrealizedLossesOf(address(poolManager), managerLosses);

        assertEq(poolManager.totalAssets(),      strategyAssets + managerAssets);
        assertEq(poolManager.unrealizedLosses(), strategyLosses + managerLosses);

        /**********************************************************************************************************************************/
        /*** Step 3: Partial recovery                                                                                                   ***/
        /**********************************************************************************************************************************/

        strategy.__setUnrealizedLosses(strategyLosses / 16);
        strategyManager.__setUnrealizedLossesOf(address(poolManager), managerLosses / 19);

        assertEq(poolManager.unrealizedLosses(), strategyLosses / 16 + managerLosses / 19);

        /**********************************************************************************************************************************/
        /*** Step 4: Full recovery                                                                                                      ***/
        /**********************************************************************************************************************************/

        strategy.__setUnrealizedLosses(0);
        strategyManager.__setUnrealizedLossesOf(address(poolManager), 0);

        assertEq(poolManager.unrealizedLosses(), 0);
    }

    function test_unrealizedLosses_managerWithZeroLosses() external {
        assertEq(poolManager.unrealizedLosses(), 0);

        poolManager.__pushToStrategyList(address(strategy));
        poolManager.__pushToStrategyList(address(strategyManager));

        assertEq(strategy.unrealizedLosses(),                              0);
        assertEq(strategyManager.unrealizedLossesOf(address(poolManager)), 0);

        assertEq(poolManager.unrealizedLosses(), 0);
    }

    function test_unrealizedLosses_clampedToTotalAssets() external {
        uint256 strategyAssets = 500_000e18;
        uint256 strategyLosses = 800_000e18;

        poolManager.__pushToStrategyList(address(strategy));
        strategy.__setAssetsUnderManagement(strategyAssets);
        strategy.__setUnrealizedLosses(strategyLosses);

        assertEq(poolManager.totalAssets(),      strategyAssets);
        assertEq(poolManager.unrealizedLosses(), strategyAssets);
    }

}

contract RequestFundsTests is PoolManagerTestBase {

    address destination = makeAddr("destination");

    address strategy;
    address strategyManager;
    address strategyFactory;
    address strategyManagerFactory;

    function setUp() public override {
        super.setUp();

        strategy               = address(new MockStrategy(address(pool), address(0), POOL_DELEGATE));
        strategyManager        = address(new MockStrategy(address(pool), address(0), POOL_DELEGATE));
        strategyFactory        = address(new MockFactory());
        strategyManagerFactory = address(new MockFactory());

        MockGlobals(globals).setValidInstance("STRATEGY_FACTORY",                 strategyFactory,                   true);
        MockGlobals(globals).setValidInstance("STRATEGY_MANAGER_FACTORY",         strategyManagerFactory,            true);
        MockGlobals(globals).setValidInstance("WITHDRAWAL_MANAGER_QUEUE_FACTORY", address(withdrawalManagerFactory), true);

        MockStrategy(strategy).__setFactory(strategyFactory);
        MockStrategy(strategyManager).__setFactory(strategyManagerFactory);

        poolManager.__setIsStrategy(strategy,               true);
        poolManager.__setIsStrategyManager(strategyManager, true);

        MockFactory(strategyFactory).__setIsInstance(strategy,               true);
        MockFactory(strategyManagerFactory).__setIsInstance(strategyManager, true);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(withdrawalManager);
        poolManager.setStrategyCap(strategy,        type(uint256).max);
        poolManager.setStrategyCap(strategyManager, type(uint256).max);
        vm.stopPrank();
    }

    function test_requestFunds_revert_paused() external {
        MockGlobals(globals).__setFunctionPaused(true);

        vm.expectRevert("PM:PAUSED");
        poolManager.requestFunds(strategy, 1);

        vm.expectRevert("PM:PAUSED");
        poolManager.requestFunds(strategyManager, 1);
    }

    function test_requestFunds_revert_reentrancy() external {
        poolManager.__setLocked(2);

        vm.expectRevert("PM:LOCKED");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 1);

        vm.expectRevert("PM:LOCKED");
        vm.prank(strategyManager);
        poolManager.requestFunds(strategyManager, 1);
    }

    function test_requestFunds_revert_invalidDestination() external {
        vm.expectRevert("PM:RF:ZERO_DESTINATION");
        vm.prank(strategy);
        poolManager.requestFunds(address(0), 1000e18);

        vm.expectRevert("PM:RF:ZERO_DESTINATION");
        vm.prank(strategyManager);
        poolManager.requestFunds(address(0), 1000e18);
    }

    function test_requestFunds_revert_zeroAmount() external {
        vm.expectRevert("PM:RF:ZERO_AMOUNT");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 0);

        vm.expectRevert("PM:RF:ZERO_AMOUNT");
        vm.prank(strategyManager);
        poolManager.requestFunds(strategyManager, 0);
    }

    function test_requestFunds_revert_zeroSupply() external {
        pool.burn(address(1), pool.totalSupply());

        vm.expectRevert("PM:RF:ZERO_SUPPLY");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 1);

        vm.expectRevert("PM:RF:ZERO_SUPPLY");
        vm.prank(strategyManager);
        poolManager.requestFunds(strategyManager, 1);
    }

    function test_requestFunds_revert_invalidStrategyOrManager_neitherMapping() external {
        poolManager.__setIsStrategy(strategy, false);
        poolManager.__setIsStrategyManager(strategyManager, false);

        vm.expectRevert("PM:RF:INVALID_STRATEGY_OR_MANAGER");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 1);

        vm.expectRevert("PM:RF:INVALID_STRATEGY_OR_MANAGER");
        vm.prank(strategyManager);
        poolManager.requestFunds(strategyManager, 1);
    }

    function test_requestFunds_revert_invalidStrategyOrManager_strategy_factoryNotRegistered() external {
        MockStrategy(strategy).__setFactory(makeAddr("Fake Factory"));

        vm.expectRevert("PM:RF:INVALID_STRATEGY_OR_MANAGER");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 1);
    }

    function test_requestFunds_revert_invalidStrategyOrManager_strategyManager_factoryNotRegistered() external {
        MockStrategy(strategyManager).__setFactory(makeAddr("Fake Factory"));

        vm.expectRevert("PM:RF:INVALID_STRATEGY_OR_MANAGER");
        vm.prank(strategyManager);
        poolManager.requestFunds(strategyManager, 1);
    }

    function test_requestFunds_revert_invalidStrategyOrManager_strategy_invalidInstance() external {
        MockFactory(strategyFactory).__setIsInstance(strategy, false);

        vm.expectRevert("PM:RF:INVALID_STRATEGY_OR_MANAGER");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 1);
    }

    function test_requestFunds_revert_invalidStrategyOrManager_strategyManager_invalidInstance() external {
        MockFactory(strategyManagerFactory).__setIsInstance(strategyManager, false);

        vm.expectRevert("PM:RF:INVALID_STRATEGY_OR_MANAGER");
        vm.prank(strategyManager);
        poolManager.requestFunds(strategyManager, 1);
    }

    function test_requestFunds_revert_invalidStrategyOrManager_strategy_factoryRegisteredAsManagerOnly() external {
        MockStrategy(strategy).__setFactory(strategyManagerFactory);

        vm.expectRevert("PM:RF:INVALID_STRATEGY_OR_MANAGER");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 1);
    }

    function test_requestFunds_revert_invalidStrategyOrManager_strategyManager_factoryRegisteredAsStrategyOnly() external {
        MockStrategy(strategyManager).__setFactory(strategyFactory);

        vm.expectRevert("PM:RF:INVALID_STRATEGY_OR_MANAGER");
        vm.prank(strategyManager);
        poolManager.requestFunds(strategyManager, 1);
    }

    function test_requestFunds_revert_invalidStrategyOrManager_bothMappingsTrue_strategyManagerTakesPrecedence() external {
        poolManager.__setIsStrategyManager(strategy, true);

        assertEq(poolManager.isStrategy(strategy),        true);
        assertEq(poolManager.isStrategyManager(strategy), true);

        assertEq(MockGlobals(globals).isInstanceOf("STRATEGY_FACTORY",         strategyFactory), true);
        assertEq(MockGlobals(globals).isInstanceOf("STRATEGY_MANAGER_FACTORY", strategyFactory), false);

        vm.expectRevert("PM:RF:INVALID_STRATEGY_OR_MANAGER");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 1);
    }

    function test_requestFunds_revert_strategyCap() external {
        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(strategy, 0);

        vm.expectRevert("PM:RF:STRATEGY_CAP");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 1);

        MockStrategy(strategy).__setAssetsUnderManagement(400e18);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(strategy, 1000e18);

        vm.expectRevert("PM:RF:STRATEGY_CAP");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 600e18 + 1);
    }

    function test_requestFunds_revert_strategyCap_strategyManager() external {
        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(strategyManager, 0);

        vm.expectRevert("PM:RF:STRATEGY_CAP");
        vm.prank(strategyManager);
        poolManager.requestFunds(strategyManager, 1);

        MockStrategy(strategyManager).__setAssetsOf(address(poolManager), 400e18);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(strategyManager, 1000e18);

        vm.expectRevert("PM:RF:STRATEGY_CAP");
        vm.prank(strategyManager);
        poolManager.requestFunds(strategyManager, 600e18 + 1);
    }

    function test_requestFunds_revert_transferFail() external {
        asset.burn(address(pool), asset.balanceOf(address(pool)));

        vm.expectRevert("PM:RF:TRANSFER_FAIL");
        vm.prank(strategy);
        poolManager.requestFunds(strategy, 1);

        vm.expectRevert("PM:RF:TRANSFER_FAIL");
        vm.prank(strategyManager);
        poolManager.requestFunds(strategyManager, 1);
    }

    function test_requestFunds_success_strategy() external {
        uint256 initialPoolBalance = 1_000_000e18;
        uint256 requestAmount      = 1_000e18;

        assertEq(asset.balanceOf(address(pool)), initialPoolBalance);
        assertEq(asset.balanceOf(strategy),      0);
        assertEq(asset.balanceOf(destination),   0);

        vm.prank(strategy);
        poolManager.requestFunds(destination, requestAmount);

        assertEq(asset.balanceOf(address(pool)), initialPoolBalance - requestAmount);
        assertEq(asset.balanceOf(strategy),      0);
        assertEq(asset.balanceOf(destination),   requestAmount);
    }

    function test_requestFunds_success_strategyManager() external {
        uint256 initialPoolBalance = 1_000_000e18;
        uint256 requestAmount      = 1_000e18;

        assertEq(asset.balanceOf(address(pool)),   initialPoolBalance);
        assertEq(asset.balanceOf(strategyManager), 0);
        assertEq(asset.balanceOf(destination),     0);

        vm.prank(strategyManager);
        poolManager.requestFunds(destination, requestAmount);

        assertEq(asset.balanceOf(address(pool)),   initialPoolBalance - requestAmount);
        assertEq(asset.balanceOf(strategyManager), 0);
        assertEq(asset.balanceOf(destination),     requestAmount);
    }

    function test_requestFunds_success_strategy_multipleRequests_fillsCap() external {
        uint256 initialPoolBalance = 1_000_000e18;
        uint256 cap                = 1_000e18;
        uint256 firstRequest       = 400e18;
        uint256 secondRequest      = cap - firstRequest;

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(strategy, cap);

        assertEq(asset.balanceOf(address(pool)), initialPoolBalance);
        assertEq(asset.balanceOf(destination),   0);
        assertEq(asset.balanceOf(strategy),      0);

        vm.prank(strategy);
        poolManager.requestFunds(destination, firstRequest);

        assertEq(asset.balanceOf(address(pool)), initialPoolBalance - firstRequest);
        assertEq(asset.balanceOf(destination),   firstRequest);
        assertEq(asset.balanceOf(strategy),      0);

        MockStrategy(strategy).__setAssetsUnderManagement(firstRequest);

        vm.prank(strategy);
        poolManager.requestFunds(destination, secondRequest);

        assertEq(asset.balanceOf(address(pool)), initialPoolBalance - cap);
        assertEq(asset.balanceOf(destination),   cap);
        assertEq(asset.balanceOf(strategy),      0);
    }

    function test_requestFunds_success_strategyManager_multipleRequests_fillsCap() external {
        uint256 initialPoolBalance = 1_000_000e18;
        uint256 cap                = 1_000e18;
        uint256 firstRequest       = 400e18;
        uint256 secondRequest      = cap - firstRequest;

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(strategyManager, cap);

        assertEq(asset.balanceOf(address(pool)),   initialPoolBalance);
        assertEq(asset.balanceOf(destination),     0);
        assertEq(asset.balanceOf(strategyManager), 0);

        vm.prank(strategyManager);
        poolManager.requestFunds(destination, firstRequest);

        assertEq(asset.balanceOf(address(pool)),   initialPoolBalance - firstRequest);
        assertEq(asset.balanceOf(destination),     firstRequest);
        assertEq(asset.balanceOf(strategyManager), 0);

        MockStrategy(strategyManager).__setAssetsOf(address(poolManager), firstRequest);

        vm.prank(strategyManager);
        poolManager.requestFunds(destination, secondRequest);

        assertEq(asset.balanceOf(address(pool)),   initialPoolBalance - cap);
        assertEq(asset.balanceOf(destination),     cap);
        assertEq(asset.balanceOf(strategyManager), 0);
    }

    function test_requestFunds_success_multipleStrategies_independentCaps() external {
        uint256 initialPoolBalance = 1_000_000e18;
        uint256 strategyCap        = 300e18;
        uint256 strategyManagerCap = 700e18;

        vm.startPrank(POOL_DELEGATE);
        poolManager.setStrategyCap(strategy,        strategyCap);
        poolManager.setStrategyCap(strategyManager, strategyManagerCap);
        vm.stopPrank();

        assertEq(asset.balanceOf(address(pool)),   initialPoolBalance);
        assertEq(asset.balanceOf(destination),     0);
        assertEq(asset.balanceOf(strategy),        0);
        assertEq(asset.balanceOf(strategyManager), 0);

        vm.prank(strategy);
        poolManager.requestFunds(destination, strategyCap);

        assertEq(asset.balanceOf(address(pool)),   initialPoolBalance - strategyCap);
        assertEq(asset.balanceOf(destination),     strategyCap);
        assertEq(asset.balanceOf(strategy),        0);
        assertEq(asset.balanceOf(strategyManager), 0);

        vm.prank(strategyManager);
        poolManager.requestFunds(destination, strategyManagerCap);

        assertEq(asset.balanceOf(address(pool)),   initialPoolBalance - strategyCap - strategyManagerCap);
        assertEq(asset.balanceOf(destination),     strategyCap + strategyManagerCap);
        assertEq(asset.balanceOf(strategy),        0);
        assertEq(asset.balanceOf(strategyManager), 0);
    }

    // TODO: Consider deleting this and similar tests once addStrategy and addStrategyManager are done
    function test_requestFunds_success_bothMappingsTrue_managerPathWins() external {
        // This test is not realistic but shows that if both mappings are true PM is giving advantage on modular strategy flow.
        uint256 initialPoolBalance = 1_000_000e18;
        uint256 cap                = 1_000e18;

        poolManager.__setIsStrategyManager(strategy, true);

        MockGlobals(globals).setValidInstance("STRATEGY_MANAGER_FACTORY", strategyFactory, true);

        MockStrategy(strategy).__setAssetsUnderManagement(900e18);
        MockStrategy(strategy).__setAssetsOf(address(poolManager), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(strategy, cap);

        assertEq(asset.balanceOf(address(pool)), initialPoolBalance);
        assertEq(asset.balanceOf(destination),   0);
        assertEq(asset.balanceOf(strategy),      0);

        vm.prank(strategy);
        poolManager.requestFunds(destination, cap);

        assertEq(asset.balanceOf(address(pool)), initialPoolBalance - cap);
        assertEq(asset.balanceOf(destination),   cap);
        assertEq(asset.balanceOf(strategy),      0);
    }

    function test_requestFunds_success_strategy_realizedLosses_freesCapHeadroom() external {
        uint256 initialPoolBalance = 1_000_000e18;
        uint256 cap                = 1_000e18;
        uint256 lossAmount         = 400e18;
        uint256 secondRequest      = lossAmount;

        vm.prank(POOL_DELEGATE);
        poolManager.setStrategyCap(strategy, cap);

        assertEq(asset.balanceOf(address(pool)), initialPoolBalance);
        assertEq(asset.balanceOf(destination),   0);
        assertEq(asset.balanceOf(strategy),      0);

        vm.prank(strategy);
        poolManager.requestFunds(destination, cap);

        assertEq(asset.balanceOf(address(pool)), initialPoolBalance - cap);
        assertEq(asset.balanceOf(destination),   cap);
        assertEq(asset.balanceOf(strategy),      0);

        MockStrategy(strategy).__setAssetsUnderManagement(cap - lossAmount);

        vm.prank(strategy);
        poolManager.requestFunds(destination, secondRequest);

        assertEq(asset.balanceOf(address(pool)), initialPoolBalance - cap - secondRequest);
        assertEq(asset.balanceOf(destination),   cap + secondRequest);
        assertEq(asset.balanceOf(strategy),      0);
    }

}
