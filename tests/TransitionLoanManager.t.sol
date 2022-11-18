// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";

import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { Pool                  } from "../contracts/Pool.sol";
import { PoolManager           } from "../contracts/PoolManager.sol";
import { TransitionLoanManager } from "../contracts/TransitionLoanManager.sol";

import { LoanManagerFactory     } from "../contracts/proxy/LoanManagerFactory.sol";
import { LoanManagerInitializer } from "../contracts/proxy/LoanManagerInitializer.sol";

import {
    MockFactory,
    MockGlobals,
    MockLoanV3,
    MockPool,
    MockPoolManager
} from "./mocks/Mocks.sol";

contract TransitionLoanManagerTestBase is TestUtils {

    address governor       = address(new Address());
    address migrationAdmin = address(new Address());
    address poolDelegate   = address(new Address());
    address treasury       = address(new Address());

    uint256 delegateManagementFeeRate = 0.05e6;
    uint256 platformManagementFeeRate = 0.15e6;

    uint256 start = 1_664_288_489 seconds;

    MockERC20       collateralAsset;
    MockERC20       fundsAsset;
    MockGlobals     globals;
    MockLoanV3      loan1;
    MockLoanV3      loan2;
    MockPool        pool;
    MockPoolManager poolManager;

    TransitionLoanManager loanManager;

    function setUp() public virtual {
        collateralAsset = new MockERC20("Collateral Asset", "CA", 18);
        fundsAsset      = new MockERC20("Funds Asset",      "FA", 18);
        globals         = new MockGlobals(governor);
        loan1           = new MockLoanV3(address(collateralAsset), address(fundsAsset));
        loan2           = new MockLoanV3(address(collateralAsset), address(fundsAsset));
        poolManager     = new MockPoolManager();
        pool            = new MockPool();

        globals.setMapleTreasury(treasury);
        globals.setMigrationAdmin(migrationAdmin);
        globals.setPlatformManagementFeeRate(address(poolManager), 0.15e6);
        globals.setValidPoolDelegate(poolDelegate, true);
        globals.setValidPoolDeployer(address(this), true);

        pool.__setAsset(address(fundsAsset));
        pool.__setManager(address(poolManager));

        poolManager.setDelegateManagementFeeRate(0.05e6);
        poolManager.__setGlobals(address(globals));
        poolManager.__setPoolDelegate(poolDelegate);

        LoanManagerFactory factory = new LoanManagerFactory(address(globals));

        vm.startPrank(governor);
        factory.registerImplementation(1, address(new TransitionLoanManager()), address(new LoanManagerInitializer()));
        factory.setDefaultVersion(1);
        vm.stopPrank();

        loanManager = TransitionLoanManager(factory.createInstance(abi.encode(address(pool)), "SALT"));

        vm.warp(start);
    }

}

contract TransitionLoanManagerAddTests is TransitionLoanManagerTestBase {

    function test_add_notMigrationAdmin() external {
        vm.expectRevert("TLM:A:NOT_MA");
        loanManager.add(address(loan1));
    }

    function test_add_noPayment() external {
        vm.prank(address(migrationAdmin));
        vm.expectRevert("TLM:A:INVALID_LOAN");
        loanManager.add(address(loan1));
    }

    function test_add_latePayment() external {
        // Set up for success case
        loan1.__setPaymentInterval(30 days);
        loan1.__setPrincipal(1_000_000e18);
        loan1.__setNextPaymentInterest(50_000e18);
        loan1.__setRefinanceInterest(0);

        loan1.__setNextPaymentDueDate(block.timestamp);

        vm.prank(address(migrationAdmin));
        vm.expectRevert("TLM:A:INVALID_LOAN");
        loanManager.add(address(loan1));

        loan1.__setNextPaymentDueDate(block.timestamp + 1);

        vm.prank(address(migrationAdmin));
        loanManager.add(address(loan1));
    }

    function test_add_multipleLoans() external {
        {
            (
                uint256 previous_,
                uint256 next_,
                uint256 sortedPaymentDueDate_
            ) = loanManager.sortedPayments(1);

            assertEq(previous_,             0);
            assertEq(next_,                 0);
            assertEq(sortedPaymentDueDate_, 0);

            (
                uint256 platformManagementFeeRate_,
                uint256 delegateManagementFeeRate_,
                uint256 startDate_,
                uint256 paymentDueDate_,
                uint256 incomingNetInterest_,
                uint256 refinanceInterest_,
                uint256 issuanceRate_
            ) = loanManager.payments(1);

            assertEq(delegateManagementFeeRate_, 0);
            assertEq(incomingNetInterest_,       0);
            assertEq(issuanceRate_,              0);
            assertEq(paymentDueDate_,            0);
            assertEq(platformManagementFeeRate_, 0);
            assertEq(refinanceInterest_,         0);
            assertEq(startDate_,                 0);
        }

        assertEq(loanManager.accountedInterest(),          0);
        assertEq(loanManager.assetsUnderManagement(),      0);
        assertEq(loanManager.domainEnd(),                  0);
        assertEq(loanManager.domainStart(),                0);
        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.paymentCounter(),             0);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.principalOut(),               0);
        assertEq(loanManager.unrealizedLosses(),           0);

        /******************************************************************************************************************************/
        /*** Add the first loan                                                                                                     ***/
        /******************************************************************************************************************************/

        // TODO: Can refinance interest be a non-zero value when we upgrade?
        loan1.__setNextPaymentDueDate(start + 20 days);
        loan1.__setPaymentInterval(30 days);
        loan1.__setPrincipal(1_000_000e18);
        loan1.__setNextPaymentInterest(50_000e18);
        loan1.__setRefinanceInterest(0);

        vm.prank(address(migrationAdmin));
        loanManager.add(address(loan1));

        {
            (
                uint256 previous_,
                uint256 next_,
                uint256 sortedPaymentDueDate_
            ) = loanManager.sortedPayments(1);

            assertEq(previous_,             0);
            assertEq(next_,                 0);
            assertEq(sortedPaymentDueDate_, start + 20 days);

            (
                uint256 platformManagementFeeRate_,
                uint256 delegateManagementFeeRate_,
                uint256 startDate_,
                uint256 paymentDueDate_,
                uint256 incomingNetInterest_,
                uint256 refinanceInterest_,
                uint256 issuanceRate_
            ) = loanManager.payments(1);

            assertEq(delegateManagementFeeRate_, 0.05e6);
            assertEq(incomingNetInterest_,       50_000e18 * 4 / 5 - 1);  // Rounding error due to issuance rate calculation.
            assertEq(issuanceRate_,              uint256(40_000e18) * 1e30 / 30 days);
            assertEq(paymentDueDate_,            start + 20 days);
            assertEq(platformManagementFeeRate_, 0.15e6);
            assertEq(refinanceInterest_,         0);
            assertEq(startDate_,                 start - 10 days);
        }

        uint256 issuanceRate      = uint256(40_000e18) * 1e30 / 30 days;
        uint256 accountedInterest = issuanceRate * 10 days / 1e30;

        assertEq(loanManager.accountedInterest(),          accountedInterest);
        assertEq(loanManager.assetsUnderManagement(),      1_000_000e18 + accountedInterest);
        assertEq(loanManager.domainEnd(),                  start + 20 days);
        assertEq(loanManager.domainStart(),                start);
        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.issuanceRate(),               issuanceRate);
        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);
        assertEq(loanManager.principalOut(),               1_000_000e18);
        assertEq(loanManager.unrealizedLosses(),           0);

        /******************************************************************************************************************************/
        /*** Add the second loan                                                                                                    ***/
        /******************************************************************************************************************************/

        loan2.__setNextPaymentDueDate(start + 10 days);
        loan2.__setPaymentInterval(30 days);
        loan2.__setPrincipal(2_500_000e18);
        loan2.__setNextPaymentInterest(100_000e18);
        loan2.__setRefinanceInterest(0);

        vm.prank(address(migrationAdmin));
        loanManager.add(address(loan2));

        {
            (
                uint256 previous_,
                uint256 next_,
                uint256 sortedPaymentDueDate_
            ) = loanManager.sortedPayments(1);

            assertEq(previous_,             2);
            assertEq(next_,                 0);
            assertEq(sortedPaymentDueDate_, start + 20 days);

            (
                uint256 platformManagementFeeRate_,
                uint256 delegateManagementFeeRate_,
                uint256 startDate_,
                uint256 paymentDueDate_,
                uint256 incomingNetInterest_,
                uint256 refinanceInterest_,
                uint256 issuanceRate_
            ) = loanManager.payments(1);

            assertEq(delegateManagementFeeRate_, 0.05e6);
            assertEq(incomingNetInterest_,       50_000e18 * 4 / 5 - 1);  // Rounding error due to issuance rate calculation.
            assertEq(issuanceRate_,              uint256(40_000e18) * 1e30 / 30 days);
            assertEq(paymentDueDate_,            start + 20 days);
            assertEq(platformManagementFeeRate_, 0.15e6);
            assertEq(refinanceInterest_,         0);
            assertEq(startDate_,                 start - 10 days);
        }

        {
            (
                uint256 previous_,
                uint256 next_,
                uint256 sortedPaymentDueDate_
            ) = loanManager.sortedPayments(2);

            assertEq(previous_,             0);
            assertEq(next_,                 1);
            assertEq(sortedPaymentDueDate_, start + 10 days);

            (
                uint256 platformManagementFeeRate_,
                uint256 delegateManagementFeeRate_,
                uint256 startDate_,
                uint256 paymentDueDate_,
                uint256 incomingNetInterest_,
                uint256 refinanceInterest_,
                uint256 issuanceRate_
            ) = loanManager.payments(2);

            assertEq(delegateManagementFeeRate_, 0.05e6);
            assertEq(incomingNetInterest_,       100_000e18 * 4 / 5 - 1);  // Rounding error due to issuance rate calculation.
            assertEq(issuanceRate_,              uint256(80_000e18) * 1e30 / 30 days);
            assertEq(paymentDueDate_,            start + 10 days);
            assertEq(platformManagementFeeRate_, 0.15e6);
            assertEq(refinanceInterest_,         0);
            assertEq(startDate_,                 start - 20 days);
        }

        uint256 issuanceRate1 = uint256(40_000e18) * 1e30 / 30 days;
        uint256 issuanceRate2 = uint256(80_000e18) * 1e30 / 30 days;

        uint256 totalPrincipalOut      = 1_000_000e18 + 2_500_000e18;
        uint256 totalIssuanceRate      = issuanceRate1 + issuanceRate2;
        uint256 totalAccountedInterest = issuanceRate1 * 10 days / 1e30 + issuanceRate2 * 20 days / 1e30;

        assertEq(loanManager.accountedInterest(),          totalAccountedInterest);
        assertEq(loanManager.assetsUnderManagement(),      totalPrincipalOut + totalAccountedInterest);
        assertEq(loanManager.domainEnd(),                  start + 10 days);
        assertEq(loanManager.domainStart(),                start);
        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.issuanceRate(),               totalIssuanceRate);
        assertEq(loanManager.paymentCounter(),             2);
        assertEq(loanManager.paymentWithEarliestDueDate(), 2);
        assertEq(loanManager.principalOut(),               totalPrincipalOut);
        assertEq(loanManager.unrealizedLosses(),           0);
    }

}
