
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                   from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import {
    MockAuctioneer,
    MockGlobals,
    MockLiquidationStrategy,
    MockLoan,
    MockPool,
    MockPoolCoverManager,
    MockPoolManager
} from "./mocks/Mocks.sol";

import { LoanManager } from "../contracts/interest/LoanManager.sol";
import { Pool }        from "../contracts/Pool.sol";
import { PoolManager } from "../contracts/PoolManager.sol";

import { LoanManagerHarness } from "./harnesses/LoanManagerHarness.sol";

contract LoanManagerBaseTest is TestUtils {

    uint256 constant START_TIME = 1657792400;

    uint256 coverFee      = 0.1e18;
    uint256 managementFee = 0.2e18;

    LoanManager     loanManager;
    MockERC20       asset;
    MockPool        pool;
    MockPoolManager poolManager;


    function setUp() public virtual {
        asset       = new MockERC20("MockERC20", "MOCK", 18);
        pool        = new MockPool();
        poolManager = new MockPoolManager();

        pool.setAsset(address(asset));

        loanManager = new LoanManager(address(pool), address(poolManager));

        vm.warp(START_TIME);

    }
}

contract FundLoanTests is LoanManagerBaseTest {

    address collateralAsset = address(asset);
    address fundsAsset      = address(asset);

    uint256 principalRequested = 1_000_000e18;
    uint256 paymentInterest    = 1e18;
    uint256 paymentPrincipal   = 0;

    MockLoan loan;

    function setUp() public override {
        super.setUp();

        poolManager.setCoverFee(coverFee);
        poolManager.setManagementFee(managementFee);

        loan = new MockLoan(collateralAsset, fundsAsset);

        // Set next payment information for loanManager to use.
        loan.__setPrincipalRequested(principalRequested);  // Simulate funding
        loan.__setNextPaymentInterest(paymentInterest);
        loan.__setNextPaymentPrincipal(paymentPrincipal);
        loan.__setNextPaymentDueDate(block.timestamp + 100);
    }

    function test_fund() external {
        asset.mint(address(loan), principalRequested);

        (
            ,
            ,
            uint256 incomingNetInterest_,
            uint256 startDate_,
            uint256 paymentDueDate_,
            uint256 coverFee_,
            uint256 managementFee_,
            address vehicle_
        ) = loanManager.loans(1);

        assertEq(incomingNetInterest_, 0);
        assertEq(startDate_,           0);
        assertEq(paymentDueDate_,      0);
        assertEq(coverFee_,            0);
        assertEq(managementFee_,       0);
        assertEq(vehicle_,             address(0));

        assertEq(loanManager.principalOut(),        0);
        assertEq(loanManager.accountedInterest(),   0);
        assertEq(loanManager.issuanceRate(),        0);
        assertEq(loanManager.vestingPeriodFinish(), 0);
        assertEq(loanManager.lastUpdated(),         0);

        loan.__setPrincipal(principalRequested);  // Simulate intermediate state from funding

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));

        assertEq(loanManager.loanIdOf(address(loan)), 1);

        (   ,
            ,
            incomingNetInterest_,
            startDate_,
            paymentDueDate_,
            coverFee_,
            managementFee_,
            vehicle_
        ) = loanManager.loans(1);

        // Check loan information
        assertEq(incomingNetInterest_, 0.7e18); // 1e18 of interest minus cover and management fees
        assertEq(startDate_,           block.timestamp);
        assertEq(paymentDueDate_,      block.timestamp + 100);
        assertEq(coverFee_,            coverFee);
        assertEq(managementFee_,       managementFee);
        assertEq(vehicle_,             address(loan));

        assertEq(loanManager.principalOut(),        principalRequested);
        assertEq(loanManager.accountedInterest(),   0);
        assertEq(loanManager.issuanceRate(),        0.7e46);  // 0.7e18 * 1e30 / 100 = 0.7e46
        assertEq(loanManager.vestingPeriodFinish(), START_TIME + 100);
        assertEq(loanManager.lastUpdated(),         START_TIME);
    }

    function test_fund_failIfNotPoolManager() external {
        address notPoolManager = address(new Address());

        asset.mint(address(loan), principalRequested);

        vm.prank(notPoolManager);
        vm.expectRevert("IM:F:NOT_ADMIN");
        loanManager.fund(address(loan));
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
