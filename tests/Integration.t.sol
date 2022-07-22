// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";

import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import { LoanManager } from "../contracts/LoanManager.sol";
import { Pool }        from "../contracts/Pool.sol";
import { PoolManager } from "../contracts/PoolManager.sol";

import { MockAuctioneer, MockGlobals, MockLoan, MockLiquidationStrategy, MockPoolCoverManager } from "./mocks/Mocks.sol";

/// @dev Suite of tests that use PoolManagers, Pools, LoanManagers and Factories
contract IntegrationTestBase is TestUtils {

    address GOVERNOR = address(new Address());
    address LP       = address(new Address());
    address PD       = address(new Address());
    address TREASURY = address(new Address());

    address implementation;
    address initializer;

    LoanManager          loanManager;
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
        loanManager = new LoanManager(address(pool), address(poolManager));

        vm.startPrank(PD);
        poolManager.setLoanManager(address(loanManager), true);
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
        loan = new MockLoan(address(collateralAsset), address(fundsAsset));

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
        loan_.__setNextPaymentDueDate(block.timestamp + 30 days);

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

contract LoanManagerTest is TestUtils {

    address LP       = address(new Address());
    address BORROWER = address(new Address());

    address implementation;
    address initializer;

    uint256 collateralPrice;

    LoanManager          loanManager;
    MockAuctioneer       auctioneer;
    MockERC20            fundsAsset;
    MockERC20            collateralAsset;
    MockGlobals          globals;
    MockPoolCoverManager poolCoverManager;
    Pool                 pool;
    PoolManager          poolManager;
    PoolManagerFactory   poolManagerFactory;

    function setUp() public virtual {
        collateralAsset   = new MockERC20("MockCollateral", "MC", 18);
        fundsAsset        = new MockERC20("MockToken",      "MT", 18);

        collateralPrice = 2;  // $2

        auctioneer = new MockAuctioneer(collateralPrice * 1e8, 1e8);  // Worth $2

        globals            = new MockGlobals(address(this));
        poolManagerFactory = new PoolManagerFactory(address(globals));

        implementation = address(new PoolManager());
        initializer    = address(new PoolManagerInitializer());

        globals.setValidPoolDelegate(address(this), true);

        poolManagerFactory.registerImplementation(1, implementation, initializer);
        poolManagerFactory.setDefaultVersion(1);

        poolManager = PoolManager(poolManagerFactory.createInstance(
            PoolManagerInitializer(initializer).encodeArguments(
                address(globals),
                address(this),
                address(fundsAsset),
                "POOL",
                "POOL-LP"
            ),
            keccak256(abi.encode(address(this)))
        ));

        pool             = Pool(poolManager.pool());
        poolCoverManager = new MockPoolCoverManager();

        loanManager = new LoanManager(address(pool), address(poolManager));

        poolManager.setLoanManager(address(loanManager), true);
        poolManager.setPoolCoverManager(address(poolCoverManager));
        poolManager.setLiquidityCap(type(uint256).max);
        poolManager.setOpenToPublic();
    }

    // TODO
    // function test_unrealizedLosses() external { }

    // TODO: Add auctioneer to this repo

    function test_liquidation_shortfall() external {
        uint256 principalRequested = 1_000_000_000e18;
        uint256 collateralRequired = principalRequested / collateralPrice / 2;  // 50% collateralized

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired);

        uint256 principalToCover = loan.principal();

        // NOTE: This is only possible because of MockLoan not using grace period logic.
        poolManager.triggerCollateralLiquidation(address(loan), address(auctioneer));

        (uint256 principal, address liquidator) = loanManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);
        assertEq(auctioneer.getExpectedAmount(collateralRequired), collateralRequired * collateralPrice);

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);

        // Perform Liquidation -- LoanManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(auctioneer));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  0);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      collateralRequired * collateralPrice);

        loanManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested / collateralPrice);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * collateralPrice);
    }

    function test_liquidation_equalToPrincipal() external {
        uint256 principalRequested = 1_000_000e18;
        uint256 collateralRequired = principalRequested / collateralPrice;

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired);

        uint256 principalToCover = loan.principal();

        // NOTE: This is only possible because of MockLoan not using grace period logic.
        poolManager.triggerCollateralLiquidation(address(loan), address(auctioneer));

        (uint256 principal, address liquidator) = loanManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);
        assertEq(auctioneer.getExpectedAmount(collateralRequired), collateralRequired * collateralPrice);

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);

        // Perform Liquidation -- LoanManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(auctioneer));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  0);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      collateralRequired * collateralPrice);

        loanManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * collateralPrice);
    }

    function test_liquidation_greaterThanPrincipal() external {
        uint256 principalRequested = 1_000_000e18;
        uint256 collateralRequired = principalRequested;

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired);

        uint256 principalToCover = loan.principal();

        // NOTE: This is only possible because of MockLoan not using grace period logic.
        poolManager.triggerCollateralLiquidation(address(loan), address(auctioneer));

        (uint256 principal, address liquidator) = loanManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);
        assertEq(auctioneer.getExpectedAmount(collateralRequired), collateralRequired * collateralPrice);

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);

        // Perform Liquidation -- LoanManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(auctioneer));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  0);
        assertEq(fundsAsset.balanceOf(address(loan)),             0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),       0);
        assertEq(fundsAsset.balanceOf(address(loanManager)),      collateralRequired * collateralPrice);

        loanManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested * collateralPrice);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * collateralPrice);
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

    function _createFundAndDrawdownLoan(uint256 principalRequested_, uint256 collateralRequired_) internal returns (MockLoan loan){
        loan = new MockLoan(address(collateralAsset), address(fundsAsset));

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
