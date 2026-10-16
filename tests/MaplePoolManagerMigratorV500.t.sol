// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { Test } from "../modules/forge-std/src/Test.sol";
import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MaplePoolManager } from "../contracts/MaplePoolManager.sol";

import { MaplePoolManagerFactory } from "../contracts/proxy/MaplePoolManagerFactory.sol";
import { MaplePoolManagerInitializer } from "../contracts/proxy/MaplePoolManagerInitializer.sol";
import { MaplePoolManagerMigratorV500 } from "../contracts/proxy/MaplePoolManagerMigratorV500.sol";

import { MaplePoolManagerHarness } from "./utils/Harnesses.sol";

import { MockGlobals, MockStrategy } from "./utils/Mocks.sol";

abstract contract MaplePoolManagerMigratorV500TestBase is Test {

    address ftlmFactory     = makeAddr("ftlmFactory");
    address otlmFactory     = makeAddr("otlmFactory");
    address strategyFactory = makeAddr("strategyFactory");
    address governor        = makeAddr("governor");
    address poolDelegate    = makeAddr("poolDelegate");
    address securityAdmin   = makeAddr("securityAdmin");

    address asset   = address(new MockERC20("USD Coin", "USDC", 6));
    address globals = address(new MockGlobals(governor));

    MaplePoolManagerFactory factory;
    MaplePoolManagerHarness poolManager;

    function setUp() public virtual {
        MockGlobals(globals).setValidPoolAsset(asset, true);
        MockGlobals(globals).setValidPoolDelegate(poolDelegate, true);
        MockGlobals(globals).setValidPoolDeployer(address(this), true);
        MockGlobals(globals).setValidInstance("FT_LOAN_MANAGER_FACTORY", ftlmFactory, true);
        MockGlobals(globals).setValidInstance("OT_LOAN_MANAGER_FACTORY", otlmFactory, true);
        MockGlobals(globals).__setSecurityAdmin(securityAdmin);

        address implementationV1 = address(new MaplePoolManagerHarness());
        address implementationV2 = address(new MaplePoolManager());
        address initializer      = address(new MaplePoolManagerInitializer());
        address migrator         = address(new MaplePoolManagerMigratorV500());

        factory = new MaplePoolManagerFactory(globals);

        vm.startPrank(governor);
        factory.registerImplementation(1, implementationV1, initializer);
        factory.registerImplementation(2, implementationV2, initializer);
        factory.enableUpgradePath(1, 2, migrator);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        poolManager = MaplePoolManagerHarness(factory.createInstance(abi.encode(poolDelegate, asset, 0, "Maple Pool", "MP"), "salt"));
    }

    function _createAndAddStrategy(address factory_, uint256 aum_) private returns (address strategy_) {
        MockStrategy mockStrategy_ = new MockStrategy(address(0), address(0), address(0));

        mockStrategy_.__setFactory(factory_);
        mockStrategy_.__setAssetsUnderManagement(aum_);

        poolManager.__pushToStrategyList(address(mockStrategy_));
        poolManager.__setIsStrategy(address(mockStrategy_), true);

        strategy_ = address(mockStrategy_);
    }

    function createAndAddFixedTermLoanManager(uint256 aum_) internal returns (address loanManager_) {
        loanManager_ = _createAndAddStrategy(ftlmFactory, aum_);
    }

    function createAndAddOpenTermLoanManager(uint256 aum_) internal returns (address loanManager_) {
        loanManager_ = _createAndAddStrategy(otlmFactory, aum_);
    }

    function createAndAddStrategy(uint256 aum_) internal returns (address strategy_) {
        strategy_ = _createAndAddStrategy(strategyFactory, aum_);
    }

    function assertStrategyList(address[] memory expected_) internal {
        assertEq(poolManager.strategyListLength(), expected_.length);

        for (uint256 i_; i_ < expected_.length; ++i_) {
            assertEq(poolManager.strategyList(i_), expected_[i_]);
        }
    }

    function array(address a_) internal pure returns (address[] memory array_) {
        array_    = new address[](1);
        array_[0] = a_;
    }

    function array(address a_, address b_) internal pure returns (address[] memory array_) {
        array_    = new address[](2);
        array_[0] = a_;
        array_[1] = b_;
    }

    function array(address a_, address b_, address c_) internal pure returns (address[] memory array_) {
        array_    = new address[](3);
        array_[0] = a_;
        array_[1] = b_;
        array_[2] = c_;
    }

    function array(address a_, address b_, address c_, address d_) internal pure returns (address[] memory array_) {
        array_    = new address[](4);
        array_[0] = a_;
        array_[1] = b_;
        array_[2] = c_;
        array_[3] = d_;
    }

    function array(address a_, address b_, address c_, address d_, address e_, address f_) internal pure returns (address[] memory array_) {
        array_    = new address[](6);
        array_[0] = a_;
        array_[1] = b_;
        array_[2] = c_;
        array_[3] = d_;
        array_[4] = e_;
        array_[5] = f_;
    }

}

contract MigrateFailureTests is MaplePoolManagerMigratorV500TestBase {

    function test_migrate_revert_nonZeroAum_ftlm() external {
        createAndAddFixedTermLoanManager({
            aum_: 1
        });

        vm.prank(securityAdmin);
        vm.expectRevert("MPF:UI:FAILED");
        poolManager.upgrade(2, "");
    }

}

contract MigrateSuccessTests is MaplePoolManagerMigratorV500TestBase {

    function test_migrate_success_emptyStrategyList() external {
        assertEq(poolManager.strategyListLength(), 0);

        vm.prank(securityAdmin);
        poolManager.upgrade(2, "");

        assertEq(poolManager.strategyListLength(), 0);
    }

    function test_migrate_success_keepsOpenTermLoanManagers() external {
        address otlm1 = createAndAddOpenTermLoanManager({
            aum_: 0
        });
        address otlm2 = createAndAddOpenTermLoanManager({
            aum_: 1_000e6
        });
        address otlm3 = createAndAddOpenTermLoanManager({
            aum_: 42
        });

        assertStrategyList(array(otlm1, otlm2, otlm3));

        assertEq(poolManager.isStrategy(otlm1), true);
        assertEq(poolManager.isStrategy(otlm2), true);
        assertEq(poolManager.isStrategy(otlm3), true);

        vm.prank(securityAdmin);
        poolManager.upgrade(2, "");

        assertStrategyList(array(otlm1, otlm2, otlm3));

        assertEq(poolManager.isStrategy(otlm1), true);
        assertEq(poolManager.isStrategy(otlm2), true);
        assertEq(poolManager.isStrategy(otlm3), true);
    }

    function test_migrate_success_singleFixedTermLoanManager() external {
        address ftlm = createAndAddFixedTermLoanManager({
            aum_: 0
        });

        assertStrategyList(array(ftlm));

        assertEq(poolManager.isStrategy(ftlm), true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm);

        vm.prank(securityAdmin);
        poolManager.upgrade(2, "");

        assertStrategyList(new address[](0));

        assertEq(poolManager.isStrategy(ftlm), false);
    }

    function test_migrate_success_removesFixedTermLoanManagerKeepsOpenTerm() external {
        address otlm = createAndAddOpenTermLoanManager({
            aum_: 0
        });
        address ftlm = createAndAddFixedTermLoanManager({
            aum_: 0
        });

        assertStrategyList(array(otlm, ftlm));

        assertEq(poolManager.isStrategy(otlm), true);
        assertEq(poolManager.isStrategy(ftlm), true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm);

        vm.prank(securityAdmin);
        poolManager.upgrade(2, "");

        assertStrategyList(array(otlm));

        assertEq(poolManager.isStrategy(otlm), true);
        assertEq(poolManager.isStrategy(ftlm), false);
    }

    function test_migrate_success_multipleFixedTermLoanManagers() external {
        address ftlm1 = createAndAddFixedTermLoanManager({
            aum_: 0
        });
        address ftlm2 = createAndAddFixedTermLoanManager({
            aum_: 0
        });
        address otlm1 = createAndAddOpenTermLoanManager({
            aum_: 10_000e6
        });
        address otlm2 = createAndAddOpenTermLoanManager({
            aum_: 0
        });

        assertStrategyList(array(ftlm1, ftlm2, otlm1, otlm2));

        assertEq(poolManager.isStrategy(ftlm1), true);
        assertEq(poolManager.isStrategy(ftlm2), true);
        assertEq(poolManager.isStrategy(otlm1), true);
        assertEq(poolManager.isStrategy(otlm2), true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm2);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm1);

        vm.prank(securityAdmin);
        poolManager.upgrade(2, "");

        assertStrategyList(array(otlm1, otlm2));

        assertEq(poolManager.isStrategy(ftlm1), false);
        assertEq(poolManager.isStrategy(ftlm2), false);
        assertEq(poolManager.isStrategy(otlm1), true);
        assertEq(poolManager.isStrategy(otlm2), true);
    }

    function test_migrate_success_removesStrategy() external {
        address strategy = createAndAddStrategy({
            aum_: 0
        });

        assertStrategyList(array(strategy));

        assertEq(poolManager.isStrategy(strategy), true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(strategy);

        vm.prank(securityAdmin);
        poolManager.upgrade(2, "");

        assertStrategyList(new address[](0));

        assertEq(poolManager.isStrategy(strategy), false);
    }

    function test_migrate_success_removesStrategyWithNonZeroAum() external {
        address strategy = createAndAddStrategy({
            aum_: 1_000e6
        });

        assertStrategyList(array(strategy));

        assertEq(poolManager.isStrategy(strategy), true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(strategy);

        vm.prank(securityAdmin);
        poolManager.upgrade(2, "");

        assertStrategyList(new address[](0));

        assertEq(poolManager.isStrategy(strategy), false);
    }

    function test_migrate_success_removesAllRemovableStrategies() external {
        address aave = createAndAddStrategy({
            aum_: 0
        });
        address sky = createAndAddStrategy({
            aum_: 0
        });
        address ftlm = createAndAddFixedTermLoanManager({
            aum_: 0
        });

        assertStrategyList(array(aave, sky, ftlm));

        assertEq(poolManager.isStrategy(aave), true);
        assertEq(poolManager.isStrategy(sky),  true);
        assertEq(poolManager.isStrategy(ftlm), true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(sky);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(aave);

        vm.prank(securityAdmin);
        poolManager.upgrade(2, "");

        assertStrategyList(new address[](0));

        assertEq(poolManager.isStrategy(aave), false);
        assertEq(poolManager.isStrategy(sky),  false);
        assertEq(poolManager.isStrategy(ftlm), false);
    }

    function test_migrate_success_scramblesOrderOfSurvivingOpenTermLoanManagers() external {
        address otlm1 = createAndAddOpenTermLoanManager({
            aum_: 0
        });
        address aave = createAndAddStrategy({
            aum_: 0
        });
        address otlm2 = createAndAddOpenTermLoanManager({
            aum_: 0
        });
        address sky = createAndAddStrategy({
            aum_: 0
        });
        address ftlm = createAndAddFixedTermLoanManager({
            aum_: 0
        });
        address otlm3 = createAndAddOpenTermLoanManager({
            aum_: 0
        });

        assertStrategyList(array(otlm1, aave, otlm2, sky, ftlm, otlm3));

        assertEq(poolManager.isStrategy(otlm1), true);
        assertEq(poolManager.isStrategy(aave),  true);
        assertEq(poolManager.isStrategy(otlm2), true);
        assertEq(poolManager.isStrategy(sky),   true);
        assertEq(poolManager.isStrategy(ftlm),  true);
        assertEq(poolManager.isStrategy(otlm3), true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(sky);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(aave);

        vm.prank(securityAdmin);
        poolManager.upgrade(2, "");

        assertStrategyList(array(otlm1, otlm3, otlm2));

        assertEq(poolManager.isStrategy(otlm1), true);
        assertEq(poolManager.isStrategy(aave),  false);
        assertEq(poolManager.isStrategy(otlm2), true);
        assertEq(poolManager.isStrategy(sky),   false);
        assertEq(poolManager.isStrategy(ftlm),  false);
        assertEq(poolManager.isStrategy(otlm3), true);
    }

}
