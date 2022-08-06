// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { LoanManagerFactory }     from "../contracts/proxy/LoanManagerFactory.sol";
import { LoanManagerInitializer } from "../contracts/proxy/LoanManagerInitializer.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import { LoanManager } from "../contracts/LoanManager.sol";
import { Pool }        from "../contracts/Pool.sol";
import { PoolManager } from "../contracts/PoolManager.sol";

import { MockGlobals, MockLoan, MockLiquidationStrategy } from "./mocks/Mocks.sol";

/* TODO: Need to update final accounting to reflect realized losses.
    // 1m loan
    // 100k collateral
    // 200k cover
    // TA:  1m
    // TAL: 1m
    // trigger: 1m unrealized loss
    // TA:  1m
    // TAL: 0
    // finish step 1: 900k unrealized loss
    // TA:  1m
    // TAL: 100k (cash)
    // finish step 2: 700k unrealized loss
    // TA:  1m (outstanding principal)
    // TAL: 300k (cash)
    // finish step 3: Update final accounting
    // TA:  300k
    // TAL: 300k
*/

import { GlobalsBootstrapper } from "./bootstrap/GlobalsBootstrapper.sol";

/// @dev Suite of tests that use PoolManagers, Pools, LoanManagers and Factories
contract IntegrationTestBase is TestUtils, GlobalsBootstrapper {

    address BORROWER = address(new Address());
    address LP       = address(new Address());
    address PD       = address(new Address());

    address loanManagerImplementation = address(new LoanManager());
    address loanManagerInitializer    = address(new LoanManagerInitializer());

    address poolManagerImplementation = address(new PoolManager());
    address poolManagerInitializer    = address(new PoolManagerInitializer());

    MockERC20 collateralAsset;
    MockERC20 fundsAsset;

    LoanManager        loanManager;
    LoanManagerFactory loanManagerFactory;

    Pool               pool;
    PoolManager        poolManager;
    PoolManagerFactory poolManagerFactory;

    function setUp() public virtual {
        collateralAsset = new MockERC20("COL", "COL", 18);
        fundsAsset      = new MockERC20("Asset", "AT", 18);

        _deployAndBootstrapGlobals(address(fundsAsset), PD);

        vm.startPrank(GOVERNOR);
        poolManagerFactory = new PoolManagerFactory(address(globals));
        poolManagerFactory.registerImplementation(1, poolManagerImplementation, poolManagerInitializer);
        poolManagerFactory.setDefaultVersion(1);
        vm.stopPrank();

        vm.startPrank(GOVERNOR);
        loanManagerFactory = new LoanManagerFactory(address(globals));
        loanManagerFactory.registerImplementation(1, loanManagerImplementation, loanManagerInitializer);
        loanManagerFactory.setDefaultVersion(1);
        vm.stopPrank();

        ( pool, poolManager, loanManager ) = _createPoolAndManagers();

        vm.startPrank(PD);
        poolManager.addLoanManager(address(loanManager));
        poolManager.setLiquidityCap(type(uint256).max);
        poolManager.setAllowedLender(LP, true);
        vm.stopPrank();

    }

    function _createPoolAndManagers() internal returns (Pool pool_, PoolManager poolManager_, LoanManager loanManager_) {
        MockGlobals(globals).setValidPoolDeployer(address(this), true);

        bytes memory arguments = PoolManagerInitializer(poolManagerInitializer).encodeArguments(address(globals), PD, address(fundsAsset), "Pool", "Pool");
        address poolManagerAddress = PoolManagerFactory(poolManagerFactory).createInstance(arguments, "");

        poolManager_ = PoolManager(poolManagerAddress);
        pool_        = Pool(poolManager_.pool());

        arguments    = LoanManagerInitializer(loanManagerInitializer).encodeArguments(address(pool_));
        loanManager_ = LoanManager(LoanManagerFactory(loanManagerFactory).createInstance(arguments, ""));
    }

    function _createFundAndDrawdownLoan(uint256 principalRequested_, uint256 collateralRequired_) internal returns (MockLoan loan) {
        loan = new MockLoan(address(collateralAsset), address(fundsAsset));

        loan.__setBorrower(BORROWER);

        loan.__setPrincipalRequested(principalRequested_);
        loan.__setCollateralRequired(collateralRequired_);
        loan.__setNextPaymentDueDate(block.timestamp + 30 days);

        vm.prank(PD);
        poolManager.fund(principalRequested_, address(loan), address(loanManager));

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

    function setUp() public override {
        super.setUp();

        MockGlobals(globals).setManagementFeeSplit(address(pool), managementFeeSplit);
        MockGlobals(globals).setValidBorrower(BORROWER, true);

        vm.startPrank(PD);
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
        loan_.__setNextPaymentDueDate(block.timestamp + 30 days);

        assertEq(fundsAsset.balanceOf(address(loan_)),     interestPayment);
        assertEq(fundsAsset.balanceOf(address(pool)),      0);
        assertEq(fundsAsset.balanceOf(address(TREASURY)),  0);
        assertEq(fundsAsset.balanceOf(address(PD)),        0);

        poolManager.claim(address(loan_));

        assertEq(fundsAsset.balanceOf(address(loan_)),     0);
        assertEq(fundsAsset.balanceOf(address(pool)),      900e18); // 10% of the interest paid
        assertEq(fundsAsset.balanceOf(address(TREASURY)),  30e18);  // 30% of 100e18 (10% of interest paid)
        assertEq(fundsAsset.balanceOf(address(PD)),        70e18);  // 70% of 100e18 (10% of interest paid)
    }

}

contract LoanManagerTest is TestUtils, GlobalsBootstrapper {

    address LP       = address(new Address());
    address BORROWER = address(new Address());

    address loanManagerImplementation = address(new LoanManager());
    address loanManagerInitializer    = address(new LoanManagerInitializer());

    address poolManagerImplementation = address(new PoolManager());
    address poolManagerInitializer    = address(new PoolManagerInitializer());

    uint256 COLLATERAL_PRICE = 2;
    uint256 FUNDS_PRICE      = 1;

    address implementation;
    address initializer;

    LoanManager        loanManager;
    LoanManagerFactory loanManagerFactory;
    MockERC20          fundsAsset;
    MockERC20          collateralAsset;
    Pool               pool;
    PoolManager        poolManager;
    PoolManagerFactory poolManagerFactory;

    function setUp() public virtual {
        collateralAsset = new MockERC20("MockCollateral", "MC", 18);
        fundsAsset      = new MockERC20("MockToken",      "MT", 18);

        _deployAndBootstrapGlobals(address(fundsAsset), address(this));

        poolManagerFactory = new PoolManagerFactory(address(globals));

        implementation = address(new PoolManager());
        initializer    = address(new PoolManagerInitializer());

        MockGlobals(globals).setValidBorrower(BORROWER, true);

        vm.startPrank(GOVERNOR);
        poolManagerFactory = new PoolManagerFactory(address(globals));
        poolManagerFactory.registerImplementation(1, poolManagerImplementation, poolManagerInitializer);
        poolManagerFactory.setDefaultVersion(1);

        loanManagerFactory = new LoanManagerFactory(address(globals));
        loanManagerFactory.registerImplementation(1, loanManagerImplementation, loanManagerInitializer);
        loanManagerFactory.setDefaultVersion(1);
        vm.stopPrank();

        MockGlobals(globals).setValidPoolDeployer(address(this), true);

        poolManager = PoolManager(poolManagerFactory.createInstance(
            PoolManagerInitializer(poolManagerInitializer).encodeArguments(
                address(globals),
                address(this),
                address(fundsAsset),
                "POOL",
                "POOL-LP"
            ),
            keccak256(abi.encode(address(this)))
        ));

        pool = Pool(poolManager.pool());

        loanManager = LoanManager(LoanManagerFactory(loanManagerFactory).createInstance(
            LoanManagerInitializer(loanManagerInitializer).encodeArguments(
                address(pool)
            ),
            keccak256(abi.encode(address(this)))
        ));

        poolManager.addLoanManager(address(loanManager));
        poolManager.setLiquidityCap(type(uint256).max);
        poolManager.setOpenToPublic();

        MockGlobals(globals).setLatestPrice(address(fundsAsset),      FUNDS_PRICE);
        MockGlobals(globals).setLatestPrice(address(collateralAsset), COLLATERAL_PRICE);
    }

    // TODO: function test_unrealizedLosses() external { }

    function test_liquidation_shortfall() external {
        uint256 principalRequested = 1_000_000_000e18;
        uint256 collateralRequired = principalRequested / COLLATERAL_PRICE / 2;  // 50% collateralized

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired);

        uint256 principalToCover = loan.principal();

        // NOTE: This is only possible because of MockLoan not using grace period logic.
        poolManager.triggerCollateralLiquidation(address(loan));

        (uint256 principal, address liquidator ) = loanManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);

        assertEq(loanManager.getExpectedAmount(address(collateralAsset), collateralRequired), collateralRequired * COLLATERAL_PRICE);

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);

        // Perform Liquidation -- LoanManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(loanManager));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset), address(loan));

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  0);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      collateralRequired * COLLATERAL_PRICE);

        poolManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested / COLLATERAL_PRICE);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * COLLATERAL_PRICE);
    }

    function test_liquidation_equalToPrincipal() external {
        uint256 principalRequested = 1_000_000e18;
        uint256 collateralRequired = principalRequested / COLLATERAL_PRICE;

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired);

        uint256 principalToCover = loan.principal();

        // NOTE: This is only possible because of MockLoan not using grace period logic.
        poolManager.triggerCollateralLiquidation(address(loan));

        (uint256 principal, address liquidator ) = loanManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);

        assertEq(loanManager.getExpectedAmount(address(collateralAsset), collateralRequired), collateralRequired * COLLATERAL_PRICE);

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);

        // Perform Liquidation -- LoanManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(loanManager));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset), address(loan));

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  0);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      collateralRequired * COLLATERAL_PRICE);

        poolManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * COLLATERAL_PRICE);
    }

    function test_liquidation_greaterThanPrincipal() external {
        uint256 principalRequested = 1_000_000e18;
        uint256 collateralRequired = principalRequested;

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired);

        uint256 principalToCover = loan.principal();

        // NOTE: This is only possible because of MockLoan not using grace period logic.
        poolManager.triggerCollateralLiquidation(address(loan));

        (uint256 principal, address liquidator ) = loanManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);

        assertEq(loanManager.getExpectedAmount(address(collateralAsset), collateralRequired), collateralRequired * COLLATERAL_PRICE);

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);

        // Perform Liquidation -- LoanManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(loanManager));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset), address(loan));

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  0);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      collateralRequired * COLLATERAL_PRICE);

        poolManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested * COLLATERAL_PRICE);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * COLLATERAL_PRICE);
    }

    /************************/
    /*** Internal Helpers ***/
    /************************/

    function _mintAndDeposit(uint256 amount_) internal {
        address depositor = address(1);  // Use a non-address(this) address for deposit
        fundsAsset.mint(depositor, amount_);
        vm.startPrank(depositor);
        fundsAsset.approve(address(pool), amount_);
        pool.deposit(amount_, address(this));
        vm.stopPrank();
    }

    function _createFundAndDrawdownLoan(uint256 principalRequested_, uint256 collateralRequired_) internal returns (MockLoan loan) {
        loan = new MockLoan(address(collateralAsset), address(fundsAsset));

        loan.__setBorrower(BORROWER);

        loan.__setPrincipalRequested(principalRequested_);
        loan.__setCollateralRequired(collateralRequired_);
        loan.__setNextPaymentDueDate(block.timestamp + 30 days);

        loan.__setPrincipal(principalRequested_);
        loan.__setCollateral(collateralRequired_);

        poolManager.fund(principalRequested_, address(loan), address(loanManager));

        collateralAsset.mint(address(loan), collateralRequired_);

        loan.drawdownFunds(principalRequested_, address(this));
    }

}
