// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { Test }      from "../modules/forge-std/src/Test.sol";
import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MaplePoolManager } from "../contracts/MaplePoolManager.sol";

import { MaplePoolManagerFactory }      from "../contracts/proxy/MaplePoolManagerFactory.sol";
import { MaplePoolManagerInitializer }  from "../contracts/proxy/MaplePoolManagerInitializer.sol";
import { MaplePoolManagerMigratorV500 } from "../contracts/proxy/MaplePoolManagerMigratorV500.sol";

import { MaplePoolManagerHarness } from "./harnesses/MaplePoolManagerHarness.sol";

import { MockGlobals, MockStrategy } from "./mocks/Mocks.sol";

abstract contract MaplePoolManagerMigratorV500TestBase is Test {

    address ftlmFactory    = makeAddr("ftlmFactory");
    address governor       = makeAddr("governor");
    address nonFtlmFactory = makeAddr("nonFtlmFactory");
    address poolDelegate   = makeAddr("poolDelegate");

    address asset   = address(new MockERC20("USD Coin", "USDC", 6));
    address globals = address(new MockGlobals(governor));

    MaplePoolManagerFactory factory;
    MaplePoolManagerHarness poolManager;

    function setUp() public virtual {
        MockGlobals(globals).setValidPoolAsset(asset, true);
        MockGlobals(globals).setValidPoolDelegate(poolDelegate, true);
        MockGlobals(globals).setValidPoolDeployer(address(this), true);
        MockGlobals(globals).setValidInstance("FT_LOAN_MANAGER_FACTORY", ftlmFactory, true);
        MockGlobals(globals).__setIsValidScheduledCall(true);

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

        poolManager = MaplePoolManagerHarness(factory.createInstance(
            abi.encode(poolDelegate, asset, 0, "Maple Pool", "MP"),
            "salt"
        ));
    }

    function createAndAddStrategy(bool isFixedTermLoan_, uint256 aum_) internal returns (address strategy_) {
        MockStrategy mockStrategy_ = new MockStrategy(address(0), address(0), address(0));

        mockStrategy_.__setFactory(isFixedTermLoan_ ? ftlmFactory : nonFtlmFactory);
        mockStrategy_.__setAssetsUnderManagement(aum_);

        poolManager.__pushToStrategyList(address(mockStrategy_));
        poolManager.__setIsStrategy(address(mockStrategy_), true);

        strategy_ = address(mockStrategy_);
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

}

contract MigrateFailureTests is MaplePoolManagerMigratorV500TestBase {

    function test_migrate_revert_nonZeroAum() external {
        createAndAddStrategy({ isFixedTermLoan_: true, aum_: 1 });

        vm.prank(poolDelegate);
        vm.expectRevert("MPF:UI:FAILED");
        poolManager.upgrade(2, "");
    }

}

contract MigrateSuccessTests is MaplePoolManagerMigratorV500TestBase {

    function test_migrate_success_emptyStrategyList() external {
        assertEq(poolManager.strategyListLength(), 0);

        vm.prank(poolDelegate);
        poolManager.upgrade(2, "");

        assertEq(poolManager.strategyListLength(), 0);
    }

    function test_migrate_success_onlyNonFtlms() external {
        address strategy1 = createAndAddStrategy({ isFixedTermLoan_: false, aum_: 0 });
        address strategy2 = createAndAddStrategy({ isFixedTermLoan_: false, aum_: 1_000e6 });
        address strategy3 = createAndAddStrategy({ isFixedTermLoan_: false, aum_: 42 });

        assertStrategyList(array(strategy1, strategy2, strategy3));

        assertEq(poolManager.isStrategy(strategy1), true);
        assertEq(poolManager.isStrategy(strategy2), true);
        assertEq(poolManager.isStrategy(strategy3), true);

        vm.prank(poolDelegate);
        poolManager.upgrade(2, "");

        assertStrategyList(array(strategy1, strategy2, strategy3));

        assertEq(poolManager.isStrategy(strategy1), true);
        assertEq(poolManager.isStrategy(strategy2), true);
        assertEq(poolManager.isStrategy(strategy3), true);
    }

    function test_migrate_success_singleFtlm() external {
        address ftlm = createAndAddStrategy({ isFixedTermLoan_: true, aum_: 0 });

        assertStrategyList(array(ftlm));

        assertEq(poolManager.isStrategy(ftlm), true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm);

        vm.prank(poolDelegate);
        poolManager.upgrade(2, "");

        assertStrategyList(new address[](0));

        assertEq(poolManager.isStrategy(ftlm), false);
    }

    function test_migrate_success_removesFtlmKeepsNonFtlm() external {
        address nonFtlm = createAndAddStrategy({ isFixedTermLoan_: false, aum_: 0 });
        address ftlm    = createAndAddStrategy({ isFixedTermLoan_: true,  aum_: 0 });

        assertStrategyList(array(nonFtlm, ftlm));

        assertEq(poolManager.isStrategy(nonFtlm), true);
        assertEq(poolManager.isStrategy(ftlm),    true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm);

        vm.prank(poolDelegate);
        poolManager.upgrade(2, "");

        assertStrategyList(array(nonFtlm));

        assertEq(poolManager.isStrategy(nonFtlm), true);
        assertEq(poolManager.isStrategy(ftlm),    false);
    }

    function test_migrate_success_orderNotPreserved() external {
        address nonFtlm1 = createAndAddStrategy({ isFixedTermLoan_: false, aum_: 0 });
        address ftlm     = createAndAddStrategy({ isFixedTermLoan_: true,  aum_: 0 });
        address nonFtlm2 = createAndAddStrategy({ isFixedTermLoan_: false, aum_: 0 });
        address nonFtlm3 = createAndAddStrategy({ isFixedTermLoan_: false, aum_: 0 });

        assertStrategyList(array(nonFtlm1, ftlm, nonFtlm2, nonFtlm3));

        assertEq(poolManager.isStrategy(nonFtlm1), true);
        assertEq(poolManager.isStrategy(ftlm),     true);
        assertEq(poolManager.isStrategy(nonFtlm2), true);
        assertEq(poolManager.isStrategy(nonFtlm3), true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm);

        vm.prank(poolDelegate);
        poolManager.upgrade(2, "");

        assertStrategyList(array(nonFtlm1, nonFtlm3, nonFtlm2));

        assertEq(poolManager.isStrategy(nonFtlm1), true);
        assertEq(poolManager.isStrategy(ftlm),     false);
        assertEq(poolManager.isStrategy(nonFtlm2), true);
        assertEq(poolManager.isStrategy(nonFtlm3), true);
    }

    function test_migrate_success_multipleFtlms() external {
        address ftlm1    = createAndAddStrategy({ isFixedTermLoan_: true,  aum_: 0 });
        address ftlm2    = createAndAddStrategy({ isFixedTermLoan_: true,  aum_: 0 });
        address nonFtlm1 = createAndAddStrategy({ isFixedTermLoan_: false, aum_: 10_000e6 });
        address nonFtlm2 = createAndAddStrategy({ isFixedTermLoan_: false, aum_: 0 });

        assertStrategyList(array(ftlm1, ftlm2, nonFtlm1, nonFtlm2));

        assertEq(poolManager.isStrategy(ftlm1),    true);
        assertEq(poolManager.isStrategy(ftlm2),    true);
        assertEq(poolManager.isStrategy(nonFtlm1), true);
        assertEq(poolManager.isStrategy(nonFtlm2), true);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm2);

        vm.expectEmit();
        emit MaplePoolManagerMigratorV500.StrategyRemoved(ftlm1);

        vm.prank(poolDelegate);
        poolManager.upgrade(2, "");

        assertStrategyList(array(nonFtlm1, nonFtlm2));

        assertEq(poolManager.isStrategy(ftlm1),    false);
        assertEq(poolManager.isStrategy(ftlm2),    false);
        assertEq(poolManager.isStrategy(nonFtlm1), true);
        assertEq(poolManager.isStrategy(nonFtlm2), true);
    }

}
