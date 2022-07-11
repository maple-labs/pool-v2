// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";

import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { InvestmentManager } from "../contracts/interest/InvestmentManager.sol";

import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import { Pool }        from "../contracts/Pool.sol";
import { PoolManager } from "../contracts/PoolManager.sol";

import { MockGlobals, MockLoan, MockPoolCoverManager } from "./mocks/Mocks.sol";

/// @dev Suite of tests that use PoolManagers, Pools, InvestmentManagers and Factories
contract IntegrationTestBase is TestUtils {

    address GOVERNOR = address(new Address());
    address LP       = address(new Address());
    address PD       = address(new Address());
    address TREASURY = address(new Address());

    address implementation;
    address initializer;

    InvestmentManager    investmentManager;
    MockERC20            fundsAsset;
    MockERC20            collateralAsset;
    MockGlobals          globals;
    MockPoolCoverManager poolCover;
    Pool                 pool;
    PoolManager          poolManager;
    PoolManagerFactory   factory;

    function setUp() public virtual {
        collateralAsset = new MockERC20("COL", "COL", 18);
        globals         = new MockGlobals(GOVERNOR);
        factory         = new PoolManagerFactory(address(globals));
        fundsAsset      = new MockERC20("Asset", "AT", 18);
        implementation  = address(new PoolManager());
        initializer     = address(new PoolManagerInitializer());
        poolCover       = new MockPoolCoverManager();

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        globals.setValidPoolDelegate(PD, true);
        vm.stopPrank();

        ( poolManager, pool ) = _createManagerAndPool();
        investmentManager = new InvestmentManager(address(pool), address(poolManager));

        vm.startPrank(PD);
        poolManager.setInvestmentManager(address(investmentManager), true);
        poolManager.setPoolCoverManager(address(poolCover));
        poolManager.setLiquidityCap(type(uint256).max);
        poolManager.setAllowedLender(LP, true);
        vm.stopPrank();

        // Aditional Configuration
        globals.setTreasury(TREASURY);
    }

    function _createManagerAndPool() internal returns (PoolManager poolManager_, Pool pool_) {
        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), PD, address(fundsAsset), "Pool", "Pool");

        address poolManagerAddress = PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(PD)));

        poolManager_ = PoolManager(poolManagerAddress);
        pool_        = Pool(poolManager_.pool());
    }

    function _createFundAndDrawdownLoan(uint256 principalRequested_, uint256 collateralRequired_) internal returns (MockLoan loan){
        loan = new MockLoan(address(fundsAsset), address(collateralAsset), principalRequested_, collateralRequired_);

        vm.prank(PD);
        poolManager.fund(principalRequested_, address(loan), address(investmentManager));

        collateralAsset.mint(address(loan), collateralRequired_);

        loan.drawdownFunds(principalRequested_, address(this));
    }

    function _depositLP(address depositor_, uint256 amount_) internal returns (uint256 shares_) {
        fundsAsset.mint(depositor_, amount_);

        vm.startPrank(depositor_);
        fundsAsset.approve(address(pool), amount_);
        shares_ = pool.deposit(amount_, depositor_);
        vm.stopPrank();
    }

}

contract FeeDistributionTest is IntegrationTestBase {

    uint256 principalRequested = 1_000_000e18;
    uint256 managementFeeSplit = 0.30e18; // 30% to treasury
    uint256 managementFee      = 0.10e18;
    uint256 coverFee           = 0.20e18;

    function setUp() public override {
        super.setUp();

        globals.setManagementFeeSplit(address(pool), managementFeeSplit);

        vm.startPrank(PD);
        poolManager.setCoverFee(coverFee);
        poolManager.setManagementFee(managementFee);
        vm.stopPrank();
    }

    function test_feeDistribution() external {
        _depositLP(LP, principalRequested);

        MockLoan loan_ = _createFundAndDrawdownLoan(principalRequested, 0);

        vm.warp(loan_.nextPaymentDueDate());

        uint256 interestPayment = 1_000e18;

        // Simulate an interest payment
        fundsAsset.mint(address(loan_), interestPayment);
        loan_.__setClaimableFunds(interestPayment);

        assertEq(fundsAsset.balanceOf(address(loan_)),     interestPayment);
        assertEq(fundsAsset.balanceOf(address(pool)),      0);
        assertEq(fundsAsset.balanceOf(address(TREASURY)),  0);
        assertEq(fundsAsset.balanceOf(address(PD)),        0);
        assertEq(fundsAsset.balanceOf(address(poolCover)), 0);

        poolManager.claim(address(loan_));

        assertEq(fundsAsset.balanceOf(address(loan_)),     0);
        assertEq(fundsAsset.balanceOf(address(pool)),      700e18); // 70% of the interest paid
        assertEq(fundsAsset.balanceOf(address(TREASURY)),  30e18);  // 30% of 100e18 (10% of interest paid)
        assertEq(fundsAsset.balanceOf(address(PD)),        70e18);  // 70% of 100e18 (10% of interest paid)
        assertEq(fundsAsset.balanceOf(address(poolCover)), 200e18); // 20% of the interest paid
    }

}
