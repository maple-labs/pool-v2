
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { LoanManagerFactory }     from "../contracts/proxy/LoanManagerFactory.sol";
import { LoanManagerInitializer } from "../contracts/proxy/LoanManagerInitializer.sol";

import { LoanManagerHarness } from "./harnesses/LoanManagerHarness.sol";
import {
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

    uint256 managementFee = 0.2e18;

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

        MockGlobals(globals).setValidPoolDeployer(address(this), true);

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
        uint256 incomingNetInterest,
        uint256 refinanceInterest,
        uint256 principalOf_loan,
        uint256 startDate,
        uint256 paymentDueDate
    )
        internal
    {
        ( , , uint256 incomingNetInterest_, uint256 refinanceInterest_, , uint256 startDate_, uint256 paymentDueDate_, , ) = loanManager.loans(loanManager.loanIdOf(loanAddress));

        assertEq(incomingNetInterest_, incomingNetInterest);
        assertEq(refinanceInterest_,   refinanceInterest);
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
    }

    function test_finishCollateralLiquidation_notManager() public {
        uint256 nextPaymentDueDate = MockLoan(loan).nextPaymentDueDate();
        vm.warp(nextPaymentDueDate);

        vm.prank(address(poolManager));
        loanManager.triggerCollateralLiquidation(address(loan));

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

        /**
         *  Loan 1
         *    Start date:    0
         *    Issuance rate: 0.008e30 (100 * 0.8 / 10_000)
         */
    }

    function test_claim_onTimePayment_interestOnly() external {
        // First  payment net interest accrued: 10_000 * 0.008 = 80
        // First  payment net interest claimed: 10_000 * 0.008 = 80
        // Second payment net interest accrued: 0      * 0.008 = 0
        // ----------------------
        // Starting  total assets: 1_000_000 + 0  + 80 = 1_000_080
        // Resulting total assets: 1_000_000 + 80 + 0  = 1_000_080

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
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_080);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_000,
            issuanceRate:          0.008e30,
            lastUpdated:           START + 10_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        80,
            poolManagerBalance: 20
        });

        _assertTotalAssets(1_000_080);
    }

    function test_claim_earlyPayment_interestOnly() external {
        // First  payment net interest accrued:  4_000 * 0.008 = 32
        // First  payment net interest claimed: 10_000 * 0.008 = 80
        // Second payment net interest accrued:      0 * 0.008 = 0
        // ----------------------
        // Starting  total assets: 1_000_000 + 0  + 32 = 1_000_032
        // Resulting total assets: 1_000_000 + 80 + 0  = 1_000_080

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 4_000,  // Payment is made 6000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       32,  // 0.008 * 4_000 = 32
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_032,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_032);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 4_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_000,
            issuanceRate:          0.005e30,  // 80 / (10_000 + 4_000 remaining in interval) = 0.005
            lastUpdated:           START + 4_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        80,
            poolManagerBalance: 20
        });

        _assertTotalAssets(1_000_080);
    }

    function test_claim_latePayment_interestOnly() external {
        // First  payment net interest accrued: 10_000 * 0.008                = 80
        // First  payment net interest claimed: 10_000 * 0.008 + 4000 * 0.012 = 128
        // Second payment net interest accrued:  4_000 * 0.008                = 32
        // ----------------------
        // Starting  total assets: 1_000_000 + 0   + 80 = 1_000_080
        // Resulting total assets: 1_000_000 + 128 + 32 = 1_000_160

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
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        160,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_080);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     32,  // 4000 seconds into the next interval = 4000 * 0.008 = 32
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_032,
            issuanceRate:          0.008e30,  // Same issuance rate as before.
            lastUpdated:           START + 14_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        128,  // 160 * 0.8 = 128
            poolManagerBalance: 32    // 160 * 0.2 = 32
        });

        _assertTotalAssets(1_000_160);
    }

    function test_claim_onTimePayment_amortized() external {
        // First  payment net interest accrued: 10_000 * 0.008 = 80
        // First  payment net interest claimed: 10_000 * 0.008 = 80
        // Second payment net interest accrued:      0 * 0.008 = 0
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0  + 80 = 1_000_080
        // Resulting total assets: 800_000   + 200_000 + 80 + 0  = 1_000_080

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
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       80,  // 0.008 * 10_000 = 80
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_080);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    800_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          800_000,
            assetsUnderManagement: 800_000,
            issuanceRate:          0.008e30,
            lastUpdated:           START + 10_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_080,
            poolManagerBalance: 20
        });

        _assertTotalAssets(1_000_080);
    }

    function test_claim_earlyPayment_amortized() external {
        // First  payment net interest accrued:  4_000 * 0.008 = 32
        // First  payment net interest claimed: 10_000 * 0.008 = 80
        // Second payment net interest accrued:      0 * 0.008 = 0
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0  + 32 = 1_000_032
        // Resulting total assets: 800_000   + 200_000 + 80 + 0  = 1_000_080

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 4_000,  // Payment is made 4000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       32,  // 0.008 * 6_000 = 32
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_032,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_032);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    800_000,
            startDate:           START + 4_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          800_000,
            assetsUnderManagement: 800_000,
            issuanceRate:          0.005e30,  // 80 / (10_000 + 6_000 remaining in current interval) = 0.005
            lastUpdated:           START + 4_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_080,
            poolManagerBalance: 20
        });

        _assertTotalAssets(1_000_080);
    }

    function test_claim_latePayment_amortized() external {
        // First  payment net interest accrued: 10_000 * 0.008                = 80
        // First  payment net interest claimed: 10_000 * 0.008 + 4000 * 0.012 = 128
        // Second payment net interest accrued:  4_000 * 0.008                = 32
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0   + 80 = 1_000_080
        // Resulting total assets: 800_000   + 200_000 + 128 + 32 = 1_000_156

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      160,             // 4000 seconds late at the premium interest rate (10_000 * 0.008 + 4000 * 0.012) / 0.8 = 160
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 14_000,  // Payment is made 4000 seconds late.
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_160,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_080);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    800_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     32,  // 4000 seconds into the next interval = 4000 * 0.008 = 28
            principalOut:          800_000,
            assetsUnderManagement: 800_032,
            issuanceRate:          0.008e30,  // Same issuance rate as before.
            lastUpdated:           START + 14_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_128,  // 160 * 0.8 = 128
            poolManagerBalance: 32        // 160 * 0.2 = 32
        });

        _assertTotalAssets(1_000_160);
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
        // First  payment net interest accrued: 10_000 * 0.008 = 80
        // First  payment net interest claimed: 10_000 * 0.008 = 80
        // Second payment net interest accrued:  1_000 * 0.008 = 8
        // ----------------------
        // Starting  total assets: 1_000_000 + 0  + 80 = 1_000_080
        // Resulting total assets: 1_000_000 + 80 + 7  = 1_000_088

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
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_080);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     8,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_008,
            issuanceRate:          0.008e30,
            lastUpdated:           START + 11_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        80,
            poolManagerBalance: 20
        });

        _assertTotalAssets(1_000_088);
    }

    function test_claim_earlyPayment_interestOnly_claimBeforeDueDate() external {
        // First  payment net interest accrued at time of payment:  3_000 * 0.008 = 24
        // First  payment net interest accrued at time of claim:    4_000 * 0.008 = 32
        // First  payment net interest claimed:                    10_000 * 0.008 = 80
        // Second payment net interest accrued:                         0 * 0.008 = 0
        // ----------------------
        // Starting  total assets: 1_000_000 + 0  + 56 = 1_000_056
        // Resulting total assets: 1_000_000 + 80 + 0  = 1_000_080

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 5_000,  // Payment is made 5000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 4_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       32,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_032,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_032);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 4_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_000,
            issuanceRate:          0.005e30,  // 80 / (10_000 + 4_000 remaining in interval) = 0.005
            lastUpdated:           START + 4_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        80,
            poolManagerBalance: 20
        });

        _assertTotalAssets(1_000_080);
    }

    function test_claim_earlyPayment_interestOnly_claimAfterDueDate() external {
        // First  payment net interest accrued at time of payment:  5_000 * 0.008 = 40
        // First  payment net interest accrued at time of claim:   10_000 * 0.008 = 80
        // First  payment net interest claimed:                    10_000 * 0.008 = 80
        // Second payment net interest accrued:                     1_000 * 0.008 = 8
        // ----------------------
        // Starting  total assets: 1_000_000 + 0  + 80 = 1_000_080
        // Resulting total assets: 1_000_000 + 80 + 8  = 1_000_088

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
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_080);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     8,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_008,
            issuanceRate:          0.008e30,
            lastUpdated:           START + 11_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        80,
            poolManagerBalance: 20
        });

        _assertTotalAssets(1_000_088);
    }

    function test_claim_latePayment_interestOnly() external {
        // First  payment net interest accrued:      10_000 * 0.008                = 80
        // First  payment net interest claimed:      10_000 * 0.008 + 4000 * 0.012 = 128
        // Second payment net interest accrued:       4_000 * 0.008                = 32
        // Second payment interest accrued at claim:  5_000 * 0.008                = 40
        // ----------------------
        // Starting  total assets: 1_000_000 + 0   + 80 = 1_000_080
        // Resulting total assets: 1_000_000 + 128 + 40 = 1_000_168

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
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        160,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_080);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     40,  // 5000 seconds into the next interval = 5000 * 0.008 = 40
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_040,
            issuanceRate:          0.008e30,  // Same issuance rate as before.
            lastUpdated:           START + 15_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        128,  // 160 * 0.8 = 128
            poolManagerBalance: 32    // 160 * 0.2 = 32
        });

        _assertTotalAssets(1_000_168);
    }

    function test_claim_onTimePayment_amortized() external {
        // First  payment net interest accrued: 10_000 * 0.008 = 80
        // First  payment net interest claimed: 10_000 * 0.008 = 80
        // Second payment net interest accrued:  1_000 * 0.008 = 8
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0  + 80 = 1_000_080
        // Resulting total assets: 800_000   + 200_000 + 80 + 7  = 1_000_088

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
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_080);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    800_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     8,
            principalOut:          800_000,
            assetsUnderManagement: 800_008,
            issuanceRate:          0.008e30,
            lastUpdated:           START + 11_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_080,
            poolManagerBalance: 20
        });

        _assertTotalAssets(1_000_088);
    }

    function test_claim_earlyPayment_amortized_claimBeforeDueDate() external {
        // First  payment net interest accrued at time of payment:  3_000 * 0.008 = 24
        // First  payment net interest accrued at time of claim:    4_000 * 0.008 = 32
        // First  payment net interest claimed:                    10_000 * 0.008 = 80
        // Second payment net interest accrued:                         0 * 0.008 = 0
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0  + 32 = 1_000_032
        // Resulting total assets: 800_000   + 200_000 + 80 + 0  = 1_000_080

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100,
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 3_000,  // Payment is made 5000 seconds early.
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 4_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       32,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_032,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_032);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    800_000,
            startDate:           START + 4_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          800_000,
            assetsUnderManagement: 800_000,
            issuanceRate:          0.005e30,  // 80 / (10_000 + 6_000 remaining in interval) = 0.005
            lastUpdated:           START + 4_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_080,
            poolManagerBalance: 20
        });

        _assertTotalAssets(1_000_080);
    }

    function test_claim_earlyPayment_amortized_claimAfterDueDate() external {
        // First  payment net interest accrued at time of payment:  5_000 * 0.008 = 40
        // First  payment net interest accrued at time of claim:   10_000 * 0.008 = 80
        // First  payment net interest claimed:                    10_000 * 0.008 = 80
        // Second payment net interest accrued:                     1_000 * 0.008 = 8
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0  + 80 = 1_000_080
        // Resulting total assets: 800_000   + 200_000 + 80 + 7  = 1_000_088

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
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_080);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    800_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     8,
            principalOut:          800_000,
            assetsUnderManagement: 800_008,
            issuanceRate:          0.008e30,
            lastUpdated:           START + 11_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_080,
            poolManagerBalance: 20
        });

        _assertTotalAssets(1_000_088);
    }

    function test_claim_latePayment_amortized() external {
        // First  payment net interest accrued:      10_000 * 0.008                = 80
        // First  payment net interest claimed:      10_000 * 0.008 + 4000 * 0.012 = 128
        // Second payment net interest accrued:       4_000 * 0.008                = 32
        // Second payment interest accrued at claim:  5_000 * 0.008                = 40
        // Principal paid: 200_000
        // ----------------------
        // Starting  total assets: 1_000_000 + 0       + 0   + 80 = 1_000_080
        // Resulting total assets: 800_000   + 200_000 + 128 + 40 = 1_000_168

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      160,             // 4000 seconds late at the premium interest rate (10_000 * 0.008 + 4000 * 0.012 = 160)
            principalAmount:     200_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 14_000,  // Payment is made 4000 seconds late.
            nextPaymentDueDate:  START + 20_000
        });

        vm.warp(START + 15_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_160,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(1_000_080);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    800_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     40,  // 5000 seconds into the next interval = 4000 * 0.008 = 28
            principalOut:          800_000,
            assetsUnderManagement: 800_040,
            issuanceRate:          0.008e30,  // Same issuance rate as before.
            lastUpdated:           START + 15_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        200_128,  // 160 * 0.8 = 128
            poolManagerBalance: 32        // 160 * 0.2 = 32
        });

        _assertTotalAssets(1_000_168);
    }

}

// TODO: Refactor above tests to use 80%
// TODO: Update helper function to include loan issuance rate.
contract TwoLoanAtomicClaimTests is LoanManagerClaimBaseTest {

    MockLoan loan1;
    MockLoan loan2;

    function setUp() public override {
        super.setUp();

        loan1 = new MockLoan(address(asset), address(asset));
        loan2 = new MockLoan(address(asset), address(asset));

        // Set next payment information for loanManager to use.
        loan1.__setPrincipal(1_000_000);
        loan2.__setPrincipal(1_000_000);
        loan1.__setPrincipalRequested(1_000_000);
        loan2.__setPrincipalRequested(1_000_000);
        loan1.__setNextPaymentInterest(100);
        loan2.__setNextPaymentInterest(125);
        loan1.__setNextPaymentDueDate(START + 10_000);
        loan2.__setNextPaymentDueDate(START + 16_000);  // 10_000 second interval

        vm.startPrank(address(poolManager));
        loanManager.fund(address(loan1));
        vm.warp(START + 6_000);
        loanManager.fund(address(loan2));
        vm.stopPrank();

        /**
         *  Loan 1
         *    Start date:    0sec
         *    Issuance rate: 0.008e30 (100 * 0.8 / 10_000)
         *  Loan 2
         *    Start date:    6_000sec
         *    Issuance rate: 0.01e30 (125 * 0.8 / 10_000)
         */
    }

    // Interest only, interest only
    function test_claim_onTimePayment_interestOnly_onTimePayment_interestOnly() external {
        /**
         *  ***********************************
         *  *** Loan 1 Payment (t = 10_000) ***
         *  ***********************************
         *  --- Pre-Claim ---
         *  Loan 1:
         *    First  payment net interest accounted: 6_000sec * 0.008 = 48 (Accounted during loan2 funding)
         *    First  payment net interest accrued:   4_000sec * 0.008 = 32
         *  Loan 2:
         *    First payment net interest accrued: 4_000sec * 0.01 = 40
         *  --- Post-Claim ---
         *  Loan 1:
         *    First  payment net interest claimed:   10_000sec * 0.008 = 80
         *    Second payment net interest accounted: 0sec      * 0.008 = 0
         *  Loan 2:
         *    First payment net interest accounted: 4_000sec * 0.01 = 40
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + (32 + 40) + 48 + 0  = 1_000_120
         *  Resulting total assets: 2_000_000 + 0         + 40 + 80 = 1_000_120
         *
         *  ***********************************
         *  *** Loan 2 Payment (t = 16_000) ***
         *  ***********************************
         *  --- Pre-Claim ---
         *  Loan 1:
         *    Second payment net interest accrued: 6_000sec * 0.008 = 48
         *  Loan 2:
         *    First  payment net interest accounted: 4_000sec * 0.01 = 40 (Accounted during loan1 payment)
         *    First  payment net interest accrued:   6_000sec * 0.01 = 60
         *    Second payment net interest accrued:   0sec     * 0.01 = 0
         *  --- Post-Claim ---
         *  Loan 1:
         *    Second payment net interest accounted: 6_000sec * 0.008 = 48
         *  Loan 2:
         *    First  payment net interest claimed:   10_000sec * 0.01 = 100
         *    Second payment net interest accounted: 0sec      * 0.01 = 0
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + (48 + 60) + 40 + 80  = 1_000_228
         *  Resulting total assets: 2_000_000 + 0         + 48 + 180 = 1_000_228
         */

        /**********************/
        /*** Loan 1 Payment ***/
        /**********************/

        _makePayment({
            loanAddress:         address(loan1),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 10_000,
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       32 + 40,
            accountedInterest:     48,  // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_120,
            issuanceRate:          0.018e30,
            lastUpdated:           START + 6_000,
            vestingPeriodFinish:   START + 10_000  // End of loan1 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan1),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_120);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan1));

        _assertLoanInfo({
            loanAddress:         address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     40,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_040,
            issuanceRate:          0.018e30,
            lastUpdated:           START + 10_000,
            vestingPeriodFinish:   START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan1),
            loanBalance:        0,
            poolBalance:        80,
            poolManagerBalance: 20
        });

        _assertTotalAssets(2_000_120);

        /**********************/
        /*** Loan 2 Payment ***/
        /**********************/

        _makePayment({
            loanAddress:         address(loan2),
            interestAmount:      125,
            principalAmount:     0,
            nextInterestPayment: 125,
            paymentTimestamp:    START + 16_000,
            nextPaymentDueDate:  START + 26_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 6_000,
            paymentDueDate:      START + 16_000
        });

        _assertLoanManagerState({
            accruedInterest:       48 + 60,
            accountedInterest:     40,  // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_148,
            issuanceRate:          0.018e30,
            lastUpdated:           START + 10_000,
            vestingPeriodFinish:   START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan2),
            loanBalance:        125,
            poolBalance:        80,
            poolManagerBalance: 20
        });

        _assertTotalAssets(2_000_228);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan2));

        _assertLoanInfo({
            loanAddress:         address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 16_000,
            paymentDueDate:      START + 26_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     48,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_048,
            issuanceRate:          0.018e30,
            lastUpdated:           START + 16_000,
            vestingPeriodFinish:   START + 20_000  // End of loan2 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan2),
            loanBalance:        0,
            poolBalance:        180,  // 80 from first payment, 100 from second payment.
            poolManagerBalance: 45
        });

        _assertTotalAssets(2_000_228);
    }

    function test_claim_earlyPayment_interestOnly_onTimePayment_interestOnly() external {
        /**
         *  ***********************************
         *  *** Loan 1 Payment (t = 8_000) ***
         *  ***********************************
         *  --- Pre-Claim ---
         *  Loan 1:
         *    First  payment net interest accounted: 6_000sec * 0.008 = 48 (Accounted during loan2 funding)
         *    First  payment net interest accrued:   2_000sec * 0.008 = 16
         *  Loan 2:
         *    First payment net interest accrued: 2_000sec * 0.01 = 20
         *  --- Post-Claim ---
         *  Loan 1:
         *    First  payment net interest claimed:   10_000sec * 0.008 = 80
         *    Second payment net interest accounted: 0sec      * 0.008 = 0
         *  Loan 2:
         *    First payment net interest accounted: 2_000sec * 0.01 = 20
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + (16 + 20) + 48 + 0  = 2_000_084
         *  Resulting total assets: 2_000_000 + 0         + 20 + 80 = 2_000_100
         *
         *  ***********************************
         *  *** Loan 2 Payment (t = 16_000) ***
         *  ***********************************
         *  --- Pre-Claim ---
         *  Loan 1:
         *    Second payment net interest accrued: 8_000sec * (80/12_000) = 53
         *  Loan 2:
         *    First  payment net interest accounted: 2_000sec * 0.01 = 20 (Accounted during loan1 payment)
         *    First  payment net interest accrued:   8_000sec * 0.01 = 80
         *    Second payment net interest accrued:   0sec     * 0.01 = 0
         *  --- Post-Claim ---
         *  Loan 1:
         *    Second payment net interest accounted: 8_000sec * (80/12_000) = 53
         *  Loan 2:
         *    First  payment net interest claimed:   10_000sec * 0.01 = 100
         *    Second payment net interest accounted: 0sec      * 0.01 = 0
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + (53 + 80) + 20 + 80  = 1_000_233
         *  Resulting total assets: 2_000_000 + 0         + 53 + 180 = 1_000_233
         */

        /**********************/
        /*** Loan 1 Payment ***/
        /**********************/

        _makePayment({
            loanAddress:         address(loan1),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 8_000,
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       16 + 20,
            accountedInterest:     48,  // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_084,
            issuanceRate:          0.018e30,
            lastUpdated:           START + 6_000,
            vestingPeriodFinish:   START + 10_000  // End of loan1 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan1),
            loanBalance:        100,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_084);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan1));

        _assertLoanInfo({
            loanAddress:         address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 8_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     20,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_020,
            issuanceRate:          0.016666666666666666666666666666e30,  // 0.01 + 80/12_000 = 0.0166...
            lastUpdated:           START + 8_000,
            vestingPeriodFinish:   START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan1),
            loanBalance:        0,
            poolBalance:        80,
            poolManagerBalance: 20
        });

        _assertTotalAssets(2_000_100);

        /**********************/
        /*** Loan 2 Payment ***/
        /**********************/

        _makePayment({
            loanAddress:         address(loan2),
            interestAmount:      125,
            principalAmount:     0,
            nextInterestPayment: 125,
            paymentTimestamp:    START + 16_000,
            nextPaymentDueDate:  START + 26_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 6_000,
            paymentDueDate:      START + 16_000
        });

        _assertLoanManagerState({
            accruedInterest:       53 + 80,
            accountedInterest:     20,  // Accounted during loan1 payment.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_153,
            issuanceRate:          0.016666666666666666666666666666e30,  // 0.01 + 80/12_000 = 0.0166...
            lastUpdated:           START + 8_000,
            vestingPeriodFinish:   START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan2),
            loanBalance:        125,
            poolBalance:        80,
            poolManagerBalance: 20
        });

        _assertTotalAssets(2_000_233);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan2));

        _assertLoanInfo({
            loanAddress:         address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 16_000,
            paymentDueDate:      START + 26_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     53,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_053,
            issuanceRate:          0.016666666666666666666666666666e30,  // 0.01 + 80/12_000 = 0.0166...
            lastUpdated:           START + 16_000,
            vestingPeriodFinish:   START + 20_000  // End of loan2 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan2),
            loanBalance:        0,
            poolBalance:        180,  // 80 from first payment, 100 from second payment.
            poolManagerBalance: 45
        });

        _assertTotalAssets(2_000_233);
    }

    function test_claim_latePayment_interestOnly_onTimePayment_interestOnly() external {
        /**
         *  ***********************************
         *  *** Loan 1 Payment (t = 12_000) ***
         *  ***********************************
         *  --- Pre-Claim ---
         *  Loan 1:
         *    First payment net interest accounted: 6_000sec * 0.008 = 48 (Accounted during loan2 funding)
         *    First payment net interest accrued:   4_000sec * 0.008 = 32
         *  Loan 2:
         *    First payment net interest accrued: 4_000sec * 0.01 = 40  (Only accrues until loan1 due date)
         *  --- Post-Claim ---
         *  Loan 1:
         *    First  payment net interest claimed:   (10_000sec * 0.008) + (2_000sec * 0.012) = 104
         *    Second payment net interest accounted:  2_000sec  * 0.008                    = 16
         *  Loan 2:
         *    First payment net interest accounted: 6_000sec * 0.01 = 60
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + (32 + 40) + 48        + 0   = 2_000_120
         *  Resulting total assets: 2_000_000 + 0         + (16 + 60) + 104 = 2_000_180
         *
         *  ***********************************
         *  *** Loan 2 Payment (t = 16_000) ***
         *  ***********************************
         *  --- Pre-Claim ---
         *  Loan 1:
         *    Second payment net interest accounted: 2_000sec * 0.008 = 16
         *    Second payment net interest accrued:   4_000sec * 0.008 = 32
         *  Loan 2:
         *    First  payment net interest accounted: 6_000sec * 0.01 = 60 (Accounted during loan1 claim)
         *    First  payment net interest accrued:   4_000sec * 0.01 = 40
         *    Second payment net interest accrued:   0sec     * 0.01 = 0
         *  --- Post-Claim ---
         *  Loan 1:
         *    Second payment net interest accounted: 6_000sec * 0.008 = 48
         *  Loan 2:
         *    First  payment net interest claimed:   10_000sec * 0.01 = 100
         *    Second payment net interest accounted: 0sec      * 0.01 = 0
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + (32 + 40) + (16 + 60) + 104 = 2_000_252
         *  Resulting total assets: 2_000_000 + 48        + 0         + 204 = 2_000_252
         */

        /**********************/
        /*** Loan 1 Payment ***/
        /**********************/

        _makePayment({
            loanAddress:         address(loan1),
            interestAmount:      130,  // ((10_000 * 0.008) + (2_000 * 0.012)) / 0.8 = 130 (gross late interest)
            principalAmount:     0,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 12_000,
            nextPaymentDueDate:  START + 20_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       32 + 40,
            accountedInterest:     48,  // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_120,
            issuanceRate:          0.018e30,
            lastUpdated:           START + 6_000,
            vestingPeriodFinish:   START + 10_000  // End of loan1 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan1),
            loanBalance:        130,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_120);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan1));

        _assertLoanInfo({
            loanAddress:         address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     16 + 60,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_076,
            issuanceRate:          0.018e30,  // Not early so use same interval, causing same exchange rate
            lastUpdated:           START + 12_000,
            vestingPeriodFinish:   START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan1),
            loanBalance:        0,
            poolBalance:        104,  // 130 * 0.8 = 104
            poolManagerBalance: 26    // 130 * 0.2 = 26
        });

        _assertTotalAssets(2_000_180);

        /**********************/
        /*** Loan 2 Payment ***/
        /**********************/

        _makePayment({
            loanAddress:         address(loan2),
            interestAmount:      125,
            principalAmount:     0,
            nextInterestPayment: 125,
            paymentTimestamp:    START + 16_000,
            nextPaymentDueDate:  START + 26_000
        });

        _assertLoanInfo({
            loanAddress:         address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 6_000,
            paymentDueDate:      START + 16_000
        });

        _assertLoanManagerState({
            accruedInterest:       32 + 40,
            accountedInterest:     16 + 60,  // Accounted during loan1 payment.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_148,
            issuanceRate:          0.018e30,
            lastUpdated:           START + 12_000,
            vestingPeriodFinish:   START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan2),
            loanBalance:        125,
            poolBalance:        104,
            poolManagerBalance: 26
        });

        _assertTotalAssets(2_000_252);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan2));

        _assertLoanInfo({
            loanAddress:         address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START + 16_000,
            paymentDueDate:      START + 26_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     48,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_048,
            issuanceRate:          0.018e30,
            lastUpdated:           START + 16_000,
            vestingPeriodFinish:   START + 20_000  // End of loan2 payment interval
        });

        _assertBalances({
            loanAddress:        address(loan2),
            loanBalance:        0,
            poolBalance:        204,  // 104 from first payment, 100 from second payment.
            poolManagerBalance: 51
        });

        _assertTotalAssets(2_000_252);
    }

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

// TODO: Create mock refinance interest values
// TODO: Add fuzzing to automate amortized tests
contract RefinanceAccountingSingleLoanTests is LoanManagerClaimBaseTest {

    MockLoan loan;

    // Refinance
    address refinancer = address(new Address());

    function setUp() public override {
        super.setUp();

        loan = new MockLoan(address(asset), address(asset));

        // Setup next payment information
        loan.__setPrincipal(1_000_000);
        loan.__setPrincipalRequested(1_000_000);
        loan.__setNextPaymentInterest(125);
        loan.__setNextPaymentDueDate(START + 10_000);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));

        // On this suite, pools have a total of 2_000_000 to facilitate funding + refinance
        asset.mint(address(pool), 1_000_000);
    }

    function test_refinance_onLoanPaymentDueDate_interestOnly() external {
        /**
         *  *************************************************************
         *  *** Loan Issuance Rate = (125 * 0.8) / 10_000 = 0.01/sec ***
         *  *************************************************************
         *  ***************************************************************************
         *  *** Refinance                                                           ***
         *  *** Principal: 1m => 2m, Incoming Interest: 100 => 300, IR 0.01 => 0.03 ***
         *  ***************************************************************************
         *  *********************************
         *  *** Loan Payment (t = 10_000) ***
         *  *********************************
         *  --- Pre-Refinance ---
         *  First payment net interest accounted: 0
         *  First payment net interest accrued:   10_000sec * 0.01 = 100
         *  --- Post-Refinance ---
         *  First  payment net interest claimed:  10_000sec * 0.01 = 100
         *  Second payment net interest accounted: 0
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 1_000_000 + 100 + 0   + 1_000_000 = 2_000_0100
         *  Resulting total assets: 2_000_000 + 0   + 100 + 0         = 2_000_0100
         *
         *  ********************************
         *  *** Loan Payment (t = 20_000) ***
         *  ********************************
         *  --- Pre-Claim ---
         *  Second payment net interest accounted: 0
         *  Second payment net interest accrued:   10_000sec * 0.03 = 300
         *  --- Post-Claim ---
         *  Second payment net interest claimed:   10_000sec * 0.03 = 300
         *  Second payment net interest accounted: 0
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + 300 + 100 + 0   = 2_000_400
         *  Resulting total assets: 2_000_000 + 0   + 0   + 400 = 2_000_400
         */

        vm.warp(START + 10_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       100,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_100,
            issuanceRate:          0.01e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        1_000_000,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_100);

        // Set Refinance values
        loan.__setRefinanceInterest(125);  // Accrued gross interest from first payment cycle (accounted for in real loan).
        loan.__setRefinancePrincipal(2_000_000);
        loan.__setPrincipalRequested(2_000_000);
        loan.__setRefinanceNextPaymentInterest(375);
        loan.__setRefinanceNextPaymentDueDate(START + 20_000);

        vm.warp(START + 10_000);

        // Burn from the pool to simulate fund
        asset.burn(address(pool), 1_000_000);

        vm.prank(address(poolManager));
        loanManager.acceptNewTerms(address(loan), address(refinancer), block.timestamp, new bytes[](0));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   100,
            principalOf_loan:    2_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     100,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_100,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 10_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_100);

        // Make a refinanced payment and claim
        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      375 + 125,
            principalAmount:     0,
            nextInterestPayment: 375,
            paymentTimestamp:    START + 20_000,
            nextPaymentDueDate:  START + 30_000
        });

        loan.__setRefinanceInterest(0);  // Set refinance interest to zero after payment is made.

        _assertLoanManagerState({
            accruedInterest:       300,
            accountedInterest:     100,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_400,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 10_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        375 + 125,  // Principal + interest + refinance interest
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_400);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   0,
            principalOf_loan:    2_000_000,
            startDate:           START + 20_000,
            paymentDueDate:      START + 30_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_000,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 20_000,
            vestingPeriodFinish:   START + 30_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        100 + 300,
            poolManagerBalance: 25 + 75
        });

        _assertTotalAssets(2_000_400);
    }

    function test_refinance_beforeLoanDueDate_interestOnly() external {
        /**
         *  *************************************************************
         *  *** Loan Issuance Rate = (125 * 0.8) / 10_000 = 0.01/sec ***
         *  *************************************************************
         *  ***************************************************************************
         *  *** Refinance                                                           ***
         *  *** Principal: 1m => 2m, Incoming Interest: 100 => 300, IR 0.01 => 0.03 ***
         *  ***************************************************************************
         *  *****************************
         *  *** Refinance (t = 6_000) ***
         *  *****************************
         *  --- Pre-Refinance ---
         *  First payment net interest accounted: 0
         *  First payment net interest accrued:   6_000sec * 0.01  = 60
         *  --- Post-Refinance ---
         *  First payment net interest accounted: 6_000sec * 0.01 = 60
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 1_000_000 + 60 + 0  + 1_000_000 = 2_000_060
         *  Resulting total assets: 2_000_000 + 0  + 60 + 0         = 2_000_060
         *
         *  *********************************
         *  *** Loan Payment (t = 16_000) ***
         *  *********************************
         *  --- Pre-Claim ---
         *  Second payment net interest accounted: 0
         *  Second payment net interest accrued:   10_000sec * 0.03 = 300
         *  --- Post-Claim ---
         *  Second payment net interest claimed:   10_000sec * 0.03 = 300
         *  Secpnd payment net interest accounted: 0
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + 300 + 60 + 0   = 2_000_360
         *  Resulting total assets: 2_000_000 + 0   + 0  + 360 = 2_000_360
         */

        vm.warp(START + 6_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       60,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_060,
            issuanceRate:          0.01e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        1_000_000,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_060);

        // Set Refinance values
        loan.__setRefinanceInterest(75);  // Accrued gross interest from first payment cycle (accounted for in real loan).
        loan.__setRefinancePrincipal(2_000_000);
        loan.__setPrincipalRequested(2_000_000);
        loan.__setRefinanceNextPaymentInterest(375);
        loan.__setRefinanceNextPaymentDueDate(START + 16_000);

        asset.burn(address(pool), 1_000_000);  // Burn from the pool to simulate fund and drawdown.

        vm.prank(address(poolManager));
        loanManager.acceptNewTerms(address(loan), address(refinancer), block.timestamp, new bytes[](0));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   60,
            principalOf_loan:    2_000_000,
            startDate:           START + 6_000,
            paymentDueDate:      START + 16_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     60,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_060,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 6_000,
            vestingPeriodFinish:   START + 16_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_060);

        // Make a refinanced payment and claim
        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      375 + 75,  // Interest plus refinance interest.
            principalAmount:     0,
            nextInterestPayment: 375,
            paymentTimestamp:    START + 16_000,
            nextPaymentDueDate:  START + 26_000
        });

        _assertLoanManagerState({
            accruedInterest:       300,
            accountedInterest:     60,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_360,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 6_000,
            vestingPeriodFinish:   START + 16_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        375 + 75,  // Principal + interest + refinance interest
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_360);

        loan.__setRefinanceInterest(0);  // Set to 0 to simulate a refinance that has been paid off.

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   0,
            principalOf_loan:    2_000_000,
            startDate:           START + 16_000,
            paymentDueDate:      START + 26_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_000,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 16_000,
            vestingPeriodFinish:   START + 26_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        60 + 300,
            poolManagerBalance: 15 + 75
        });

        _assertTotalAssets(2_000_360);
    }

    function test_refinance_onLatePayment_interestOnly() external {
        /**
         *  *************************************************************
         *  *** Loan Issuance Rate = (125 * 0.8) / 10_000 = 0.01/sec ***
         *  *************************************************************
         *  ***************************************************************************
         *  *** Refinance                                                           ***
         *  *** Principal: 1m => 2m, Incoming Interest: 100 => 300, IR 0.01 => 0.03 ***
         *  ***************************************************************************
         *  ***********************************
         *  *** Refinance (t = 14_000) Late ***
         *  ***********************************
         *  --- Pre-Refinance ---
         *  First payment net interest accounted: 0
         *  First payment net interest accrued:   10_000sec * 0.01 = 100
         *  --- Post-Refinance ---
         *  First payment net interest accounted: (10_000sec * 0.01 + 4000sec * 0.012) = 148 (`refinanceInterest` in loan will capture late fees and allow LM to account for them)
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 1_000_000 + 100 + 0   + 1_000_000 = 2_000_100
         *  Resulting total assets: 2_000_000 + 0   + 148 + 0         = 2_000_148
         *
         *  *********************************
         *  *** Loan Payment (t = 24_000) ***
         *  *********************************
         *  --- Pre-Claim ---
         *  Second payment net interest accounted: 0
         *  Second payment net interest accrued:   10_000sec * 0.03 = 300
         *  --- Post-Claim ---
         *  Second payment net interest claimed:   10_000sec * 0.03 = 300
         *  Second payment net interest accounted: 0
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + 300 + 148 + 0   = 2_000_448
         *  Resulting total assets: 2_000_000 + 0   + 0   + 448 = 2_000_448
         */

        vm.warp(START + 14_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       100,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_100,
            issuanceRate:          0.01e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        1_000_000,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_100);

        // Set Refinance values
        loan.__setRefinanceInterest(185);  // Accrued gross interest from first payment cycle (accounted for in real loan).
        loan.__setRefinancePrincipal(2_000_000);
        loan.__setPrincipalRequested(2_000_000);
        loan.__setRefinanceNextPaymentInterest(375);
        loan.__setRefinanceNextPaymentDueDate(START + 24_000); // The payment schedule restarts at refinance

        asset.burn(address(pool), 1_000_000);

        vm.prank(address(poolManager));
        loanManager.acceptNewTerms(address(loan), address(refinancer), block.timestamp, new bytes[](0));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   148,
            principalOf_loan:    2_000_000,
            startDate:           START + 14_000,
            paymentDueDate:      START + 24_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     148,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_148,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 14_000,
            vestingPeriodFinish:   START + 24_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_148);

        // Make a refinanced payment and claim
        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      375 + 185,  // Interest plus refinance interest.
            principalAmount:     0,
            nextInterestPayment: 375,
            paymentTimestamp:    START + 24_000,
            nextPaymentDueDate:  START + 34_000
        });

        loan.__setRefinanceInterest(0);  // Set refinance interest to zero after payment is made.

        _assertLoanManagerState({
            accruedInterest:       300,
            accountedInterest:     148,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_448,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 14_000,
            vestingPeriodFinish:   START + 24_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        375 + 185,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_448);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   0,
            principalOf_loan:    2_000_000,
            startDate:           START + 24_000,
            paymentDueDate:      START + 34_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_000,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 24_000,
            vestingPeriodFinish:   START + 34_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        300 + 148,
            poolManagerBalance: 75  + 37
        });

        _assertTotalAssets(2_000_448);
    }

    function test_refinance_onPaymentDueDate_amortized() external {
         /**
         *  *************************************************************
         *  *** Loan Issuance Rate = (125 * 0.8) / 10_000 = 0.01/sec ***
         *  *************************************************************
         *  ***************************************************************************
         *  *** Refinance                                                           ***
         *  *** Principal: 1m => 2m, Incoming Interest: 100 => 300, IR 0.01 => 0.03 ***
         *  ***************************************************************************
         *  ********************************
         *  *** Loan Payment (t = 10_000) ***
         *  ********************************
         *  --- Pre-Refinance ---
         *  First payment net interest accounted: 0
         *  First payment net interest accrued:   10_000sec * 0.01 = 100
         *  --- Post-Refinance ---
         *  First payment net interest accounted: 10_000sec * 0.01 = 100
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 1_000_000 + 100 + 0   + 1_000_000 = 2_000_100
         *  Resulting total assets: 2_000_000 + 0   + 100 + 0         = 2_000_100
         *
         *  ********************************
         *  *** Loan Payment (t = 20_000) ***
         *  ********************************
         *  --- Pre-Claim ---
         *  Second payment net interest accounted: 0
         *  Second payment net interest accrued:   10_000sec * 0.03 = 300
         *  --- Post-Claim ---
         *  Second payment principa; claimed:      200_000
         *  Second payment net interest claimed:   10_000sec * 0.03 = 300
         *  Second payment net interest accounted: 0
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + 300 + 100 + 0       = 2_000_400
         *  Resulting total assets: 1_800_000 + 0   + 0   + 200_400 = 2_000_400
         */

        vm.warp(START + 10_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            principalOf_loan:    1_000_000,
            startDate:           START,
            paymentDueDate:      START + 10_000
        });

        _assertLoanManagerState({
            accruedInterest:       100,  // 0.008 * 10_000 = 80
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_100,
            issuanceRate:          0.01e30,
            lastUpdated:           START,
            vestingPeriodFinish:   START + 10_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        1_000_000,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_100);

        // Set Refinance values
        loan.__setRefinanceInterest(125);
        loan.__setRefinancePrincipal(2_000_000);
        loan.__setPrincipalRequested(2_000_000);
        loan.__setRefinanceNextPaymentInterest(375);
        loan.__setRefinanceNextPaymentDueDate(START + 20_000);

        vm.prank(address(poolManager));
        loanManager.acceptNewTerms(address(loan), address(refinancer), block.timestamp, new bytes[](0));

        asset.burn(address(pool), 1_000_000);

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   100,
            principalOf_loan:    2_000_000,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     100,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_100,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 10_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_100);

        // Make a payment post refinance
        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      375 + 125,  // Interest plus refiance interest
            principalAmount:     200_000,
            nextInterestPayment: 375,
            paymentTimestamp:    START + 20_000,
            nextPaymentDueDate:  START + 30_000
        });

        loan.__setRefinanceInterest(0);  // Set refinance interest to zero after payment is made.

        _assertLoanManagerState({
            accruedInterest:       300,
            accountedInterest:     100,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_400,
            issuanceRate:          0.03e30,
            lastUpdated:           START + 10_000,
            vestingPeriodFinish:   START + 20_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        200_000 + 375 + 125,
            poolBalance:        0,
            poolManagerBalance: 0
        });

        _assertTotalAssets(2_000_400);

        vm.prank(address(poolManager));
        loanManager.claim(address(loan));

        _assertLoanInfo({
            loanAddress:         address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   0,
            principalOf_loan:    1_800_000,
            startDate:           START + 20_000,
            paymentDueDate:      START + 30_000
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          1_800_000,
            assetsUnderManagement: 1_800_000,
            issuanceRate:          0.03e30,         // 240 interest over 1000 seconds
            lastUpdated:           START + 20_000,
            vestingPeriodFinish:   START + 30_000
        });

        _assertBalances({
            loanAddress:        address(loan),
            loanBalance:        0,
            poolBalance:        300 + 100 + 200_000,
            poolManagerBalance: 75 + 25
        });

        _assertTotalAssets(2_000_400);
    }

}

contract TriggerCollateralLiquidationTests is LoanManagerBaseTest {

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

    function test_triggerCollateralLiquidation_notManager() public {
        // NOTE: The next two lines of code are unnecessary, as loan.repossess() is mocked, but simulate the real preconditions for this function to be called.
        uint256 nextPaymentDueDate = MockLoan(loan).nextPaymentDueDate();
        vm.warp(nextPaymentDueDate);

        vm.expectRevert("LM:TCL:NOT_POOL_MANAGER");
        loanManager.triggerCollateralLiquidation(address(loan));

        vm.prank(address(poolManager));
        loanManager.triggerCollateralLiquidation(address(loan));
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
            uint256 refinanceInterest_,
            ,
            uint256 startDate_,
            uint256 paymentDueDate_,
            uint256 managementFee_,
            address vehicle_
        ) = loanManager.loans(1);

        assertEq(incomingNetInterest_, 0);
        assertEq(refinanceInterest_, 0);
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
            refinanceInterest_,
            ,
            startDate_,
            paymentDueDate_,
            managementFee_,
            vehicle_
        ) = loanManager.loans(1);

        // Check loan information
        assertEq(incomingNetInterest_, 0.8e18); // 1e18 of interest minus management fees
        assertEq(startDate_,           block.timestamp);
        assertEq(paymentDueDate_,      block.timestamp + 100);
        assertEq(managementFee_,       managementFee);
        assertEq(vehicle_,             address(loan));

        assertEq(loanManager.principalOut(),        principalRequested);
        assertEq(loanManager.accountedInterest(),   0);
        assertEq(loanManager.issuanceRate(),        0.8e46);  // 0.7e18 * 1e30 / 100 = 0.7e46
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
        loanManager.addLoanToList(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);
    }

    function test_addLoan_ascendingPair() external {
        loanManager.addLoanToList(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoanToList(latestLoan);

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
        loanManager.addLoanToList(latestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(latestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  latestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoanToList(earliestLoan);

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
        loanManager.addLoanToList(medianLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(medianLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoanToList(synchronizedLoan);

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
        loanManager.addLoanToList(medianLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(medianLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  medianLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoanToList(latestLoan);

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

        loanManager.addLoanToList(earliestLoan);

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
        loanManager.addLoanToList(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoanToList(latestLoan);

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

        loanManager.addLoanToList(medianLoan);

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
        loanManager.addLoanToList(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoanToList(medianLoan);

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

        loanManager.addLoanToList(latestLoan);

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

    // TODO: Add test back
    // TODO: Add recognizeLoanPayment coverage
    function skiptest_removeLoan_invalidAddress() external {
        address nonExistingVehicle = address(new Address());

        vm.expectRevert(ZERO_DIVISION);
        loanManager.recognizeLoanPayment(nonExistingVehicle);
    }

    function test_removeLoan_single() external {
        loanManager.addLoanToList(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.recognizeLoanPayment(earliestLoan.vehicle);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 0);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 0);

        assertEq(loanManager.loan(1).vehicle,  address(0));
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);
    }

    function test_removeLoan_pair() external {
        loanManager.addLoanToList(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoanToList(latestLoan);

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

        loanManager.recognizeLoanPayment(earliestLoan.vehicle);

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
        loanManager.addLoanToList(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoanToList(medianLoan);

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

        loanManager.addLoanToList(latestLoan);

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

        loanManager.recognizeLoanPayment(earliestLoan.vehicle);

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
        loanManager.addLoanToList(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoanToList(medianLoan);

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

        loanManager.addLoanToList(latestLoan);

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

        loanManager.recognizeLoanPayment(medianLoan.vehicle);

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
        loanManager.addLoanToList(earliestLoan);

        assertEq(loanManager.loanCounter(),                    1);
        assertEq(loanManager.loanWithEarliestPaymentDueDate(), 1);

        assertEq(loanManager.loanIdOf(earliestLoan.vehicle), 1);

        assertEq(loanManager.loan(1).vehicle,  earliestLoan.vehicle);
        assertEq(loanManager.loan(1).next,     0);
        assertEq(loanManager.loan(1).previous, 0);

        loanManager.addLoanToList(medianLoan);

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

        loanManager.addLoanToList(latestLoan);

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

        loanManager.recognizeLoanPayment(latestLoan.vehicle);

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
