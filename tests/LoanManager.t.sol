
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                   from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import {
    MockAuctioneer,
    MockGlobals,
    MockLiquidationStrategy,
    MockLoan,
    MockPool,
    MockPoolCoverManager
} from "./mocks/Mocks.sol";

import { LoanManager } from "../contracts/interest/LoanManager.sol";
import { Pool }        from "../contracts/Pool.sol";
import { PoolManager } from "../contracts/PoolManager.sol";

import { LoanManagerHarness } from "./harnesses/LoanManagerHarness.sol";

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
        loan = new MockLoan(address(fundsAsset), address(collateralAsset), principalRequested_, collateralRequired_);

        poolManager.fund(principalRequested_, address(loan), address(loanManager));

        collateralAsset.mint(address(loan), collateralRequired_);

        loan.drawdownFunds(principalRequested_, address(this));
    }

}

contract LoanManagerSortingTests is TestUtils {

    LoanManagerHarness loanManager;

    LoanManagerHarness.LoanInfo earliestLoan;
    LoanManagerHarness.LoanInfo latestLoan;
    LoanManagerHarness.LoanInfo medianLoan;
    LoanManagerHarness.LoanInfo synchronizedLoan;

    function setUp() public {
        loanManager = new LoanManagerHarness(address(new MockPool()), address(0));

        earliestLoan.vehicle     = address(new Address());
        medianLoan.vehicle       = address(new Address());
        synchronizedLoan.vehicle = address(new Address());
        latestLoan.vehicle       = address(new Address());

        earliestLoan.paymentDueDate     = 10;
        medianLoan.paymentDueDate       = 20;
        synchronizedLoan.paymentDueDate = 20;
        latestLoan.paymentDueDate       = 30;
    }

    /**********************/
    /*** Add Investment ***/
    /**********************/

    function test_addLoan_single() external {
        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);
    }

    function test_addLoan_ascendingPair() external {
        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoan(latestLoan);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   2);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);
    }

    function test_addLoan_descendingPair() external {
        loanManager.addLoan(latestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(latestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 2);

        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   1);
        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 2);

        assertEq(loanManager.loan(1).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 2);

        assertEq(loanManager.loan(2).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(2).next,     1);
        assertEq(loanManager.loan(2).previous, 0);
    }

    function test_addLoan_synchronizedPair() external {
        loanManager.addLoan(medianLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(medianLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoan(synchronizedLoan);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(medianLoan.vehicle),       1);
        assertEq(loanManager.loanIdOf(synchronizedLoan.vehicle), 2);

        assertEq(loanManager.loan(1).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  synchronizedLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);
    }

    function test_addLoan_toHead() external {
        loanManager.addLoan(medianLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(medianLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoan(latestLoan);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(medianLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle), 2);

        assertEq(loanManager.loan(1).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);

        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    3);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 3);

        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   1);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   2);
        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 3);

        assertEq(loanManager.loan(1).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 3);

        assertEq(loanManager.loan(2).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);

        assertEq(loanManager.loan(3).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(3).next,     1);
        assertEq(loanManager.loan(3).previous, 0);
    }

    function test_addLoan_toMiddle() external {
        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoan(latestLoan);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   2);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);

        loanManager.addLoan(medianLoan);

        assertEq(loanManager.loanCounter(),                    3);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   2);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   3);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     3);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 3);

        assertEq(loanManager.loan(3).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(3).next,     2);
        assertEq(loanManager.loan(3).previous, 1);
    }

    function test_addLoan_toTail() external {
        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoan(medianLoan);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   2);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);

        loanManager.addLoan(latestLoan);

        assertEq(loanManager.loanCounter(),                    3);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   2);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   3);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(2).next,     3);
        assertEq(loanManager.loan(2).previous, 1);

        assertEq(loanManager.loan(3).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(3).next,     0);
        assertEq(loanManager.loan(3).previous, 2);
    }

    /*************************/
    /*** Remove Investment ***/
    /*************************/

    function test_removeLoan_invalidAddress() external {
        address nonExistingVehicle = address(new Address());

        vm.expectRevert(ZERO_DIVISION);
        loanManager.removeLoan(nonExistingVehicle);
    }

    function test_removeLoan_single() external {
        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.removeLoan(earliestLoan.vehicle);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 0);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 0);

        assertEq(loanManager.loan(1).vehicle,  address(0));
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);
    }

    function test_removeLoan_pair() external {
        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoan(latestLoan);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   2);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);

        loanManager.removeLoan(earliestLoan.vehicle);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 2);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 0);

        assertEq(loanManager.loan(1).vehicle,  address(0));
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 0);
    }

    function test_removeLoan_earliestDueDate() external {
        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoan(medianLoan);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   2);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);

        loanManager.addLoan(latestLoan);

        assertEq(loanManager.loanCounter(),                    3);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   2);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   3);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(2).next,     3);
        assertEq(loanManager.loan(2).previous, 1);

        assertEq(loanManager.loan(3).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(3).next,     0);
        assertEq(loanManager.loan(3).previous, 2);

        loanManager.removeLoan(earliestLoan.vehicle);

        assertEq(loanManager.loanCounter(),                    3);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 2);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 0);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   2);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   3);

        assertEq(loanManager.loan(1).vehicle,  address(0));
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(2).next,     3);
        assertEq(loanManager.loan(2).previous, 0);

        assertEq(loanManager.loan(3).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(3).next,     0);
        assertEq(loanManager.loan(3).previous, 2);
    }

    function test_removeLoan_medianDueDate() external {
        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoan(medianLoan);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   2);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);

        loanManager.addLoan(latestLoan);

        assertEq(loanManager.loanCounter(),                    3);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   2);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   3);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(2).next,     3);
        assertEq(loanManager.loan(2).previous, 1);

        assertEq(loanManager.loan(3).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(3).next,     0);
        assertEq(loanManager.loan(3).previous, 2);

        loanManager.removeLoan(medianLoan.vehicle);

        assertEq(loanManager.loanCounter(),                    3);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   0);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   3);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     3);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  address(0));
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 0);

        assertEq(loanManager.loan(3).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(3).next,     0);
        assertEq(loanManager.loan(3).previous, 1);
    }

    function test_removeLoan_latestDueDate() external {
        loanManager.addLoan(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoan(medianLoan);

        assertEq(loanManager.loanCounter(),                    2);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   2);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);

        loanManager.addLoan(latestLoan);

        assertEq(loanManager.loanCounter(),                    3);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   2);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   3);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(2).next,     3);
        assertEq(loanManager.loan(2).previous, 1);

        assertEq(loanManager.loan(3).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(3).next,     0);
        assertEq(loanManager.loan(3).previous, 2);

        loanManager.removeLoan(latestLoan.vehicle);

        assertEq(loanManager.loanCounter(),                    3);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);
        assertEq(loanManager.loanIdOf(medianLoan.vehicle),   2);
        assertEq(loanManager.loanIdOf(latestLoan.vehicle),   0);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     2);
        assertEq(loanManager.loan(1).previous, 0);

        assertEq(loanManager.loan(2).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(2).next,     0);
        assertEq(loanManager.loan(2).previous, 1);

        assertEq(loanManager.loan(3).vehicle,  address(0));
        assertEq(loanManager.loan(3).next,     0);
        assertEq(loanManager.loan(3).previous, 0);
    }

}
