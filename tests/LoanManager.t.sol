
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                   from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { LoanManagerFactory }     from "../contracts/proxy/LoanManagerFactory.sol";
import { LoanManagerInitializer } from "../contracts/proxy/LoanManagerInitializer.sol";

import { LoanManagerHarness } from "./harnesses/LoanManagerHarness.sol";
import {
    MockAuctioneer,
    MockGlobals,
    MockLiquidationStrategy,
    MockLoan,
    MockLoanManagerMigrator,
    MockPool,
    MockPoolManager
} from "./mocks/Mocks.sol";

import { LoanManager } from "../contracts/LoanManager.sol";
import { Pool }        from "../contracts/Pool.sol";
import { PoolManager } from "../contracts/PoolManager.sol";

import { LoanManagerHarness } from "./harnesses/LoanManagerHarness.sol";

// TODO: Can we add tests for 2 claims on the same loan without any payments between them?

contract LoanManagerBaseTest is TestUtils {

    uint256 constant START = 5_000_000;

    address governor       = address(new Address());
    address implementation = address(new LoanManagerHarness());
    address initializer    = address(new LoanManagerInitializer());

    uint256 managementFee = 0.3e18;

    MockERC20       asset;
    MockGlobals     globals;
    MockPool        pool;
    MockPoolManager poolManager;

    LoanManagerFactory factory;
    LoanManagerHarness loanManager;

    function setUp() public virtual {
        asset       = new MockERC20("MockERC20", "MOCK", 18);
        globals     = new MockGlobals(governor);
        poolManager = new MockPoolManager();
        pool        = new MockPool();

        pool.__setAsset(address(asset));
        pool.__setManager(address(poolManager));

        vm.startPrank(governor);
        factory = new LoanManagerFactory(address(globals));
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        bytes memory arguments = LoanManagerInitializer(initializer).encodeArguments(address(pool));
        loanManager = LoanManagerHarness(LoanManagerFactory(factory).createInstance(arguments, ""));

        vm.warp(START);
    }
}

contract MigrateTests is LoanManagerBaseTest {

    address migrator = address(new MockLoanManagerMigrator());

    function test_migrate_notFactory() external {
        vm.expectRevert("LM:M:NOT_FACTORY");
        loanManager.migrate(migrator, "");
    }

    function test_migrate_internalFailure() external {
        vm.prank(loanManager.factory());
        vm.expectRevert("LM:M:FAILED");
        loanManager.migrate(migrator, "");
    }

    function test_migrate_success() external {
        assertEq(loanManager.fundsAsset(), address(asset));

        vm.prank(loanManager.factory());
        loanManager.migrate(migrator, abi.encode(address(0)));

        assertEq(loanManager.fundsAsset(), address(0));
    }

}

contract SetImplementationTests is LoanManagerBaseTest {

    address newImplementation = address(new LoanManagerHarness());

    function test_setImplementation_notFactory() external {
        vm.expectRevert("LM:SI:NOT_FACTORY");
        loanManager.setImplementation(newImplementation);
    }

    function test_setImplementation_success() external {
        assertEq(loanManager.implementation(), implementation);

        vm.prank(loanManager.factory());
        loanManager.setImplementation(newImplementation);

        assertEq(loanManager.implementation(), newImplementation);
    }

}

contract UpgradeTests is LoanManagerBaseTest {

    address newImplementation = address(new LoanManagerHarness());

    function setUp() public override {
        super.setUp();

        vm.startPrank(governor);
        factory.registerImplementation(2, newImplementation, address(0));
        factory.enableUpgradePath(1, 2, address(0));
        vm.stopPrank();
    }

    function test_upgrade_notPoolDelegate() external {
        vm.expectRevert("LM:U:NOT_PD");
        loanManager.upgrade(2, "");
    }

    function test_upgrade_upgradeFailed() external {
        vm.prank(poolManager.poolDelegate());
        vm.expectRevert("MPF:UI:FAILED");
        loanManager.upgrade(2, "1");
    }

    function test_upgrade_success() external {
        vm.prank(poolManager.poolDelegate());
        loanManager.upgrade(2, "");
    }

}

contract LoanManagerClaimBaseTest is LoanManagerBaseTest {

    function setUp() public virtual override {
        super.setUp();

        poolManager.setManagementFee(managementFee);
    }

    function _assertBalances(address loanAddress, uint256 loanBalance, uint256 poolBalance, uint256 poolManagerBalance) internal {
        assertEq(asset.balanceOf(loanAddress),          loanBalance);
        assertEq(asset.balanceOf(address(pool)),        poolBalance);
        assertEq(asset.balanceOf(address(poolManager)), poolManagerBalance);
    }

    function _assertLoanInfo(
        address loanAddress,
        uint256 loanId,
        uint256 incomingNetInterest,
        uint256 principalOf_loan,
        uint256 startDate,
        uint256 paymentDueDate
    )
        internal
    {
        ( , , uint256 incomingNetInterest_, uint256 startDate_, uint256 paymentDueDate_, ,  ) = loanManager.loans(loanId);

        assertEq(incomingNetInterest_, incomingNetInterest);
        assertEq(startDate_,           startDate);
        assertEq(paymentDueDate_,      paymentDueDate);

        assertEq(loanManager.principalOf(loanAddress), principalOf_loan);
    }

    function _assertLoanManagerState(
        uint256 accruedInterest,
        uint256 accountedInterest,
        uint256 principalOut,
        uint256 assetsUnderManagement,
        uint256 issuanceRate,
        uint256 lastUpdated,
        uint256 vestingPeriodFinish
    )
        internal
    {
        assertEq(loanManager.getAccruedInterest(),     accruedInterest);
        assertEq(loanManager.accountedInterest(),      accountedInterest);
        assertEq(loanManager.principalOut(),           principalOut);
        assertEq(loanManager.assetsUnderManagement(),  assetsUnderManagement);
        assertEq(loanManager.issuanceRate(),           issuanceRate);
        assertEq(loanManager.lastUpdated(),            lastUpdated);
        assertEq(loanManager.vestingPeriodFinish(),    vestingPeriodFinish);
    }

    function _assertTotalAssets(uint256 totalAssets) internal {
        assertEq(loanManager.assetsUnderManagement() + asset.balanceOf(address(pool)), totalAssets);
    }

    function _makePayment(
        address loanAddress,
        uint256 interestAmount,
        uint256 principalAmount,
        uint256 nextInterestPayment,
        uint256 paymentTimestamp,
        uint256 nextPaymentDueDate
    )
        public
    {
        MockLoan loan_ = MockLoan(loanAddress);
        vm.warp(paymentTimestamp);
        asset.mint(address(loan_), interestAmount + principalAmount);
        loan_.__setClaimableFunds(interestAmount + principalAmount);
        loan_.__setPrincipal(loan_.principal() - principalAmount);
        loan_.__setNextPaymentInterest(nextInterestPayment);
        loan_.__setNextPaymentDueDate(nextPaymentDueDate);
    }

}

contract ClaimTests is LoanManagerClaimBaseTest {

    address loan;

    function setUp() public override {
        super.setUp();

        loan = address(new MockLoan(address(asset), address(asset)));

        // Set next payment information for loanManager to use.
        MockLoan loan_ = MockLoan(loan);
        loan_.__setPrincipal(1_000_000);
        loan_.__setPrincipalRequested(1_000_000);
        loan_.__setNextPaymentInterest(100);
        loan_.__setNextPaymentDueDate(START + 10_000);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));
    }

    function test_claim_notManager() external {
        _makePayment({
            loanAddress:         loan,
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 10_000,
            nextPaymentDueDate:  START + 20_000
        });

        vm.expectRevert("LM:C:NOT_POOL_MANAGER");
        loanManager.claim(loan);

        vm.prank(address(poolManager));
        loanManager.claim(loan);
    }
}

contract FinishCollateralLiquidationTests is LoanManagerBaseTest {

    address auctioneer;
    address loan;

    function setUp() public override {
        super.setUp();

        loan = address(new MockLoan(address(asset), address(asset)));

        // Set next payment information for loanManager to use.
        MockLoan loan_ = MockLoan(loan);
        loan_.__setPrincipal(1_000_000);
        loan_.__setPrincipalRequested(1_000_000);
        loan_.__setNextPaymentInterest(100);
        loan_.__setNextPaymentDueDate(START + 10_000);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));

        auctioneer = address(new MockAuctioneer(0.5e18, 1e18));
    }

    function test_finishCollateralLiquidation_notManager() public {
        uint256 nextPaymentDueDate = MockLoan(loan).nextPaymentDueDate();
        vm.warp(nextPaymentDueDate);

        vm.prank(address(poolManager));
        loanManager.triggerCollateralLiquidation(address(loan), auctioneer);

        vm.expectRevert("LM:FCL:NOT_POOL_MANAGER");
        loanManager.finishCollateralLiquidation(address(loan));

        vm.prank(address(poolManager));
        loanManager.finishCollateralLiquidation(address(loan));
    }

}

contract SingleLoanAtomicClaimTests is LoanManagerClaimBaseTest {

    MockLoan loan;

    function setUp() public override {
        super.setUp();

        loan = new MockLoan(address(asset), address(asset));

        // Set next payment information for loanManager to use.
        loan.__setPrincipal(1_000_000);
        loan.__setPrincipalRequested(1_000_000);
        loan.__setNextPaymentInterest(100);
        loan.__setNextPaymentDueDate(START + 10_000);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));
    }

    function test_claim_onTimePayment_interestOnly() external {
        // First  payment net interest accrued: 10_000 * 0.01 * 0.7 = 70
        // First  payment net interest claimed: 10_000 * 0.01 * 0.7 = 70
        // Second payment net interest accrued: 0      * 0.01 * 0.7 = 0
        // ----------------------
        // Starting  total assets: 1_000_000 + 0  + 70 = 1_000_070
        // Resulting total assets: 1_000_000 + 70 + 0  = 1_000_070

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 10_000,
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       70,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_070,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_070);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_000,
            issuanceRate:          0.007e30,
            lastUpdated:           START + 10_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        70,
            poolManagerBalance: 30
        });

        _assertTotalAssets(1_000_070);
    }

    function test_claim_earlyPayment_interestOnly() external {
        // First  payment net interest accrued:  6_000 * 0.01 * 0.7 = 42
        // First  payment net interest claimed: 10_000 * 0.01 * 0.7 = 70
        // Second payment net interest accrued:      0 * 0.01 * 0.7 = 0
        // ----------------------
        // Starting  total assets: 1_000_000 + 0  + 42 = 1_000_042
        // Resulting total assets: 1_000_000 + 70 + 0  = 1_000_070

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 6_000,  // Payment is made 4000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       42,  // 0.007 * 6_000 = 42
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_042,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_042);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START + 6_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_000,
            issuanceRate:          0.005e30,  // 70 / (10_000 + 4_000 remaining in interval) = 0.005
            lastUpdated:           START + 6_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        70,
            poolManagerBalance: 30
        });

        _assertTotalAssets(1_000_070);
    }

    function test_claim_latePayment_interestOnly() external {
        // First  payment net interest accrued:  10_000 * 0.01 * 0.7                 = 70
        // First  payment net interest claimed: (10_000 * 0.01 + 4000 * 0.015) * 0.7 = 112
        // Second payment net interest accrued:   4_000 * 0.01 * 0.7                 = 28
        // ----------------------
        // Starting  total assets: 1_000_000 + 0   + 70 = 1_000_070
        // Resulting total assets: 1_000_000 + 112 + 28 = 1_000_140

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      160,             // 4000 seconds late at the premium interest rate (10_000 * 0.01 + 4000 * 0.015 = 160)
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 14_000,  // Payment is made 4000 seconds late.
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       70,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_070,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        160,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_070);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     28,  // 4000 seconds into the next interval = 4000 * 0.007 = 28
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_028,
            issuanceRate:          0.007e30,  // Same issuance rate as before.
            lastUpdated:           START + 14_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        112,  // 160 * 0.7 = 112
            poolManagerBalance: 48    // 160 * 0.3 = 48
        });

        _assertTotalAssets(1_000_140);
    }

    function test_claim_onTimePayment_amortized() external {
        // First  payment net interest accrued: 10_000 * 0.01 * 0.7 = 70
        // First  payment net interest claimed: 10_000 * 0.01 * 0.7 = 70
        // Second payment net interest accrued:      0 * 0.01 * 0.7 = 0
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0  + 70 = 1_000_070
        // Resulting total assets: 800_000   + 200_000 + 70 + 0  = 1_000_070

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 10_000,  // Payment is made 4000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       70,  // 0.007 * 10_000 = 70
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_070,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_070);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    800_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          800_000,
            assetsUnderManagement: 800_000,
            issuanceRate:          0.007e30,
            lastUpdated:           START + 10_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_070,
            poolManagerBalance: 30
        });

        _assertTotalAssets(1_000_070);
    }

    function test_claim_earlyPayment_amortized() external {
        // First  payment net interest accrued:  6_000 * 0.01 * 0.7 = 42
        // First  payment net interest claimed: 10_000 * 0.01 * 0.7 = 70
        // Second payment net interest accrued:      0 * 0.01 * 0.7 = 0
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0  + 42 = 1_000_042
        // Resulting total assets: 800_000   + 200_000 + 70 + 0  = 1_000_070

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 6_000,  // Payment is made 4000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       42,  // 0.007 * 6_000 = 42
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_042,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_042);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    800_000,
            startDate:           START + 6_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          800_000,
            assetsUnderManagement: 800_000,
            issuanceRate:          0.005e30,  // 70 / (10_000 + 4_000 remaining in current interval) = 0.005
            lastUpdated:           START + 6_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_070,
            poolManagerBalance: 30
        });

        _assertTotalAssets(1_000_070);
    }

    function test_claim_latePayment_amortized() external {
        // First  payment net interest accrued:  10_000 * 0.01 * 0.7                 = 70
        // First  payment net interest claimed: (10_000 * 0.01 + 4000 * 0.015) * 0.7 = 112
        // Second payment net interest accrued:   4_000 * 0.01 * 0.7                 = 28
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0   + 70 = 1_000_070
        // Resulting total assets: 800_000   + 200_000 + 112 + 28 = 1_000_140

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      160,             // 4000 seconds late at the premium interest rate (10_000 * 0.01 + 4000 * 0.015 = 160)
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 14_000,  // Payment is made 4000 seconds late.
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       70,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_070,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_160,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_070);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    800_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     28,  // 4000 seconds into the next interval = 4000 * 0.007 = 28
            principalOut:          800_000,
            assetsUnderManagement: 800_028,
            issuanceRate:          0.007e30,  // Same issuance rate as before.
            lastUpdated:           START + 14_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_112,  // 160 * 0.7 = 112
            poolManagerBalance: 48        // 160 * 0.3 = 48
        });

        _assertTotalAssets(1_000_140);
    }

}

contract SingleLoanLateClaimTests is LoanManagerClaimBaseTest {

    MockLoan loan;

    function setUp() public override {
        super.setUp();

        loan = new MockLoan(address(asset), address(asset));

        // Set next payment information for loanManager to use.
        loan.__setPrincipal(1_000_000);
        loan.__setPrincipalRequested(1_000_000);
        loan.__setNextPaymentInterest(100);
        loan.__setNextPaymentDueDate(START + 10_000);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));
    }

    function test_claim_onTimePayment_interestOnly() external {
        // First  payment net interest accrued: 10_000 * 0.01 * 0.7 = 70
        // First  payment net interest claimed: 10_000 * 0.01 * 0.7 = 70
        // Second payment net interest accrued:  1_000 * 0.01 * 0.7 = 7
        // ----------------------
        // Starting  total assets: 1_000_000 + 0  + 70 = 1_000_070
        // Resulting total assets: 1_000_000 + 70 + 7  = 1_000_077

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 10_000,
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 11_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       70,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_070,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_070);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     7,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_007,
            issuanceRate:          0.007e30,
            lastUpdated:           START + 11_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        70,
            poolManagerBalance: 30
        });

        _assertTotalAssets(1_000_077);
    }

    function test_claim_earlyPayment_interestOnly_claimBeforeDueDate() external {
        // First  payment net interest accrued at time of payment:  5_000 * 0.01 * 0.7 = 35
        // First  payment net interest accrued at time of claim:    8_000 * 0.01 * 0.7 = 42
        // First  payment net interest claimed:                    10_000 * 0.01 * 0.7 = 70
        // Second payment net interest accrued:                         0 * 0.01 * 0.7 = 0
        // ----------------------
        // Starting  total assets: 1_000_000 + 0  + 56 = 1_000_056
        // Resulting total assets: 1_000_000 + 70 + 0  = 1_000_070

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 5_000,  // Payment is made 5000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 6_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       42,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_042,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_042);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START + 6_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_000,
            issuanceRate:          0.005e30,  // 70 / (10_000 + 4_000 remaining in interval) = 0.005
            lastUpdated:           START + 6_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        70,
            poolManagerBalance: 30
        });

        _assertTotalAssets(1_000_070);
    }

    function test_claim_earlyPayment_interestOnly_claimAfterDueDate() external {
        // First  payment net interest accrued at time of payment:  5_000 * 0.01 * 0.7 = 35
        // First  payment net interest accrued at time of claim:   10_000 * 0.01 * 0.7 = 70
        // First  payment net interest claimed:                    10_000 * 0.01 * 0.7 = 70
        // Second payment net interest accrued:                     1_000 * 0.01 * 0.7 = 7
        // ----------------------
        // Starting  total assets: 1_000_000 + 0  + 70 = 1_000_070
        // Resulting total assets: 1_000_000 + 70 + 7  = 1_000_077

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 5_000,  // Payment is made 5000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 11_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       70,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_070,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_070);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     7,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_007,
            issuanceRate:          0.007e30,
            lastUpdated:           START + 11_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        70,
            poolManagerBalance: 30
        });

        _assertTotalAssets(1_000_077);
    }

    function test_claim_latePayment_interestOnly() external {
        // First  payment net interest accrued:      10_000 * 0.01 * 0.7                 = 70
        // First  payment net interest claimed:     (10_000 * 0.01 + 4000 * 0.015) * 0.7 = 112
        // Second payment net interest accrued:       4_000 * 0.01 * 0.7                 = 28
        // Second payment interest accrued at claim:  5_000 * 0.01 * 0.7                 = 35
        // ----------------------
        // Starting  total assets: 1_000_000 + 0   + 70 = 1_000_070
        // Resulting total assets: 1_000_000 + 112 + 35 = 1_000_147

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      160,             // 4000 seconds late at the premium interest rate (10_000 * 0.01 + 4000 * 0.015 = 160)
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 14_000,  // Payment is made 4000 seconds late.
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 15_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       70,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_070,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        160,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_070);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     35,  // 5000 seconds into the next interval = 4000 * 0.007 = 28
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_035,
            issuanceRate:          0.007e30,  // Same issuance rate as before.
            lastUpdated:           START + 15_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        112,  // 160 * 0.7 = 112
            poolManagerBalance: 48    // 160 * 0.3 = 48
        });

        _assertTotalAssets(1_000_147);
    }

    function test_claim_onTimePayment_amortized() external {
        // First  payment net interest accrued: 10_000 * 0.01 * 0.7 = 70
        // First  payment net interest claimed: 10_000 * 0.01 * 0.7 = 70
        // Second payment net interest accrued:  1_000 * 0.01 * 0.7 = 7
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0  + 70 = 1_000_070
        // Resulting total assets: 800_000   + 200_000 + 70 + 7  = 1_000_077

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 10_000,
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 11_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       70,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_070,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_070);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    800_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     7,
            principalOut:          800_000,
            assetsUnderManagement: 800_007,
            issuanceRate:          0.007e30,
            lastUpdated:           START + 11_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_070,
            poolManagerBalance: 30
        });

        _assertTotalAssets(1_000_077);
    }

    function test_claim_earlyPayment_amortized_claimBeforeDueDate() external {
        // First  payment net interest accrued at time of payment:  5_000 * 0.01 * 0.7 = 35
        // First  payment net interest accrued at time of claim:    8_000 * 0.01 * 0.7 = 42
        // First  payment net interest claimed:                    10_000 * 0.01 * 0.7 = 70
        // Second payment net interest accrued:                         0 * 0.01 * 0.7 = 0
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0  + 42 = 1_000_042
        // Resulting total assets: 800_000   + 200_000 + 70 + 0  = 1_000_070

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 5_000,  // Payment is made 5000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 6_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       42,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_042,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_042);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    800_000,
            startDate:           START + 6_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          800_000,
            assetsUnderManagement: 800_000,
            issuanceRate:          0.005e30,  // 70 / (10_000 + 4_000 remaining in interval) = 0.005
            lastUpdated:           START + 6_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_070,
            poolManagerBalance: 30
        });

        _assertTotalAssets(1_000_070);
    }

    function test_claim_earlyPayment_amortized_claimAfterDueDate() external {
        // First  payment net interest accrued at time of payment:  5_000 * 0.01 * 0.7 = 35
        // First  payment net interest accrued at time of claim:   10_000 * 0.01 * 0.7 = 70
        // First  payment net interest claimed:                    10_000 * 0.01 * 0.7 = 70
        // Second payment net interest accrued:                     1_000 * 0.01 * 0.7 = 7
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0  + 70 = 1_000_070
        // Resulting total assets: 800_000   + 200_000 + 70 + 7  = 1_000_077

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 5_000,  // Payment is made 5000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 11_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       70,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_070,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_070);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    800_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     7,
            principalOut:          800_000,
            assetsUnderManagement: 800_007,
            issuanceRate:          0.007e30,
            lastUpdated:           START + 11_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_070,
            poolManagerBalance: 30
        });

        _assertTotalAssets(1_000_077);
    }

    function test_claim_latePayment_amortized() external {
        // First  payment net interest accrued:      10_000 * 0.01 * 0.7                 = 70
        // First  payment net interest claimed:     (10_000 * 0.01 + 4000 * 0.015) * 0.7 = 112
        // Second payment net interest accrued:       4_000 * 0.01 * 0.7                 = 28
        // Second payment interest accrued at claim:  5_000 * 0.01 * 0.7                 = 35
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0   + 70 = 1_000_070
        // Resulting total assets: 800_000   + 200_000 + 112 + 35 = 1_000_147

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      160,             // 4000 seconds late at the premium interest rate (10_000 * 0.01 + 4000 * 0.015 = 160)
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 14_000,  // Payment is made 4000 seconds late.
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 15_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              1,
            incomingNetInterest: 70,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       70,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_070,
            issuanceRate:          0.007e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_160,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_070);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            loanId:              2,
            incomingNetInterest: 70,
            principalOf_loan:    800_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     35,  // 5000 seconds into the next interval = 4000 * 0.007 = 28
            principalOut:          800_000,
            assetsUnderManagement: 800_035,
            issuanceRate:          0.007e30,  // Same issuance rate as before.
            lastUpdated:           START + 15_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_112,  // 160 * 0.7 = 112
            poolManagerBalance: 48        // 160 * 0.3 = 48
        });

        _assertTotalAssets(1_000_147);
    }

}

contract TwoLoanAtomicClaimTests is LoanManagerClaimBaseTest {

    // Interest only, interest only
    function skiptest_claim_onTimePayment_interestOnly_onTimePayment_interestOnly() external {}
    function skiptest_claim_earlyPayment_interestOnly_onTimePayment_interestOnly() external {}
    function skiptest_claim_latePayment_interestOnly_onTimePayment_interestOnly() external {}

    function skiptest_claim_onTimePayment_interestOnly_earlyPayment_interestOnly() external {}
    function skiptest_claim_earlyPayment_interestOnly_earlyPayment_interestOnly() external {}
    function skiptest_claim_latePayment_interestOnly_earlyPayment_interestOnly() external {}

    function skiptest_claim_onTimePayment_interestOnly_latePayment_interestOnly() external {}
    function skiptest_claim_earlyPayment_interestOnly_latePayment_interestOnly() external {}
    function skiptest_claim_latePayment_interestOnly_latePayment_interestOnly() external {}

    // Interest only, amortized
    function skiptest_claim_onTimePayment_interestOnly_onTimePayment_amortized() external {}
    function skiptest_claim_earlyPayment_interestOnly_onTimePayment_amortized() external {}
    function skiptest_claim_latePayment_interestOnly_onTimePayment_amortized() external {}

    function skiptest_claim_onTimePayment_interestOnly_earlyPayment_amortized() external {}
    function skiptest_claim_earlyPayment_interestOnly_earlyPayment_amortized() external {}
    function skiptest_claim_latePayment_interestOnly_earlyPayment_amortized() external {}

    function skiptest_claim_onTimePayment_interestOnly_latePayment_amortized() external {}
    function skiptest_claim_earlyPayment_interestOnly_latePayment_amortized() external {}
    function skiptest_claim_latePayment_interestOnly_latePayment_amortized() external {}

    // Amortized, interest only
    function skiptest_claim_onTimePayment_amortized_onTimePayment_interestOnly() external {}
    function skiptest_claim_earlyPayment_amortized_onTimePayment_interestOnly() external {}
    function skiptest_claim_latePayment_amortized_onTimePayment_interestOnly() external {}

    function skiptest_claim_onTimePayment_amortized_earlyPayment_interestOnly() external {}
    function skiptest_claim_earlyPayment_amortized_earlyPayment_interestOnly() external {}
    function skiptest_claim_latePayment_amortized_earlyPayment_interestOnly() external {}

    function skiptest_claim_onTimePayment_amortized_latePayment_interestOnly() external {}
    function skiptest_claim_earlyPayment_amortized_latePayment_interestOnly() external {}
    function skiptest_claim_latePayment_amortized_latePayment_interestOnly() external {}

    // Amortized, amortized
    function skiptest_claim_onTimePayment_amortized_onTimePayment_amortized() external {}
    function skiptest_claim_earlyPayment_amortized_onTimePayment_amortized() external {}
    function skiptest_claim_latePayment_amortized_onTimePayment_amortized() external {}

    function skiptest_claim_onTimePayment_amortized_earlyPayment_amortized() external {}
    function skiptest_claim_earlyPayment_amortized_earlyPayment_amortized() external {}
    function skiptest_claim_latePayment_amortized_earlyPayment_amortized() external {}

    function skiptest_claim_onTimePayment_amortized_latePayment_amortized() external {}
    function skiptest_claim_earlyPayment_amortized_latePayment_amortized() external {}
    function skiptest_claim_latePayment_amortized_latePayment_amortized() external {}

}

contract TriggerCollateralLiquidationTests is LoanManagerBaseTest {

    address auctioneer;
    address loan;

    function setUp() public override {
        super.setUp();

        loan = address(new MockLoan(address(asset), address(asset)));

        // Set next payment information for loanManager to use.
        MockLoan loan_ = MockLoan(loan);
        loan_.__setPrincipal(1_000_000);
        loan_.__setPrincipalRequested(1_000_000);
        loan_.__setNextPaymentInterest(100);
        loan_.__setNextPaymentDueDate(START + 10_000);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));

        auctioneer = address(new MockAuctioneer(0.5e18, 1e18));
    }

    function test_triggerCollateralLiquidation_notManager() public {
        // NOTE: The next two lines of code are unnecessary, as loan.repossess() is mocked, but simulate the real preconditions for this function to be called.
        uint256 nextPaymentDueDate = MockLoan(loan).nextPaymentDueDate();
        vm.warp(nextPaymentDueDate);

        vm.expectRevert("LM:TCL:NOT_POOL_MANAGER");
        loanManager.triggerCollateralLiquidation(address(loan), auctioneer);

        vm.prank(address(poolManager));
        loanManager.triggerCollateralLiquidation(address(loan), auctioneer);
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
            uint256 managementFee_,
            address vehicle_
        ) = loanManager.loans(1);

        assertEq(incomingNetInterest_, 0);
        assertEq(startDate_,           0);
        assertEq(paymentDueDate_,      0);
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
            managementFee_,
            vehicle_
        ) = loanManager.loans(1);

        // Check loan information
        assertEq(incomingNetInterest_, 0.7e18); // 1e18 of interest minus management fees
        assertEq(startDate_,           block.timestamp);
        assertEq(paymentDueDate_,      block.timestamp + 100);
        assertEq(managementFee_,       managementFee);
        assertEq(vehicle_,             address(loan));

        assertEq(loanManager.principalOut(),        principalRequested);
        assertEq(loanManager.accountedInterest(),   0);
        assertEq(loanManager.issuanceRate(),        0.7e46);  // 0.7e18 * 1e30 / 100 = 0.7e46
        assertEq(loanManager.vestingPeriodFinish(), START + 100);
        assertEq(loanManager.lastUpdated(),         START);
    }

    function test_fund_failIfNotPoolManager() external {
        address notPoolManager = address(new Address());

        asset.mint(address(loan), principalRequested);

        vm.prank(notPoolManager);
        vm.expectRevert("LM:F:NOT_POOL_MANAGER");
        loanManager.fund(address(loan));
    }

}

contract LoanManagerSortingTests is LoanManagerBaseTest {

    LoanManagerHarness.LoanInfo earliestLoan;
    LoanManagerHarness.LoanInfo latestLoan;
    LoanManagerHarness.LoanInfo medianLoan;
    LoanManagerHarness.LoanInfo synchronizedLoan;

    function setUp() public override {
        super.setUp();

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
