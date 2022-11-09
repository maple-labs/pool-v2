// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, console, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { LoanManagerFactory }     from "../contracts/proxy/LoanManagerFactory.sol";
import { LoanManagerInitializer } from "../contracts/proxy/LoanManagerInitializer.sol";

import {
    MockFactory,
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

import { ILoanManagerStructs } from "./interfaces/ILoanManagerStructs.sol";

import { LoanManagerHarness } from "./harnesses/LoanManagerHarness.sol";

contract LoanManagerBaseTest is TestUtils {

    uint256 constant START = 5_000_000;

    address governor     = address(new Address());
    address poolDelegate = address(new Address());
    address treasury     = address(new Address());

    address implementation = address(new LoanManagerHarness());
    address initializer    = address(new LoanManagerInitializer());

    uint256 platformManagementFeeRate = 5_0000;
    uint256 delegateManagementFeeRate = 15_0000;

    MockERC20       collateralAsset;
    MockERC20       fundsAsset;
    MockFactory     liquidatorFactory;
    MockGlobals     globals;
    MockPool        pool;
    MockPoolManager poolManager;

    LoanManagerFactory factory;
    LoanManagerHarness loanManager;

    function setUp() public virtual {
        collateralAsset   = new MockERC20("CollateralAsset", "COL", 18);
        fundsAsset        = new MockERC20("FundsAsset",      "FUN", 18);
        globals           = new MockGlobals(governor);
        liquidatorFactory = new MockFactory();
        poolManager       = new MockPoolManager();
        pool              = new MockPool();

        globals.setMapleTreasury(treasury);

        pool.__setAsset(address(fundsAsset));
        pool.__setManager(address(poolManager));

        poolManager.__setGlobals(address(globals));
        poolManager.__setPoolDelegate(poolDelegate);

        vm.startPrank(governor);
        factory = new LoanManagerFactory(address(globals));
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        MockGlobals(globals).setValidPoolDeployer(address(this), true);
        MockGlobals(globals).setPlatformManagementFeeRate(address(poolManager), platformManagementFeeRate);
        poolManager.setDelegateManagementFeeRate(delegateManagementFeeRate);

        bytes memory arguments = LoanManagerInitializer(initializer).encodeArguments(address(pool));
        loanManager = LoanManagerHarness(LoanManagerFactory(factory).createInstance(arguments, ""));

        vm.warp(START);
    }

    function _assertLiquidationInfo(
        ILoanManagerStructs.LiquidationInfo memory liquidationInfo,
        uint256 principal,
        uint256 interest,
        uint256 lateInterest,
        uint256 platformFees,
        address liquidator
    ) internal {
        assertEq(liquidationInfo.principal,    principal);
        assertEq(liquidationInfo.interest,     interest);
        assertEq(liquidationInfo.lateInterest, lateInterest);
        assertEq(liquidationInfo.platformFees, platformFees);
        assertEq(liquidationInfo.liquidator,   liquidator);
    }
}

contract MigrateTests is LoanManagerBaseTest {

    address migrator = address(new MockLoanManagerMigrator());

    function test_migrate_protocolPaused() external {
        globals.__setProtocolPaused(true);

        vm.expectRevert("LM:M:PROTOCOL_PAUSED");
        loanManager.migrate(migrator, "");
    }

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
        assertEq(loanManager.fundsAsset(), address(fundsAsset));

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
        vm.expectRevert("LM:U:NOT_AUTHORIZED");
        loanManager.upgrade(2, "");
    }

    function test_upgrade_notScheduled() external {
        vm.prank(poolManager.poolDelegate());
        vm.expectRevert("LM:U:INVALID_SCHED_CALL");
        loanManager.upgrade(2, "");
    }

    function test_upgrade_upgradeFailed() external {
        MockGlobals(globals).__setIsValidScheduledCall(true);
        vm.prank(poolManager.poolDelegate());
        vm.expectRevert("MPF:UI:FAILED");
        loanManager.upgrade(2, "1");
    }

    function test_upgrade_successWithGovernor() external {
        // No need to schedule call
        vm.prank(governor);
        loanManager.upgrade(2, "");

        assertEq(loanManager.implementation(), newImplementation);
    }

    function test_upgrade_success() external {
        MockGlobals(globals).__setIsValidScheduledCall(true);
        vm.prank(poolManager.poolDelegate());
        loanManager.upgrade(2, "");

        assertEq(loanManager.implementation(), newImplementation);
    }

}

contract SetAllowedSlippage_SetterTests is LoanManagerBaseTest {

    function test_setAllowedSlippage_notPoolManager() external {
        vm.expectRevert("LM:SAS:NOT_POOL_MANAGER");
        loanManager.setAllowedSlippage(address(collateralAsset), 1e6);
    }

    function test_setAllowedSlippage_invalidSlippage() external {
        vm.prank(address(poolManager));
        vm.expectRevert("LM:SAS:INVALID_SLIPPAGE");
        loanManager.setAllowedSlippage(address(collateralAsset), 1e6 + 1);
    }

    function test_setAllowedSlippage_success() external {
        assertEq(loanManager.allowedSlippageFor(address(collateralAsset)), 0);

        vm.prank(address(poolManager));
        loanManager.setAllowedSlippage(address(collateralAsset), 1e6);

        assertEq(loanManager.allowedSlippageFor(address(collateralAsset)), 1e6);

        vm.prank(address(poolManager));
        loanManager.setAllowedSlippage(address(collateralAsset), 0);

        assertEq(loanManager.allowedSlippageFor(address(collateralAsset)), 0);
    }

}

contract SetMinRatio_SetterTests is LoanManagerBaseTest {

    function test_setMinRatio_notPoolManager() external {
        vm.expectRevert("LM:SMR:NOT_POOL_MANAGER");
        loanManager.setMinRatio(address(collateralAsset), 1e6);
    }

    function test_setMinRatio_success() external {
        assertEq(loanManager.minRatioFor(address(collateralAsset)), 0);

        vm.prank(address(poolManager));
        loanManager.setMinRatio(address(collateralAsset), 1e6);

        assertEq(loanManager.minRatioFor(address(collateralAsset)), 1e6);

        vm.prank(address(poolManager));
        loanManager.setMinRatio(address(collateralAsset), 0);

        assertEq(loanManager.minRatioFor(address(collateralAsset)), 0);
    }

}

contract LoanManagerClaimBaseTest is LoanManagerBaseTest {

    function _assertBalances(uint256 poolBalance, uint256 treasuryBalance, uint256 poolDelegateBalance) internal {
        assertEq(fundsAsset.balanceOf(address(pool)),         poolBalance);
        assertEq(fundsAsset.balanceOf(address(treasury)),     treasuryBalance);
        assertEq(fundsAsset.balanceOf(address(poolDelegate)), poolDelegateBalance);
    }

    function _assertPaymentInfo(
        address loan,
        uint256 incomingNetInterest,
        uint256 refinanceInterest,
        uint256 startDate,
        uint256 paymentDueDate,
        uint256 issuanceRate
    )
        internal
    {
        ( , , uint256 startDate_, uint256 paymentDueDate_, uint256 incomingNetInterest_, uint256 refinanceInterest_, uint256 issuanceRate_ ) = loanManager.payments(loanManager.paymentIdOf(loan));

        assertEq(incomingNetInterest_, incomingNetInterest);
        assertEq(refinanceInterest_,   refinanceInterest);
        assertEq(startDate_,           startDate);
        assertEq(paymentDueDate_,      paymentDueDate);
        assertEq(issuanceRate_,        issuanceRate);
    }

    function _assertLoanManagerState(
        uint256 accruedInterest,
        uint256 accountedInterest,
        uint256 principalOut,
        uint256 assetsUnderManagement,
        uint256 issuanceRate,
        uint256 domainStart,
        uint256 domainEnd
    )
        internal
    {
        assertEq(loanManager.getAccruedInterest(),    accruedInterest);
        assertEq(loanManager.accountedInterest(),     accountedInterest);
        assertEq(loanManager.principalOut(),          principalOut);
        assertEq(loanManager.assetsUnderManagement(), assetsUnderManagement);
        assertEq(loanManager.issuanceRate(),          issuanceRate);
        assertEq(loanManager.domainStart(),           domainStart);
        assertEq(loanManager.domainEnd(),             domainEnd);
    }

    function _assertTotalAssets(uint256 totalAssets) internal {
        assertEq(loanManager.assetsUnderManagement() + fundsAsset.balanceOf(address(pool)), totalAssets);
    }

    function _makeLatePayment(
        address loan,
        uint256 interestAmount,
        uint256 lateInterestAmount,
        uint256 principalAmount,
        uint256 nextInterestPayment,
        uint256 nextPaymentDueDate
    )
        public
    {
        MockLoan mockLoan = MockLoan(loan);

        fundsAsset.mint(address(loanManager), interestAmount + lateInterestAmount + principalAmount);
        mockLoan.__setPrincipal(mockLoan.principal() - principalAmount);
        mockLoan.__setNextPaymentInterest(nextInterestPayment);
        mockLoan.__setNextPaymentLateInterest(lateInterestAmount);

        uint256 previousPaymentDueDate = mockLoan.nextPaymentDueDate();

        mockLoan.__setNextPaymentDueDate(nextPaymentDueDate);

        vm.prank(loan);
        LoanManager(loanManager).claim(principalAmount, interestAmount + lateInterestAmount, previousPaymentDueDate, nextPaymentDueDate);
    }

    function _makePayment(
        address loan,
        uint256 interestAmount,
        uint256 principalAmount,
        uint256 nextInterestPayment,
        uint256 nextPaymentDueDate
    )
        public
    {
        MockLoan mockLoan = MockLoan(loan);

        fundsAsset.mint(address(loanManager), interestAmount + principalAmount);
        mockLoan.__setPrincipal(mockLoan.principal() - principalAmount);
        mockLoan.__setNextPaymentInterest(nextInterestPayment);

        uint256 previousPaymentDueDate = mockLoan.nextPaymentDueDate();

        mockLoan.__setNextPaymentDueDate(nextPaymentDueDate);

        vm.prank(loan);
        LoanManager(loanManager).claim(principalAmount, interestAmount, previousPaymentDueDate, nextPaymentDueDate);
    }

}

contract ClaimTests is LoanManagerClaimBaseTest {

    address loan;

    function setUp() public override {
        super.setUp();

        loan = address(new MockLoan(address(collateralAsset), address(fundsAsset)));

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
        fundsAsset.mint(address(loanManager), 100);

        vm.expectRevert("LM:C:NOT_LOAN");
        loanManager.claim(0, 100, 0, START + 10_000);

        vm.prank(address(loan));
        loanManager.claim(0, 100, 0, START + 10_000);
    }
}

contract FinishCollateralLiquidationTests is LoanManagerBaseTest {

    address auctioneer;
    address loan;

    function setUp() public override {
        super.setUp();

        loan = address(new MockLoan(address(collateralAsset), address(fundsAsset)));

        // Set next payment information for loanManager to use.
        MockLoan loan_ = MockLoan(loan);
        loan_.__setPrincipal(1_000_000);
        loan_.__setPrincipalRequested(1_000_000);
        loan_.__setNextPaymentInterest(100);
        loan_.__setNextPaymentDueDate(START + 10_000);
        loan_.__setPlatformServiceFee(20);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));
    }

    function test_finishCollateralLiquidation_notManager() public {
        uint256 nextPaymentDueDate = MockLoan(loan).nextPaymentDueDate();
        vm.warp(nextPaymentDueDate);

        vm.prank(address(poolManager));
        loanManager.triggerDefault(address(loan), address(liquidatorFactory));

        vm.expectRevert("LM:FCL:NOT_POOL_MANAGER");
        loanManager.finishCollateralLiquidation(address(loan));

        vm.prank(address(poolManager));
        loanManager.finishCollateralLiquidation(address(loan));
    }

    function test_finishCollateralLiquidation_success_withCollateral() public {
        // Assume this is past the payment due date and grace period.
        vm.warp(START + 11_000);

        MockLoan(loan).__setCollateral(1_000_000);
        collateralAsset.mint(loan, 1_000_000);

        MockLoan(loan).__setNextPaymentLateInterest(10);

        vm.prank(address(poolManager));
        loanManager.triggerDefault(address(loan), address(liquidatorFactory));

        uint256 paymentId = loanManager.paymentIdOf(address(loan));

        assertEq(paymentId, 0);  // Loan should be deleted.

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          80);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_080);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_011_000);
        assertEq(loanManager.domainEnd(),                  5_011_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.unrealizedLosses(),           1_000_080);

        ILoanManagerStructs.LiquidationInfo memory liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        address liquidator = address(0x760C3B9cb28eBf12F5fd66AfED48c45a18D0b98D);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       1_000_000,
            interest:        80,
            lateInterest:    8,
            platformFees:    20 + 5,
            liquidator:      liquidator
        });

        collateralAsset.burn(liquidator, collateralAsset.balanceOf(liquidator));

        vm.prank(address(poolManager));
        ( uint256 remainingLosses_, uint256 platformFee_ ) = loanManager.finishCollateralLiquidation(address(loan));

        paymentId = loanManager.paymentIdOf(address(loan));

        assertEq(paymentId, 0);  // Loan should be deleted.

        assertEq(remainingLosses_, 1_000_088);  // No collateral was liquidated because there is none. Remaining losses include late interest.
        assertEq(platformFee_,     20 + 5);     // 20 (platform service fee) + 100 * 5% (platform management fee)

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          0);
        assertEq(loanManager.principalOut(),               0);
        assertEq(loanManager.assetsUnderManagement(),      0);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_011_000);
        assertEq(loanManager.domainEnd(),                  5_011_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.unrealizedLosses(),           0);

        liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        // NOTE: Liquidation info is cleared after liquidations occur.
        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       0,
            interest:        0,
            lateInterest:    0,
            platformFees:    0,
            liquidator:      address(0)
        });

    }

}

contract ImpairLoanTests is LoanManagerBaseTest {
    address loan;

    function setUp() public override {
        super.setUp();

        loan = address(new MockLoan(address(collateralAsset), address(fundsAsset)));

        // Set next payment information for loanManager to use.
        MockLoan loan_ = MockLoan(loan);
        loan_.__setPrincipal(1_000_000);
        loan_.__setPrincipalRequested(1_000_000);
        loan_.__setNextPaymentInterest(100);
        loan_.__setNextPaymentDueDate(START + 10_000);
        loan_.__setPlatformServiceFee(20);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));
    }

    function test_impairLoan_notManager() public {
        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        vm.expectRevert("LM:IL:NOT_PM");
        loanManager.impairLoan(address(loan), false);

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), false);
    }

    function test_impairLoan_alreadyImpaired() public {
        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), false);

        vm.prank(address(poolManager));
        vm.expectRevert("LM:IL:ALREADY_IMPAIRED");
        loanManager.impairLoan(address(loan), false);
    }

    function test_impairLoan_success() public {
        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        uint256 paymentId_ = loanManager.paymentIdOf(address(loan));
        ILoanManagerStructs.PaymentInfo memory paymentInfo = ILoanManagerStructs(address(loanManager)).payments(paymentId_);

        assertEq(paymentInfo.incomingNetInterest, 80);        // 100 * (1 - .05 + .15)
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         48);         // 60 * (1 - (.05 + .15))
        assertEq(loanManager.accountedInterest(),          0);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0.0080e30);
        assertEq(loanManager.domainStart(),                5_000_000);
        assertEq(loanManager.domainEnd(),                  5_010_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), paymentId_);

        ILoanManagerStructs.LiquidationInfo memory liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       0,
            interest:        0,
            lateInterest:    0,
            platformFees:    0,
            liquidator:      address(0)
        });

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), false);

        paymentInfo = ILoanManagerStructs(address(loanManager)).payments(paymentId_);

        // Loan info doesn't change, in case we want to revert the loan impairment.
        assertEq(paymentInfo.incomingNetInterest, 80);
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_006_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);          // Loan has been removed from list
        assertEq(loanManager.unrealizedLosses(),           1_000_048);

        liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       1_000_000,
            interest:        48,
            lateInterest:    0,
            platformFees:    20 + 3,          // 20 + (100 * 60% * 5%)  (serviceFee + accruedPlatformManagementFee)
            liquidator:      address(0)
        });

        // Warp ahead, asserting that the loan interest accruing has been paused.
        vm.warp(START + 9_000);

        assertEq(paymentInfo.incomingNetInterest, 80);
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_006_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.unrealizedLosses(),           1_000_048);

        liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       1_000_000,
            interest:        48,
            lateInterest:    0,
            platformFees:    20 + 3,  // (20 * 60%) + (100 * 60% * 5%)  (accruedPlatformServiceFee + accruedPlatformManagementFee)
            liquidator:      address(0)
        });

        assertTrue(!liquidationInfo.triggeredByGovernor);
    }

    function test_impairLoan_success_byGovernor() public {
        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        uint256 paymentId_ = loanManager.paymentIdOf(address(loan));
        ILoanManagerStructs.PaymentInfo memory paymentInfo = ILoanManagerStructs(address(loanManager)).payments(paymentId_);

        assertEq(paymentInfo.incomingNetInterest, 80);         // 100 * (1 - .05 + .15)
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         48);         // 60 * (1 - (.05 + .15))
        assertEq(loanManager.accountedInterest(),          0);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0.0080e30);
        assertEq(loanManager.domainStart(),                5_000_000);
        assertEq(loanManager.domainEnd(),                  5_010_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), paymentId_);

        ILoanManagerStructs.LiquidationInfo memory liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       0,
            interest:        0,
            lateInterest:    0,
            platformFees:    0,
            liquidator:      address(0)
        });

        assertTrue(!liquidationInfo.triggeredByGovernor);

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), true);

        paymentInfo = ILoanManagerStructs(address(loanManager)).payments(paymentId_);

        // Loan info doesn't change, in case we want to revert the loan impairment.
        assertEq(paymentInfo.incomingNetInterest, 80);
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_006_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);          // Loan has been removed from list
        assertEq(loanManager.unrealizedLosses(),           1_000_048);

        liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       1_000_000,
            interest:        48,
            lateInterest:    0,
            platformFees:    20 + 3,  // (20 * 60%) + (100 * 60% * 5%)  (accruedPlatformServiceFee + accruedPlatformManagementFee)
            liquidator:      address(0)
        });

        assertTrue(liquidationInfo.triggeredByGovernor);
    }

}

contract RemoveLoanImpairmentTests is LoanManagerBaseTest {

    address loan;

    function setUp() public override {
        super.setUp();

        loan = address(new MockLoan(address(collateralAsset), address(fundsAsset)));

        // Set next payment information for loanManager to use.
        MockLoan loan_ = MockLoan(loan);
        loan_.__setPrincipal(1_000_000);
        loan_.__setPrincipalRequested(1_000_000);
        loan_.__setNextPaymentInterest(100);
        loan_.__setNextPaymentDueDate(START + 10_000);
        loan_.__setOriginalNextPaymentDueDate(START + 10_000);
        loan_.__setPlatformServiceFee(20);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));
    }

    function test_removeLoanImpairment_notManager() public {
        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), false);

        vm.expectRevert("LM:RLI:NOT_PM");
        loanManager.removeLoanImpairment(address(loan), false);

        vm.prank(address(poolManager));
        loanManager.removeLoanImpairment(address(loan), false);
    }

    function test_removeLoanImpairment_calledByGovernor() public {
        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), true);

        vm.expectRevert("LM:RLI:NOT_PM");
        loanManager.removeLoanImpairment(address(loan), true);

        vm.prank(address(poolManager));
        loanManager.removeLoanImpairment(address(loan), true);
    }

    function test_removeLoanImpairment_pastDueDate() public {
        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), true);

        // Warp past originalPaymentDueDate
        vm.warp(START + 10_000 + 1);

        vm.expectRevert("LM:RLI:PAST_DATE");
        vm.prank(address(poolManager));
        loanManager.removeLoanImpairment(address(loan), true);

        // Warp back before the originalPaymentDueDate
        vm.warp(START + 10_000);

        vm.prank(address(poolManager));
        loanManager.removeLoanImpairment(address(loan), true);
    }

    function test_removeLoanImpairment_delegateNotAuthorizedToRemoveGovernors() public {
        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), true); // Trigger was called by governor.

        vm.expectRevert("LM:RLI:NOT_AUTHORIZED");
        vm.prank(address(poolManager));
        loanManager.removeLoanImpairment(address(loan), false); // PD can't remove it.

        vm.prank(address(poolManager));
        loanManager.removeLoanImpairment(address(loan), true); // Governor can remove it.
    }

    function test_removeLoanImpairment_successWithPD() public {
        uint256 paymentId_ = loanManager.paymentIdOf(address(loan));
        ILoanManagerStructs.PaymentInfo memory paymentInfo = ILoanManagerStructs(address(loanManager)).payments(paymentId_);

        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), false);

        assertEq(paymentInfo.incomingNetInterest, 80);
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_006_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);          // Loan has been removed from list

        ILoanManagerStructs.LiquidationInfo memory liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       1_000_000,
            interest:        48,
            lateInterest:    0,
            platformFees:    20 + 3,  // (20 * 60%) + (100 * 60% * 5%) (accruedPlatformServiceFee + accruedPlatformManagementFee)
            liquidator:      address(0)
        });

        assertTrue(!liquidationInfo.triggeredByGovernor);

        vm.prank(address(poolManager));
        loanManager.removeLoanImpairment(address(loan), false);

        assertEq(paymentInfo.incomingNetInterest, 80);
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0.0080e30);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_010_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 2);          // Loan was re-added to list.

        liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       0,
            interest:        0,
            lateInterest:    0,
            platformFees:    0,
            liquidator:      address(0)
        });

        assertTrue(!liquidationInfo.triggeredByGovernor);

        vm.warp(START + 10_000);

        assertEq(paymentInfo.incomingNetInterest, 80);
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         32);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_080);
        assertEq(loanManager.issuanceRate(),               0.0080e30);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_010_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 2);          // Loan was re-added to list.
    }

    function test_removeLoanImpairment_successWithGovernor() public {
        uint256 paymentId_ = loanManager.paymentIdOf(address(loan));

        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), true);

        ILoanManagerStructs.PaymentInfo memory paymentInfo = ILoanManagerStructs(address(loanManager)).payments(paymentId_);

        assertEq(paymentInfo.incomingNetInterest, 80);
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_006_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);          // Loan has been removed from list

        ILoanManagerStructs.LiquidationInfo memory liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       1_000_000,
            interest:        48,
            lateInterest:    0,
            platformFees:    20 + 3,  // (20 * 60%) + (100 * 60% * 5%) (accruedPlatformServiceFee + accruedPlatformManagementFee)
            liquidator:      address(0)
        });

        assertTrue(liquidationInfo.triggeredByGovernor);

        vm.prank(address(poolManager));
        loanManager.removeLoanImpairment(address(loan), true);

        assertEq(paymentInfo.incomingNetInterest, 80);
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0.0080e30);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_010_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 2);          // Loan was re-added to list.

        liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       0,
            interest:        0,
            lateInterest:    0,
            platformFees:    0,
            liquidator:      address(0)
        });

        assertTrue(!liquidationInfo.triggeredByGovernor);

        vm.warp(START + 10_000);

        assertEq(paymentInfo.incomingNetInterest, 80);
        assertEq(paymentInfo.refinanceInterest,   0);
        assertEq(paymentInfo.issuanceRate,        0.0080e30);
        assertEq(paymentInfo.startDate,           5_000_000);
        assertEq(paymentInfo.paymentDueDate,      5_010_000);

        assertEq(loanManager.getAccruedInterest(),         32);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_080);
        assertEq(loanManager.issuanceRate(),               0.0080e30);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_010_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 2);          // Loan was re-added to list.
    }

}

contract SingleLoanAtomicClaimTests is LoanManagerClaimBaseTest {

    MockLoan loan;

    function setUp() public override {
        super.setUp();

        loan = new MockLoan(address(collateralAsset), address(fundsAsset));

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

        vm.warp(START+ 10_000);

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            domainStart:           START,
            domainEnd:             START + 10_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(1_000_080);

        _makePayment({
            loan:                address(loan),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            nextPaymentDueDate:  START + 20_000
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_000,
            issuanceRate:          0.008e30,
            domainStart:           START + 10_000,
            domainEnd:             START + 20_000
        });

        _assertBalances({
            poolBalance:         80,
            treasuryBalance:     5,
            poolDelegateBalance: 15
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

        vm.warp(START+ 4_000);

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       32,             // 0.008 * 4_000 = 32
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_032,
            issuanceRate:          0.008e30,
            domainStart:           START,
            domainEnd:             START + 10_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(1_000_032);

        _makePayment({
            loan:                address(loan),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            nextPaymentDueDate:  START + 20_000
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START + 4_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.005e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_000,
            issuanceRate:          0.005e30,       // 80 / (10_000 + 4_000 remaining in interval) = 0.005
            domainStart:           START + 4_000,
            domainEnd:             START + 20_000
        });

        _assertBalances({
            poolBalance:         80,
            treasuryBalance:     5,
            poolDelegateBalance: 15
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

        vm.warp(START+ 14_000);

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            domainStart:           START,
            domainEnd:             START + 10_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(1_000_080);

        _makeLatePayment({
            loan:                address(loan),
            interestAmount:      100,             // 4000 seconds late at the premium interest rate (10_000 * 0.01 + 4000 * 0.015 = 160)
            lateInterestAmount:  60,
            principalAmount:     0,
            nextInterestPayment: 100,
            nextPaymentDueDate:  START + 20_000
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     32,              // 4000 seconds into the next interval = 4000 * 0.008 = 32
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_032,
            issuanceRate:          0.008e30,        // Same issuance rate as before.
            domainStart:           START + 14_000,
            domainEnd:             START + 20_000
        });

        _assertBalances({
            poolBalance:         128,
            treasuryBalance:     8,
            poolDelegateBalance: 24
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

        vm.warp(START + 10_000);

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       80,             // 0.008 * 10_000 = 80
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            domainStart:           START,
            domainEnd:             START + 10_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(1_000_080);

        _makePayment({
            loan:                address(loan),
            interestAmount:      100,
            principalAmount:     200_000,
            nextInterestPayment: 100,
            nextPaymentDueDate:  START + 20_000
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          800_000,
            assetsUnderManagement: 800_000,
            issuanceRate:          0.008e30,
            domainStart:           START + 10_000,
            domainEnd:             START + 20_000
        });

        _assertBalances({
            poolBalance:         200_080,
            treasuryBalance:     5,
            poolDelegateBalance: 15
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

        vm.warp(START + 4_000);

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       32,             // 0.008 * 6_000 = 32
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_032,
            issuanceRate:          0.008e30,
            domainStart:           START,
            domainEnd:             START + 10_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(1_000_032);

        _makePayment({
            loan:                address(loan),
            interestAmount:      100,
            principalAmount:     200_000,
            nextInterestPayment: 100,
            nextPaymentDueDate:  START + 20_000
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START + 4_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.005e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          800_000,
            assetsUnderManagement: 800_000,
            issuanceRate:          0.005e30,       // 80 / (10_000 + 6_000 remaining in current interval) = 0.005
            domainStart:           START + 4_000,
            domainEnd:             START + 20_000
        });

        _assertBalances({
            poolBalance:         200_080,
            treasuryBalance:     5,
            poolDelegateBalance: 15
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

        vm.warp(START + 14_000);

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       80,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_080,
            issuanceRate:          0.008e30,
            domainStart:           START,
            domainEnd:             START + 10_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(1_000_080);

        _makeLatePayment({
            loan:                address(loan),
            interestAmount:      100,            // 4000 seconds late at the premium interest rate (10_000 * 0.008 + 4000 * 0.012) / 0.8 = 160
            lateInterestAmount:  60,
            principalAmount:     200_000,
            nextInterestPayment: 100,
            nextPaymentDueDate:  START + 20_000
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     32,              // 4000 seconds into the next interval = 4000 * 0.008 = 28
            principalOut:          800_000,
            assetsUnderManagement: 800_032,
            issuanceRate:          0.008e30,        // Same issuance rate as before.
            domainStart:           START + 14_000,
            domainEnd:             START + 20_000
        });

        _assertBalances({
            poolBalance:         200_128,
            treasuryBalance:     8,
            poolDelegateBalance: 24
        });

        _assertTotalAssets(1_000_160);
    }

}

contract TwoLoanAtomicClaimTests is LoanManagerClaimBaseTest {

    MockLoan loan1;
    MockLoan loan2;

    function setUp() public override {
        super.setUp();

        loan1 = new MockLoan(address(collateralAsset), address(fundsAsset));
        loan2 = new MockLoan(address(collateralAsset), address(fundsAsset));

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

        /******************************************************************************************************************************/
        /*** Loan 1 Payment                                                                                                         ***/
        /******************************************************************************************************************************/

        vm.warp(START + 10_000);

        _assertPaymentInfo({
            loan:                address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       32 + 40,
            accountedInterest:     48,             // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_120,
            issuanceRate:          0.018e30,
            domainStart:           START + 6_000,
            domainEnd:             START + 10_000  // End of loan1 payment interval
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_120);

        _makePayment({
            loan:                address(loan1),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            nextPaymentDueDate:  START + 20_000
        });

        _assertPaymentInfo({
            loan:                address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     40,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_040,
            issuanceRate:          0.018e30,
            domainStart:           START + 10_000,
            domainEnd:             START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            poolBalance:         80,
            treasuryBalance:     5,
            poolDelegateBalance: 15
        });

        _assertTotalAssets(2_000_120);

        /******************************************************************************************************************************/
        /*** Loan 2 Payment                                                                                                         ***/
        /******************************************************************************************************************************/

        vm.warp(START + 16_000);

        _assertPaymentInfo({
            loan:                address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START + 6_000,
            paymentDueDate:      START + 16_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       48 + 60,
            accountedInterest:     40,  // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_148,
            issuanceRate:          0.018e30,
            domainStart:           START + 10_000,
            domainEnd:             START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            poolBalance:         80,
            treasuryBalance:     5,
            poolDelegateBalance: 15
        });

        _assertTotalAssets(2_000_228);

        _makePayment({
            loan:                address(loan2),
            interestAmount:      125,
            principalAmount:     0,
            nextInterestPayment: 125,
            nextPaymentDueDate:  START + 26_000
        });

        _assertPaymentInfo({
            loan:                address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START + 16_000,
            paymentDueDate:      START + 26_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     48,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_048,
            issuanceRate:          0.018e30,
            domainStart:           START + 16_000,
            domainEnd:             START + 20_000  // End of loan2 payment interval
        });

        _assertBalances({
            poolBalance:         180 + 1,  // Plus the extra dust, 25 % 2 == 1
            treasuryBalance:     11,
            poolDelegateBalance: 33
        });

        _assertTotalAssets(2_000_229);
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

        /******************************************************************************************************************************/
        /*** Loan 1 Payment                                                                                                         ***/
        /******************************************************************************************************************************/

        vm.warp(START + 8_000);

        _assertPaymentInfo({
            loan:                address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       16 + 20,
            accountedInterest:     48,  // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_084,
            issuanceRate:          0.018e30,
            domainStart:           START + 6_000,
            domainEnd:             START + 10_000  // End of loan1 payment interval
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_084);

        _makePayment({
            loan:                address(loan1),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            nextPaymentDueDate:  START + 20_000
        });

        _assertPaymentInfo({
            loan:                address(loan1),
            incomingNetInterest: 79,
            refinanceInterest:   0,
            startDate:           START + 8_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.006666666666666666666666666666e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     20,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_020,
            issuanceRate:          0.016666666666666666666666666666e30,  // 0.01 + 80/12_000 = 0.0166...
            domainStart:           START + 8_000,
            domainEnd:             START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            poolBalance:         80,
            treasuryBalance:     5,
            poolDelegateBalance: 15
        });

        _assertTotalAssets(2_000_100);

        /******************************************************************************************************************************/
        /*** Loan 2 Payment                                                                                                         ***/
        /******************************************************************************************************************************/

        vm.warp(START + 16_000);

        _assertPaymentInfo({
            loan:                address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START + 6_000,
            paymentDueDate:      START + 16_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       53 + 80,
            accountedInterest:     20,  // Accounted during loan1 payment.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_153,
            issuanceRate:          0.016666666666666666666666666666e30,  // 0.01 + 80/12_000 = 0.0166...
            domainStart:           START + 8_000,
            domainEnd:             START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            poolBalance:         80,
            treasuryBalance:     5,
            poolDelegateBalance: 15
        });

        _assertTotalAssets(2_000_233);

        _makePayment({
            loan:                address(loan2),
            interestAmount:      125,
            principalAmount:     0,
            nextInterestPayment: 125,
            nextPaymentDueDate:  START + 26_000
        });

        _assertPaymentInfo({
            loan:                address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START + 16_000,
            paymentDueDate:      START + 26_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     53,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_053,
            issuanceRate:          0.016666666666666666666666666666e30,  // 0.01 + 80/12_000 = 0.0166...
            domainStart:           START + 16_000,
            domainEnd:             START + 20_000  // End of loan2 payment interval
        });

        _assertBalances({
            poolBalance:         180 + 1,  // Plus the extra dust, 25 % 2 == 1
            treasuryBalance:     11,
            poolDelegateBalance: 33
        });

        _assertTotalAssets(2_000_234);
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
         *    Second payment net interest accounted:  2_000sec  * 0.008                       = 16
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

        /******************************************************************************************************************************/
        /*** Loan 1 Payment                                                                                                         ***/
        /******************************************************************************************************************************/

        vm.warp(START + 12_000);

        _assertPaymentInfo({
            loan:                address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       32 + 40,
            accountedInterest:     48,  // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_120,
            issuanceRate:          0.018e30,
            domainStart:           START + 6_000,
            domainEnd:             START + 10_000  // End of loan1 payment interval
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_120);

        _makeLatePayment({
            loan:                address(loan1),
            interestAmount:      100,  // ((10_000 * 0.008) + (2_000 * 0.012)) / 0.8 = 130 (gross late interest)
            lateInterestAmount:  30,
            principalAmount:     0,
            nextInterestPayment: 100,
            nextPaymentDueDate:  START + 20_000
        });

        _assertPaymentInfo({
            loan:                address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.008e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     16 + 60,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_076,
            issuanceRate:          0.018e30,  // Not early so use same interval, causing same exchange rate
            domainStart:           START + 12_000,
            domainEnd:             START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            poolBalance:         104 + 1,  // Dust
            treasuryBalance:     6,
            poolDelegateBalance: 19
        });

        _assertTotalAssets(2_000_181);

        /******************************************************************************************************************************/
        /*** Loan 2 Payment                                                                                                         ***/
        /******************************************************************************************************************************/

        vm.warp(START + 16_000);

        _assertPaymentInfo({
            loan:                address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START + 6_000,
            paymentDueDate:      START + 16_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       32 + 40,
            accountedInterest:     16 + 60,  // Accounted during loan1 payment.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_148,
            issuanceRate:          0.018e30,
            domainStart:           START + 12_000,
            domainEnd:             START + 16_000  // End of loan1 payment interval
        });

        _assertBalances({
            poolBalance:         104 + 1,  // Dust
            treasuryBalance:     6,
            poolDelegateBalance: 19
        });

        _assertTotalAssets(2_000_253);

        _makePayment({
            loan:                address(loan2),
            interestAmount:      125,
            principalAmount:     0,
            nextInterestPayment: 125,
            nextPaymentDueDate:  START + 26_000
        });

        _assertPaymentInfo({
            loan:                address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START + 16_000,
            paymentDueDate:      START + 26_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     48,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_048,
            issuanceRate:          0.018e30,
            domainStart:           START + 16_000,
            domainEnd:             START + 20_000  // End of loan2 payment interval
        });

        _assertBalances({
            poolBalance:         204 + 1 + 1,  // 104 from first payment, 100 from second payment, plus dust
            treasuryBalance:     12,
            poolDelegateBalance: 37
        });

        _assertTotalAssets(2_000_254);
    }

}

contract ThreeLoanPastDomainEndClaimTests is LoanManagerClaimBaseTest {

    MockLoan loan1;
    MockLoan loan2;
    MockLoan loan3;

    function setUp() public override {
        super.setUp();

        loan1 = new MockLoan(address(collateralAsset), address(fundsAsset));
        loan2 = new MockLoan(address(collateralAsset), address(fundsAsset));
        loan3 = new MockLoan(address(collateralAsset), address(fundsAsset));

        // Set next payment information for loanManager to use.
        loan1.__setPrincipal(1_000_000);
        loan2.__setPrincipal(1_000_000);
        loan3.__setPrincipal(1_000_000);

        loan1.__setPrincipalRequested(1_000_000);
        loan2.__setPrincipalRequested(1_000_000);
        loan3.__setPrincipalRequested(1_000_000);

        loan1.__setNextPaymentInterest(100);  // Net interest: 80
        loan2.__setNextPaymentInterest(125);  // Net interest: 100
        loan3.__setNextPaymentInterest(150);  // Net interest: 120

        loan1.__setNextPaymentDueDate(START + 10_000);
        loan2.__setNextPaymentDueDate(START + 16_000);  // 10_000 second interval
        loan3.__setNextPaymentDueDate(START + 18_000);  // 10_000 second interval

        vm.startPrank(address(poolManager));

        loanManager.fund(address(loan1));

        vm.warp(START + 6_000);
        loanManager.fund(address(loan2));

        vm.warp(START + 8_000);
        loanManager.fund(address(loan3));

        vm.stopPrank();

        /**
         *  Loan 1
         *    Start date:    0
         *    Issuance rate: 0.008e30 (100 * 0.8 / 10_000)
         *  Loan 2
         *    Start date:    6_000
         *    Issuance rate: 0.01e30 (125 * 0.8 / 10_000)
         *  Loan 3
         *    Start date:    8_000
         *    Issuance rate: 0.012e30 (150 * 0.8 / 10_000)
         */
    }

    function test_claim_loan3_loan1NotPaid_loan2NotPaid() external {
        /**
         *  ***********************************
         *  *** Loan 3 Payment (t = 18_000) ***
         *  ***********************************
         *  --- Post-Claim ---
         *  Loan 1:
         *    First  payment net interest accounted: 10_000 * 0.008 = 80 (Accounted up to DE1)
         *  Loan 2:
         *    First payment net interest accounted: 10_000 * 0.01 = 100 (Move DE to DE2 and account to DE2)
         *  Loan 3:
         *    First  payment net interest claimed:   10_000 * 0.012 = 120
         *    Second payment net interest accounted: 0      * 0.012 = 0
         *  --------------------------------------------------------------
         *  TA = principalOut + accountedInterest + accruedInterest + cash
         *  Resulting total assets(t = 18_000): 3_000_000 + (80 + 100) + 0 + 120 = 3_000_300
         */

        vm.warp(START + 18_000);

        _makePayment({
            loan:                address(loan3),
            interestAmount:      150,
            principalAmount:     0,
            nextInterestPayment: 150,
            nextPaymentDueDate:  START + 28_000
        });

        _assertPaymentInfo({
            loan:                address(loan3),
            incomingNetInterest: 120,
            refinanceInterest:   0,
            startDate:           START + 18_000,
            paymentDueDate:      START + 28_000,
            issuanceRate:        0.012e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     80 + 100,  // Full interest accounted for loans 1 and 2
            principalOut:          3_000_000,
            assetsUnderManagement: 3_000_180,
            issuanceRate:          0.012e30,   // Since loan1 and loan2 no longer are accruing interest, IR is reduced
            domainStart:           START + 18_000,
            domainEnd:             START + 28_000  // End of loan1 payment interval
        });

        _assertBalances({
            poolBalance:         120 + 1,  // Rounding error is sent to pool
            treasuryBalance:     7,
            poolDelegateBalance: 22
        });

        _assertTotalAssets(3_000_301);  // Rounding error is sent to pool
    }

    function test_claim_loan1NotPaid_loan2NotPaid_loan3PaidLate() external {
        /**
         *  Loan1 is paid late after the payment and claim of loan3, which is also late. Loan2 is never paid.
         *
         *  ****************************************
         *  *** Loan 3 late Payment (t = 19_000) ***
         *  ****************************************
         *  DE1 = 10_000
         *  DE2 = 16_000
         *  DE2 = 18_000
         *  Loan 1:
         *    First  payment net interest accounted: 10_000 * 0.008 = 80 (Accounted up to DE1)
         *  Loan 2:
         *    First payment net interest accounted: 10_000 * 0.01 = 100 (Move DE to DE2 and account to DE2)
         *  Loan 3:
         *    First  payment net interest claimed:   10_000 * 0.012 = 120
         *    Second payment net interest accounted: 1_000  * 0.012 = 12
         *  --------------------------------------------------------------
         *  TA = principalOut + accountedInterest + accruedInterest + cash
         *  Resulting total assets (t = 19_000): 3_000_000 + (80 + 100 + 12) + 0 + 120 = 3_000_312
         */

        vm.warp(START + 19_000);

        _makePayment({
            loan:                address(loan3),
            interestAmount:      150,
            principalAmount:     0,
            nextInterestPayment: 150,
            nextPaymentDueDate:  START + 28_000
        });

        _assertPaymentInfo({
            loan:                address(loan3),
            incomingNetInterest: 120,
            refinanceInterest:   0,
            startDate:           START + 18_000,
            paymentDueDate:      START + 28_000,
            issuanceRate:        0.012e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     80 + 100 + 12,  // Full interest accounted for loans 1 and 2 + 1_000sec of loan3 at 0.012
            principalOut:          3_000_000,
            assetsUnderManagement: 3_000_192,
            issuanceRate:          0.012e30,   // Since loan1 and loan2 no longer are accruing interest, IR is reduced
            domainStart:           START + 19_000,
            domainEnd:             START + 28_000  // End of loan3 payment interval
        });

        _assertBalances({
            poolBalance:         120 + 1, // Rounding error is sent to pool
            treasuryBalance:     7,
            poolDelegateBalance: 22
        });

        _assertTotalAssets(3_000_313);  // Rounding error is sent to pool
    }

}

contract ClaimDomainStartGtDomainEnd is LoanManagerClaimBaseTest {

    MockLoan loan1;
    MockLoan loan2;

    function setUp() public override {
        super.setUp();

        loan1 = new MockLoan(address(collateralAsset), address(fundsAsset));
        loan2 = new MockLoan(address(collateralAsset), address(fundsAsset));

        // Set next payment information for loanManager to use.
        loan1.__setPrincipal(1_000_000);
        loan2.__setPrincipal(1_000_000);
        loan1.__setPrincipalRequested(1_000_000);
        loan2.__setPrincipalRequested(1_000_000);
        loan1.__setNextPaymentInterest(100);
        loan2.__setNextPaymentInterest(125);
        loan1.__setNextPaymentDueDate(START + 10_000);
        loan2.__setNextPaymentDueDate(START + 22_000);  // 10_000 second interval from 12_000sec start.

        vm.prank(address(poolManager));
        loanManager.fund(address(loan1));

        fundsAsset.mint(address(pool), 1_000_000);  // Represent totalAssets

        /**
         *  Loan 1
         *    Start date:    0sec
         *    Issuance rate: 0.008e30 (100 * 0.8 / 10_000)
         */
    }

    function test_claim_domainStart_gt_domainEnd() external {
        /**
         *  ********************************
         *  *** Loan 2 Fund (t = 12_000) ***
         *  ********************************
         *  --- Pre-Fund ---
         *  Loan 1:
         *    First  payment net interest accounted: 0
         *    First  payment net interest accrued:   10_000sec * 0.008 = 80 (Accrues up to DE)
         *  --- Post-Fund ---
         *  Loan 1:
         *    First  payment net interest accounted: 10_000sec * 0.008 = 80 (Accounted during loan2 funding, after DE using `_accountPreviousLoans`)
         *    Second payment net interest accrued:   0                      (Second payment not recognized)
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 1_000_000 + 80 + 0  + 1_000_000 = 2_000_080
         *  Resulting total assets: 2_000_000 + 0  + 80 + 0         = 2_000_080
         *  ***********************************
         *  *** Loan 2 Payment (t = 24_000) ***
         *  ***********************************
         *  --- Pre-Claim ---
         *  Loan 1:
         *    First  payment net interest accounted: 10_000sec * 0.008 = 80 (Accounted during loan2 funding, after DE)
         *    Second payment net interest accrued:   0                      (Second payment not recognized)
         *  Loan 2:
         *    First  payment net interest accounted: 0
         *    First  payment net interest accrued:   10_000sec * 0.01 = 100 (Accrues up to DE)
         *    Second payment net interest accrued:   0
         *  --- Post-Claim ---
         *  Loan 1:
         *    First  payment net interest accounted: 10_000sec * 0.008 = 80 (Accounted during loan2 funding, after DE)
         *    Second payment net interest accrued:   0                      (Second payment not recognized)
         *  Loan 2:
         *    First  payment net interest claimed:   10_000sec * 0.01 = 100
         *    Second payment net interest accounted: 2_000sec  * 0.01 = 20  (Accounts for second payment cycle)
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + 100 + 80        + 0   = 2_000_180
         *  Resulting total assets: 2_000_000 + 0   + (80 + 20) + 100 = 2_000_200
         *  *****************************************************************************
         *  *** Loan 1 Payment 1 (t = 27_000) (LU = 24_000, DE from Loan 1 = 20_000) ***
         *  *****************************************************************************
         *  --- Pre-Claim ---
         *  Loan 1:
         *    First  payment net interest accounted: 10_000sec * 0.008 = 80 (Accounted during loan2 funding, after DE)
         *    Second payment net interest accrued:   0                      (Second payment not recognized)
         *  Loan 2:
         *    Second payment net interest accounted: 2_000sec * 0.01 = 20
         *    Second payment net interest accrued:   3_000sec * 0.01 = 30
         *  --- Post-Claim ---
         *  Loan 1:
         *    First  payment net interest claimed:   10_000sec * 0.008 = 80
         *    Second payment net interest accounted: 10_000sec * 0.008 = 80
         *  Loan 2:
         *    Second payment net interest accounted: 5_000sec * 0.01 = 50
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + 30 + (80 + 20) + 100 = 2_000_230
         *  Resulting total assets: 2_000_000 + 0  + (80 + 50) + 180 = 2_000_310
         */

        /******************************************************************************************************************************/
        /*** Loan 2 Fund                                                                                                            ***/
        /******************************************************************************************************************************/

        vm.warp(START + 12_000);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan2));

        fundsAsset.burn(address(pool), 1_000_000);  // Mock pool moving cash

        /******************************************************************************************************************************/
        /*** Loan 2 Payment (t = 24_000)                                                                                            ***/
        /******************************************************************************************************************************/

        vm.warp(START + 24_000);

        _makePayment({
            loan:                address(loan2),
            interestAmount:      125,
            principalAmount:     0,
            nextInterestPayment: 125,
            nextPaymentDueDate:  START + 32_000
        });

        /******************************************************************************************************************************/
        /*** Loan 1 Payment (t = 27_000)                                                                                            ***/
        /******************************************************************************************************************************/

        vm.warp(START + 27_000);

        // Loan 1
        _assertPaymentInfo({
            loan:                address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0
        });

        // Loan 2
        _assertPaymentInfo({
            loan:                address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START + 22_000,
            paymentDueDate:      START + 32_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       30,
            accountedInterest:     80 + 20,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_130,
            issuanceRate:          0.01e30,
            domainStart:           START + 24_000,
            domainEnd:             START + 32_000
        });

        _assertBalances({
            poolBalance:         100 + 1,  // From loan 2 claim
            treasuryBalance:     6,
            poolDelegateBalance: 18
        });

        _assertTotalAssets(2_000_230 + 1);

        /******************************************************************************************************************************/
        /*** Loan 1 Payment (t = 10_000                                                                                             ***/
        /******************************************************************************************************************************/

        _makePayment({
            loan:                address(loan1),
            interestAmount:      100,
            principalAmount:     0,
            nextInterestPayment: 100,
            nextPaymentDueDate:  START + 20_000
        });

        // Loan 1
        _assertPaymentInfo({
            loan:                address(loan1),
            incomingNetInterest: 80,
            refinanceInterest:   0,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000,  // In the past - LU > DE
            issuanceRate:        0
        });

        // Loan 2 (No change)
        _assertPaymentInfo({
            loan:                address(loan2),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START + 22_000,
            paymentDueDate:      START + 32_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     50 + 80,  // Second payment accounted interest for loan 1
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_130,
            issuanceRate:          0.01e30,
            domainStart:           START + 27_000,
            domainEnd:             START + 32_000
        });

        _assertBalances({
            poolBalance:         100 + 80 + 1,  // Dust
            treasuryBalance:     6  + 5,
            poolDelegateBalance: 18 + 15
        });

        _assertTotalAssets(2_000_310 + 1);  // Dust
    }
}

contract RefinanceAccountingSingleLoanTests is LoanManagerClaimBaseTest {

    MockLoan loan;

    // Refinance
    address refinancer = address(new Address());

    function setUp() public override {
        super.setUp();

        loan = new MockLoan(address(collateralAsset), address(fundsAsset));

        // Setup next payment information
        loan.__setPrincipal(1_000_000);
        loan.__setPrincipalRequested(1_000_000);
        loan.__setNextPaymentInterest(125);
        loan.__setNextPaymentDueDate(START + 10_000);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));

        // On this suite, pools have a total of 2_000_000 to facilitate funding + refinance
        fundsAsset.mint(address(pool), 1_000_000);
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

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       100,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_100,
            issuanceRate:          0.01e30,
            domainStart:           START,
            domainEnd:             START + 10_000
        });

        _assertBalances({
            poolBalance:         1_000_000,
            treasuryBalance:     0,
            poolDelegateBalance: 0
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
        fundsAsset.burn(address(pool), 1_000_000);

        vm.prank(address(poolManager));
        loanManager.acceptNewTerms(address(loan), address(refinancer), block.timestamp, new bytes[](0));

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   100,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.03e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     100,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_100,
            issuanceRate:          0.03e30,
            domainStart:           START + 10_000,
            domainEnd:             START + 20_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_100);

        vm.warp(START + 20_000);

        loan.__setRefinanceInterest(0);  // Set refinance interest to zero after payment is made.

        _assertLoanManagerState({
            accruedInterest:       300,
            accountedInterest:     100,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_400,
            issuanceRate:          0.03e30,
            domainStart:           START + 10_000,
            domainEnd:             START + 20_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_400);

        // Make a refinanced payment and claim
        _makePayment({
            loan:                address(loan),
            interestAmount:      375 + 125,
            principalAmount:     0,
            nextInterestPayment: 375,
            nextPaymentDueDate:  START + 30_000
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   0,
            startDate:           START + 20_000,
            paymentDueDate:      START + 30_000,
            issuanceRate:        0.03e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_000,
            issuanceRate:          0.03e30,
            domainStart:           START + 20_000,
            domainEnd:             START + 30_000
        });

        _assertBalances({
            poolBalance:         100 + 300,
            treasuryBalance:     25,
            poolDelegateBalance: 75
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
         *  Second payment net interest accounted: 0
         *  --------------------------------------------------------------
         *  TA = principalOut + accruedInterest + accountedInterest + cash
         *  Starting  total assets: 2_000_000 + 300 + 60 + 0   = 2_000_360
         *  Resulting total assets: 2_000_000 + 0   + 0  + 360 = 2_000_360
         */

        vm.warp(START + 6_000);

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       60,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_060,
            issuanceRate:          0.01e30,
            domainStart:           START,
            domainEnd:             START + 10_000
        });

        _assertBalances({
            poolBalance:         1_000_000,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_060);

        // Set Refinance values
        loan.__setRefinanceInterest(75);  // Accrued gross interest from first payment cycle (accounted for in real loan).
        loan.__setRefinancePrincipal(2_000_000);
        loan.__setPrincipalRequested(2_000_000);
        loan.__setRefinanceNextPaymentInterest(375);
        loan.__setRefinanceNextPaymentDueDate(START + 16_000);

        fundsAsset.burn(address(pool), 1_000_000);  // Burn from the pool to simulate fund and drawdown.

        vm.prank(address(poolManager));
        loanManager.acceptNewTerms(address(loan), address(refinancer), block.timestamp, new bytes[](0));

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   60,
            startDate:           START + 6_000,
            paymentDueDate:      START + 16_000,
            issuanceRate:        0.03e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     60,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_060,
            issuanceRate:          0.03e30,
            domainStart:           START + 6_000,
            domainEnd:             START + 16_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_060);

        vm.warp(START + 16_000);

        _assertLoanManagerState({
            accruedInterest:       300,
            accountedInterest:     60,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_360,
            issuanceRate:          0.03e30,
            domainStart:           START + 6_000,
            domainEnd:             START + 16_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_360);

        loan.__setRefinanceInterest(0);  // Set to 0 to simulate a refinance that has been paid off.

        // Make a refinanced payment and claim
        _makePayment({
            loan:                address(loan),
            interestAmount:      375 + 75,  // Interest plus refinance interest.
            principalAmount:     0,
            nextInterestPayment: 375,
            nextPaymentDueDate:  START + 26_000
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   0,
            startDate:           START + 16_000,
            paymentDueDate:      START + 26_000,
            issuanceRate:        0.03e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_000,
            issuanceRate:          0.03e30,
            domainStart:           START + 16_000,
            domainEnd:             START + 26_000
        });

        _assertBalances({
            poolBalance:         60 + 301,
            treasuryBalance:     22,
            poolDelegateBalance: 67
        });

        _assertTotalAssets(2_000_361);
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

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       100,
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_100,
            issuanceRate:          0.01e30,
            domainStart:           START,
            domainEnd:             START + 10_000
        });

        _assertBalances({
            poolBalance:         1_000_000,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_100);

        // Set Refinance values
        loan.__setRefinanceInterest(185);  // Accrued gross interest from first payment cycle (accounted for in real loan).
        loan.__setRefinancePrincipal(2_000_000);
        loan.__setPrincipalRequested(2_000_000);
        loan.__setRefinanceNextPaymentInterest(375);
        loan.__setRefinanceNextPaymentDueDate(START + 24_000); // The payment schedule restarts at refinance

        fundsAsset.burn(address(pool), 1_000_000);

        vm.prank(address(poolManager));
        loanManager.acceptNewTerms(address(loan), address(refinancer), block.timestamp, new bytes[](0));

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   148,
            startDate:           START + 14_000,
            paymentDueDate:      START + 24_000,
            issuanceRate:        0.03e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     148,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_148,
            issuanceRate:          0.03e30,
            domainStart:           START + 14_000,
            domainEnd:             START + 24_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_148);

        vm.warp(START + 24_000);

        loan.__setRefinanceInterest(0);  // Set refinance interest to zero after payment is made.

        _assertLoanManagerState({
            accruedInterest:       300,
            accountedInterest:     148,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_448,
            issuanceRate:          0.03e30,
            domainStart:           START + 14_000,
            domainEnd:             START + 24_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_448);

        // Make a refinanced payment and claim
        _makePayment({
            loan:                address(loan),
            interestAmount:      375 + 185,  // Interest plus refinance interest.
            principalAmount:     0,
            nextInterestPayment: 375,
            nextPaymentDueDate:  START + 34_000
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   0,
            startDate:           START + 24_000,
            paymentDueDate:      START + 34_000,
            issuanceRate:        0.03e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_000,
            issuanceRate:          0.03e30,
            domainStart:           START + 24_000,
            domainEnd:             START + 34_000
        });

        _assertBalances({
            poolBalance:         300 + 148,
            treasuryBalance:     28,
            poolDelegateBalance: 84
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

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 100,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + 10_000,
            issuanceRate:        0.01e30
        });

        _assertLoanManagerState({
            accruedInterest:       100,  // 0.008 * 10_000 = 80
            accountedInterest:     0,
            principalOut:          1_000_000,
            assetsUnderManagement: 1_000_100,
            issuanceRate:          0.01e30,
            domainStart:           START,
            domainEnd:             START + 10_000
        });

        _assertBalances({
            poolBalance:         1_000_000,
            treasuryBalance:     0,
            poolDelegateBalance: 0
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

        fundsAsset.burn(address(pool), 1_000_000);

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   100,
            startDate:           START + 10_000,
            paymentDueDate:      START + 20_000,
            issuanceRate:        0.03e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     100,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_100,
            issuanceRate:          0.03e30,
            domainStart:           START + 10_000,
            domainEnd:             START + 20_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_100);

        vm.warp(START + 20_000);

        loan.__setRefinanceInterest(0);  // Set refinance interest to zero after payment is made.

        _assertLoanManagerState({
            accruedInterest:       300,
            accountedInterest:     100,
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_400,
            issuanceRate:          0.03e30,
            domainStart:           START + 10_000,
            domainEnd:             START + 20_000
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(2_000_400);

        // Make a payment post refinance
        _makePayment({
            loan:                address(loan),
            interestAmount:      375 + 125,  // Interest plus refinance interest
            principalAmount:     200_000,
            nextInterestPayment: 375,
            nextPaymentDueDate:  START + 30_000
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: 300,
            refinanceInterest:   0,
            startDate:           START + 20_000,
            paymentDueDate:      START + 30_000,
            issuanceRate:        0.03e30
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     0,
            principalOut:          1_800_000,
            assetsUnderManagement: 1_800_000,
            issuanceRate:          0.03e30,         // 240 interest over 1000 seconds
            domainStart:           START + 20_000,
            domainEnd:             START + 30_000
        });

        _assertBalances({
            poolBalance:         300 + 100 + 200_000,
            treasuryBalance:     25,
            poolDelegateBalance: 75
        });

        _assertTotalAssets(2_000_400);
    }

}

contract TriggerDefaultTests is LoanManagerBaseTest {

    address loan;

    function setUp() public override {
        super.setUp();

        loan = address(new MockLoan(address(collateralAsset), address(fundsAsset)));

        // Set next payment information for loanManager to use.
        MockLoan loan_ = MockLoan(loan);
        loan_.__setPrincipal(1_000_000);
        loan_.__setPrincipalRequested(1_000_000);
        loan_.__setNextPaymentInterest(100);
        loan_.__setNextPaymentDueDate(START + 10_000);
        loan_.__setPlatformServiceFee(20);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));
    }

    function test_triggerDefault_notManager() public {
        // NOTE: The next two lines of code are unnecessary, as loan.repossess() is mocked, but simulate the real preconditions for this function to be called.
        uint256 nextPaymentDueDate = MockLoan(loan).nextPaymentDueDate();
        vm.warp(nextPaymentDueDate);

        vm.expectRevert("LM:TD:NOT_PM");
        loanManager.triggerDefault(address(loan), address(liquidatorFactory));

        vm.prank(address(poolManager));
        loanManager.triggerDefault(address(loan), address(liquidatorFactory));
    }

    function test_triggerDefault_success_noCollateral_impaired() public {
        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), false);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_006_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.unrealizedLosses(),           1_000_048);

        ILoanManagerStructs.LiquidationInfo memory liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       1_000_000,
            interest:        48,
            lateInterest:    0,
            platformFees:    20 + 3,
            liquidator:      address(0)
        });

        vm.warp(START + 8_000);  // Warp to ensure to that accounting still holds.

        vm.prank(address(poolManager));
        ( bool liquidationComplete, uint256 remainingLosses, uint256 platformFees ) = loanManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertTrue(liquidationComplete);
        assertEq(remainingLosses, 1_000_048);
        assertEq(platformFees,    20 + 3);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          0);
        assertEq(loanManager.principalOut(),               0);
        assertEq(loanManager.assetsUnderManagement(),      0);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_008_000);  // Always updates to BT
        assertEq(loanManager.domainEnd(),                  5_008_000);  // Always updates to BT
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.unrealizedLosses(),           0);
    }

    function test_triggerDefault_success_withCollateral_impaired() public {
        // Warp 60% into the payment interval
        vm.warp(START + 6_000);

        MockLoan(loan).__setCollateral(1_000_000);
        collateralAsset.mint(loan, 1_000_000);

        vm.prank(address(poolManager));
        loanManager.impairLoan(address(loan), false);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_006_000);
        assertEq(loanManager.domainEnd(),                  5_006_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.unrealizedLosses(),           1_000_048);

        ILoanManagerStructs.LiquidationInfo memory liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       1_000_000,
            interest:        48,
            lateInterest:    0,
            platformFees:    20 + 3,
            liquidator:      address(0)
        });

        vm.warp(START + 8_000);  // Warp to ensure that accounting still holds.

        vm.prank(address(poolManager));
        ( bool liquidationComplete, uint256 remainingLosses_, uint256 platformFees_ ) = loanManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertTrue(!liquidationComplete);
        assertEq(remainingLosses_, 0);
        assertEq(platformFees_,    20 +3);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          48);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_048);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_008_000);
        assertEq(loanManager.domainEnd(),                  5_008_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.unrealizedLosses(),           1_000_048);

        liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       1_000_000,
            interest:        48,
            lateInterest:    0,
            platformFees:    20 + 3,
            liquidator:      address(0x760C3B9cb28eBf12F5fd66AfED48c45a18D0b98D)
        });
    }

    function test_triggerDefault_success_noCollateral_notImpaired() public {
        // Warp to be late
        vm.warp(START + 11_000);

        assertEq(loanManager.getAccruedInterest(),         80);
        assertEq(loanManager.accountedInterest(),          0);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_080);
        assertEq(loanManager.issuanceRate(),               0.008e30);
        assertEq(loanManager.domainStart(),                5_000_000);
        assertEq(loanManager.domainEnd(),                  5_010_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);
        assertEq(loanManager.unrealizedLosses(),           0);

        MockLoan(loan).__setNextPaymentLateInterest(10);

        vm.prank(address(poolManager));
        ( bool liquidationComplete, uint256 remainingLosses_, uint256 platformFees_ ) = loanManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertTrue(liquidationComplete);
        assertEq(remainingLosses_, 1_000_088);
        assertEq(platformFees_,    25);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          0);
        assertEq(loanManager.principalOut(),               0);
        assertEq(loanManager.assetsUnderManagement(),      0);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_011_000);
        assertEq(loanManager.domainEnd(),                  5_011_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.unrealizedLosses(),           0);
    }

    function test_triggerDefault_success_withCollateral_notImpaired() public {
        // Warp to be late
        vm.warp(START + 11_000);

        MockLoan(loan).__setCollateral(1_000_000);
        collateralAsset.mint(loan, 1_000_000);

        assertEq(loanManager.getAccruedInterest(),         80);
        assertEq(loanManager.accountedInterest(),          0);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_080);
        assertEq(loanManager.issuanceRate(),               0.008e30);
        assertEq(loanManager.domainStart(),                5_000_000);
        assertEq(loanManager.domainEnd(),                  5_010_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);
        assertEq(loanManager.unrealizedLosses(),           0);

        MockLoan(loan).__setNextPaymentLateInterest(10);

        vm.prank(address(poolManager));
        ( bool liquidationComplete, uint256 remainingLosses_, uint256 platformFees_ ) = loanManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertTrue(!liquidationComplete);
        assertEq(remainingLosses_, 0);
        assertEq(platformFees_,    25);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          80);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_080);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_011_000);
        assertEq(loanManager.domainEnd(),                  5_011_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.unrealizedLosses(),           1_000_080);

        ILoanManagerStructs.LiquidationInfo memory liquidationInfo = ILoanManagerStructs(address(loanManager)).liquidationInfo(loan);

        _assertLiquidationInfo({
            liquidationInfo: liquidationInfo,
            principal:       1_000_000,
            interest:        80,
            lateInterest:    8,
            platformFees:    25,
            liquidator:      address(0x760C3B9cb28eBf12F5fd66AfED48c45a18D0b98D)
        });
    }

    function test_triggerDefault_success_withCollateralAssetEqualToFundsAsset() public {
        MockLoan(loan).__setCollateralAsset(address(fundsAsset));
        MockLoan(loan).__setCollateral(100_000);

        fundsAsset.mint(loan, 100_000);

        // Warp to be late
        vm.warp(START + 11_000);

        assertEq(loanManager.getAccruedInterest(),         80);
        assertEq(loanManager.accountedInterest(),          0);
        assertEq(loanManager.principalOut(),               1_000_000);
        assertEq(loanManager.assetsUnderManagement(),      1_000_080);
        assertEq(loanManager.issuanceRate(),               0.008e30);
        assertEq(loanManager.domainStart(),                5_000_000);
        assertEq(loanManager.domainEnd(),                  5_010_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);
        assertEq(loanManager.unrealizedLosses(),           0);

        MockLoan(loan).__setNextPaymentLateInterest(10);

        vm.prank(address(poolManager));
        ( bool liquidationComplete, uint256 remainingLosses_, uint256 platformFees_ ) = loanManager.triggerDefault(address(loan), address(liquidatorFactory));

        assertTrue(liquidationComplete);

        assertEq(remainingLosses_, 900_113);
        assertEq(platformFees_,    0);

        assertEq(loanManager.getAccruedInterest(),         0);
        assertEq(loanManager.accountedInterest(),          0);
        assertEq(loanManager.principalOut(),               0);
        assertEq(loanManager.assetsUnderManagement(),      0);
        assertEq(loanManager.issuanceRate(),               0);
        assertEq(loanManager.domainStart(),                5_011_000);
        assertEq(loanManager.domainEnd(),                  5_011_000);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);
        assertEq(loanManager.unrealizedLosses(),           0);
    }

}

contract FundLoanTests is LoanManagerBaseTest {

    uint256 principalRequested = 1_000_000e18;
    uint256 paymentInterest    = 1e18;
    uint256 paymentPrincipal   = 0;

    MockLoan loan;

    function setUp() public override {
        super.setUp();

        poolManager.setDelegateManagementFeeRate(delegateManagementFeeRate);

        loan = new MockLoan(address(collateralAsset), address(fundsAsset));

        // Set next payment information for loanManager to use.
        loan.__setPrincipalRequested(principalRequested);  // Simulate funding
        loan.__setNextPaymentInterest(paymentInterest);
        loan.__setNextPaymentPrincipal(paymentPrincipal);
        loan.__setNextPaymentDueDate(block.timestamp + 100);
    }

    function test_fund() external {
        fundsAsset.mint(address(loan), principalRequested);

        (
            uint256 incomingNetInterest_,
            uint256 refinanceInterest_,
            ,
            uint256 startDate_,
            uint256 paymentDueDate_,
            uint256 platformManagementFeeRate_,
            uint256 delegateManagementFeeRate_
        ) = loanManager.payments(1);

        assertEq(incomingNetInterest_,       0);
        assertEq(refinanceInterest_,         0);
        assertEq(startDate_,                 0);
        assertEq(paymentDueDate_,            0);
        assertEq(platformManagementFeeRate_, 0);
        assertEq(delegateManagementFeeRate_, 0);

        assertEq(loanManager.principalOut(),      0);
        assertEq(loanManager.accountedInterest(), 0);
        assertEq(loanManager.issuanceRate(),      0);
        assertEq(loanManager.domainEnd(),         0);
        assertEq(loanManager.domainStart(),       0);

        loan.__setPrincipal(principalRequested);  // Simulate intermediate state from funding

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));

        assertEq(loanManager.paymentIdOf(address(loan)), 1);

        (
            platformManagementFeeRate_,
            delegateManagementFeeRate_,
            startDate_,
            paymentDueDate_,
            incomingNetInterest_,
            refinanceInterest_,
        ) = loanManager.payments(1);

        // Check loan information
        assertEq(incomingNetInterest_,       0.8e18); // 1e18 of interest minus management fees
        assertEq(startDate_,                 block.timestamp);
        assertEq(paymentDueDate_,            block.timestamp + 100);
        assertEq(platformManagementFeeRate_, platformManagementFeeRate);
        assertEq(delegateManagementFeeRate_, delegateManagementFeeRate);

        assertEq(loanManager.principalOut(),      principalRequested);
        assertEq(loanManager.accountedInterest(), 0);
        assertEq(loanManager.issuanceRate(),      0.8e46);  // 0.7e18 * 1e30 / 100 = 0.7e46
        assertEq(loanManager.domainEnd(),         START + 100);
        assertEq(loanManager.domainStart(),       START);
    }

    function test_fund_failIfNotPoolManager() external {
        address notPoolManager = address(new Address());

        fundsAsset.mint(address(loan), principalRequested);

        vm.prank(notPoolManager);
        vm.expectRevert("LM:F:NOT_POOL_MANAGER");
        loanManager.fund(address(loan));
    }

}

contract LoanManagerSortingTests is LoanManagerBaseTest {

    address earliestLoan;
    address latestLoan;
    address medianLoan;
    address synchronizedLoan;

    LoanManagerHarness.PaymentInfo earliestPaymentInfo;
    LoanManagerHarness.PaymentInfo latestPaymentInfo;
    LoanManagerHarness.PaymentInfo medianPaymentInfo;
    LoanManagerHarness.PaymentInfo synchronizedPaymentInfo;

    function setUp() public override {
        super.setUp();

        earliestLoan     = address(new Address());
        medianLoan       = address(new Address());
        latestLoan       = address(new Address());
        synchronizedLoan = address(new Address());

        earliestPaymentInfo.paymentDueDate     = 10;
        medianPaymentInfo.paymentDueDate       = 20;
        synchronizedPaymentInfo.paymentDueDate = 20;
        latestPaymentInfo.paymentDueDate       = 30;
    }

    /******************************************************************************************************************************/
    /*** Add Payment                                                                                                            ***/
    /******************************************************************************************************************************/

    function test_addPaymentToList_single() external {
        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),                 1);
        assertEq(loanManager.paymentWithEarliestDueDate(),     1);

        ( uint24 previous, uint24 next, uint48 paymentDueDate ) = loanManager.sortedPayments(1);

        assertEq(previous,       0);
        assertEq(next,           0);
        assertEq(paymentDueDate, earliestPaymentInfo.paymentDueDate);
    }

    function test_addPaymentToList_ascendingPair() external {
        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        loanManager.addPaymentToList(latestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             2);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     0);
    }

    function test_addPaymentToList_descendingPair() external {
        loanManager.addPaymentToList(latestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             2);
        assertEq(loanManager.paymentWithEarliestDueDate(), 2);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 2);
        assertEq(next,     0);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 0);
        assertEq(next,     1);
    }

    function test_addPaymentToList_synchronizedPair() external {
        loanManager.addPaymentToList(medianPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        loanManager.addPaymentToList(synchronizedPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             2);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     0);
    }

    function test_addPaymentToList_toHead() external {
        loanManager.addPaymentToList(medianPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        loanManager.addPaymentToList(latestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             2);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     0);

        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             3);
        assertEq(loanManager.paymentWithEarliestDueDate(), 3);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 3);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     0);

        ( previous, next, ) = loanManager.sortedPayments(3);

        assertEq(previous, 0);
        assertEq(next,     1);
    }

    function test_addPaymentToList_toMiddle() external {
        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        loanManager.addPaymentToList(latestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             2);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     0);

        loanManager.addPaymentToList(medianPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             3);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     3);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 3);
        assertEq(next,     0);

        ( previous, next, ) = loanManager.sortedPayments(3);

        assertEq(previous, 1);
        assertEq(next,     2);
    }

    function test_addPaymentToList_toTail() external {
        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        loanManager.addPaymentToList(medianPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             2);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     0);

        loanManager.addPaymentToList(latestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             3);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     3);

        ( previous, next, ) = loanManager.sortedPayments(3);

        assertEq(previous, 2);
        assertEq(next,     0);
    }

    /******************************************************************************************************************************/
    /*** Remove Payment                                                                                                         ***/
    /******************************************************************************************************************************/

    function test_removePaymentFromList_invalidPaymentId() external {
        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 0);
        assertEq(next,     0);

        loanManager.removePaymentFromList(2);

        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 0);
        assertEq(next,     0);
    }

    function test_removePaymentFromList_single() external {
        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        loanManager.removePaymentFromList(1);

        assertEq(loanManager.paymentCounter(),             1);
        assertEq(loanManager.paymentWithEarliestDueDate(), 0);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);
    }

    function test_removePaymentFromList_pair() external {
        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);
        loanManager.addPaymentToList(latestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             2);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     0);

        loanManager.removePaymentFromList(1);

        assertEq(loanManager.paymentCounter(),             2);
        assertEq(loanManager.paymentWithEarliestDueDate(), 2);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 0);
        assertEq(next,     0);
    }

    function test_removePaymentFromList_earliestDueDate() external {
        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);
        loanManager.addPaymentToList(medianPaymentInfo.paymentDueDate);
        loanManager.addPaymentToList(latestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             3);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     3);

        ( previous, next, ) = loanManager.sortedPayments(3);

        assertEq(previous, 2);
        assertEq(next,     0);

        loanManager.removePaymentFromList(1);

        assertEq(loanManager.paymentCounter(),             3);
        assertEq(loanManager.paymentWithEarliestDueDate(), 2);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     0);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 0);
        assertEq(next,     3);

        ( previous, next, ) = loanManager.sortedPayments(3);

        assertEq(previous, 2);
        assertEq(next,     0);
    }

    function test_removePaymentFromList_medianDueDate() external {
        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);
        loanManager.addPaymentToList(medianPaymentInfo.paymentDueDate);
        loanManager.addPaymentToList(latestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             3);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     3);

        ( previous, next, ) = loanManager.sortedPayments(3);

        assertEq(previous, 2);
        assertEq(next,     0);

        loanManager.removePaymentFromList(2);

        assertEq(loanManager.paymentCounter(),             3);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     3);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 0);
        assertEq(next,     0);

        ( previous, next, ) = loanManager.sortedPayments(3);

        assertEq(previous, 1);
        assertEq(next,     0);
    }

    function test_removePaymentFromList_latestDueDate() external {
        loanManager.addPaymentToList(earliestPaymentInfo.paymentDueDate);
        loanManager.addPaymentToList(medianPaymentInfo.paymentDueDate);
        loanManager.addPaymentToList(latestPaymentInfo.paymentDueDate);

        assertEq(loanManager.paymentCounter(),             3);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( uint24 previous, uint24 next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     3);

        ( previous, next, ) = loanManager.sortedPayments(3);

        assertEq(previous, 2);
        assertEq(next,     0);

        loanManager.removePaymentFromList(3);

        assertEq(loanManager.paymentCounter(),             3);
        assertEq(loanManager.paymentWithEarliestDueDate(), 1);

        ( previous, next, ) = loanManager.sortedPayments(1);

        assertEq(previous, 0);
        assertEq(next,     2);

        ( previous, next, ) = loanManager.sortedPayments(2);

        assertEq(previous, 1);
        assertEq(next,     0);

        ( previous, next, ) = loanManager.sortedPayments(3);

        assertEq(previous, 0);
        assertEq(next,     0);
    }

}

contract QueueNextPaymentTests is LoanManagerBaseTest {

    uint256 internal principalRequested = 1_000_000e18;
    uint256 internal paymentInterest    = 1e18;
    uint256 internal paymentPrincipal   = 0;

    MockLoan internal loan;

    function setUp() public override {
        super.setUp();

        loan = new MockLoan(address(collateralAsset), address(fundsAsset));

        // Set next payment information for loanManager to use.
        loan.__setPrincipalRequested(principalRequested);  // Simulate funding
        loan.__setNextPaymentInterest(paymentInterest);
        loan.__setNextPaymentPrincipal(paymentPrincipal);
        loan.__setNextPaymentDueDate(block.timestamp + 100);
    }

    function test_queueNextPayment_fees() external {
        uint256 platformManagementFeeRate_ = 75_0000;
        uint256 delegateManagementFeeRate_ = 50_0000;

        MockGlobals(globals).setPlatformManagementFeeRate(address(poolManager), platformManagementFeeRate_);
        poolManager.setDelegateManagementFeeRate(delegateManagementFeeRate_);

        loanManager.__queueNextPayment(address(loan), block.timestamp, block.timestamp + 30 days);

        uint256 paymentId = loanManager.paymentIdOf(address(loan));
        ILoanManagerStructs.PaymentInfo memory paymentInfo = ILoanManagerStructs(address(loanManager)).payments(paymentId);

        assertEq(paymentInfo.platformManagementFeeRate, 75_0000);
        assertEq(paymentInfo.delegateManagementFeeRate, 25_0000);  // Gets reduced to 0.25 so sum is less than 100%
    }

    function testFuzz_queueNextPayment_fees(uint256 platformManagementFeeRate_, uint256 delegateManagementFeeRate_) external {
        platformManagementFeeRate_ = constrictToRange(platformManagementFeeRate_, 0, 100_0000);
        delegateManagementFeeRate_ = constrictToRange(delegateManagementFeeRate_, 0, 100_0000);

        MockGlobals(globals).setPlatformManagementFeeRate(address(poolManager), platformManagementFeeRate_);
        poolManager.setDelegateManagementFeeRate(delegateManagementFeeRate_);

        loanManager.__queueNextPayment(address(loan), block.timestamp, block.timestamp + 30 days);

        uint256 paymentId = loanManager.paymentIdOf(address(loan));
        ILoanManagerStructs.PaymentInfo memory paymentInfo = ILoanManagerStructs(address(loanManager)).payments(paymentId);

        assertEq(paymentInfo.platformManagementFeeRate, platformManagementFeeRate_);

        assertTrue(paymentInfo.platformManagementFeeRate + paymentInfo.delegateManagementFeeRate <= 100_0000);
    }

}

contract UintCastingTests is LoanManagerBaseTest {

    function test_castUint24() external {
        vm.expectRevert("LM:UINT24_CAST_OOB");
        loanManager.castUint24(2 ** 24);

        uint256 castedValue = loanManager.castUint24(2 ** 24 - 1);

        assertEq(castedValue, 2 ** 24 - 1);
    }

    function test_castUint48() external {
        vm.expectRevert("LM:UINT48_CAST_OOB");
        loanManager.castUint48(2 ** 48);

        uint256 castedValue = loanManager.castUint48(2 ** 48 - 1);

        assertEq(castedValue, 2 ** 48 - 1);
    }

    function test_castUint96() external {
        vm.expectRevert("LM:UINT96_CAST_OOB");
        loanManager.castUint96(2 ** 96);

        uint256 castedValue = loanManager.castUint96(2 ** 96 - 1);

        assertEq(castedValue, 2 ** 96 - 1);
    }

    function test_castUint112() external {
        vm.expectRevert("LM:UINT112_CAST_OOB");
        loanManager.castUint112(2 ** 112);

        uint256 castedValue = loanManager.castUint112(2 ** 112 - 1);

        assertEq(castedValue, 2 ** 112 - 1);
    }

    function test_castUint120() external {
        vm.expectRevert("LM:UINT120_CAST_OOB");
        loanManager.castUint120(2 ** 120);

        uint256 castedValue = loanManager.castUint120(2 ** 120 - 1);

        assertEq(castedValue, 2 ** 120 - 1);
    }

    function test_castUint128() external {
        vm.expectRevert("LM:UINT128_CAST_OOB");
        loanManager.castUint128(2 ** 128);

        uint256 castedValue = loanManager.castUint128(2 ** 128 - 1);

        assertEq(castedValue, 2 ** 128 - 1);
    }
}

contract UpdateAccountingFailureTests is LoanManagerBaseTest {

    function test_updateAccounting_notPoolDelegate() external {
        vm.expectRevert("LM:UA:NOT_AUTHORIZED");
        loanManager.updateAccounting();

        vm.prank(poolDelegate);
        loanManager.updateAccounting();
    }

    function test_updateAccounting_notGovernor() external {
        vm.expectRevert("LM:UA:NOT_AUTHORIZED");
        loanManager.updateAccounting();

        vm.prank(governor);
        loanManager.updateAccounting();
    }

}

contract UpdateAccountingTests is LoanManagerClaimBaseTest {

    MockLoan loan1;
    MockLoan loan2;

    function setUp() public override {
        super.setUp();

        loan1 = new MockLoan(address(collateralAsset), address(fundsAsset));
        loan2 = new MockLoan(address(collateralAsset), address(fundsAsset));

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

    function test_updateAccounting_failifPaused() external {
        globals.__setProtocolPaused(true);

        vm.prank(poolDelegate);
        vm.expectRevert("LM:UA:PROTOCOL_PAUSED");
        loanManager.updateAccounting();
    }

    function test_updateAccounting_beforeDomainEnd() external {
        vm.warp(START + 8_000);

        _assertLoanManagerState({
            accruedInterest:       16 + 20,
            accountedInterest:     48,             // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_084,
            issuanceRate:          0.018e30,
            domainStart:           START + 6_000,
            domainEnd:             START + 10_000  // End of loan1 payment interval
        });

        _assertTotalAssets(2_000_084);

        vm.prank(poolDelegate);
        loanManager.updateAccounting();

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     84,             // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_084,
            issuanceRate:          0.018e30,
            domainStart:           START + 8_000,
            domainEnd:             START + 10_000  // End of loan1 payment interval
        });

        _assertTotalAssets(2_000_084);
    }

    function test_updateAccounting_afterDomainEnd() external {
        vm.warp(START + 12_000);

        _assertLoanManagerState({
            accruedInterest:       32 + 40,
            accountedInterest:     48,             // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_120,
            issuanceRate:          0.018e30,
            domainStart:           START + 6_000,
            domainEnd:             START + 10_000  // End of loan1 payment interval
        });

        _assertTotalAssets(2_000_120);

        vm.prank(poolDelegate);
        loanManager.updateAccounting();

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     140,             // 120 + 20 from loan2
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_140,
            issuanceRate:          0.01e30,
            domainStart:           START + 12_000,
            domainEnd:             START + 16_000  // End of loan1 payment interval
        });

        _assertTotalAssets(2_000_140);
    }

    function test_updateAccounting_afterTwoDomainEnds() external {
        vm.warp(START + 20_000);

        _assertLoanManagerState({
            accruedInterest:       32 + 40,
            accountedInterest:     48,             // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_120,
            issuanceRate:          0.018e30,
            domainStart:           START + 6_000,
            domainEnd:             START + 10_000  // End of loan1 payment interval
        });

        _assertTotalAssets(2_000_120);

        vm.prank(poolDelegate);
        loanManager.updateAccounting();

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     180,             // Accounted during loan2 funding.
            principalOut:          2_000_000,
            assetsUnderManagement: 2_000_180,
            issuanceRate:          0,
            domainStart:           START + 20_000,
            domainEnd:             START + 20_000  // End of loan1 payment interval
        });

        _assertTotalAssets(2_000_180);
    }

}

contract SetterTests is LoanManagerBaseTest {

    function setUp() public override {
        super.setUp();

        loanManager.__setDomainStart(START);
        loanManager.__setDomainEnd(START + 1_000_000);
        loanManager.__setIssuanceRate(0.1e30);
        loanManager.__setPrincipalOut(1_000_000e6);
        loanManager.__setAccountedInterest(10_000e6);
    }

    function test_getAccruedInterest() external {
        // At the start accrued interest is zero.
        assertEq(loanManager.getAccruedInterest(), 0);

        vm.warp(START + 1_000);
        assertEq(loanManager.getAccruedInterest(), 100);

        vm.warp(START + 22_222);
        assertEq(loanManager.getAccruedInterest(), 2222);

        vm.warp(START + 888_888);
        assertEq(loanManager.getAccruedInterest(), 88888);

        vm.warp(START + 1_000_000);
        assertEq(loanManager.getAccruedInterest(), 100_000);

        vm.warp(START + 1_000_000 + 1);
        assertEq(loanManager.getAccruedInterest(), 100_000);

        vm.warp(START + 2_000_000);
        assertEq(loanManager.getAccruedInterest(), 100_000);
    }

    function test_getAssetsUnderManagement() external {
        // At the start there's only principal out and accounted interest
        assertEq(loanManager.assetsUnderManagement(), 1_000_000e6 + 10_000e6);

         vm.warp(START + 1_000);
        assertEq(loanManager.assetsUnderManagement(), 1_000_000e6 + 10_000e6 + 100);

        vm.warp(START + 22_222);
        assertEq(loanManager.assetsUnderManagement(), 1_000_000e6 + 10_000e6 + 2222);

        vm.warp(START + 888_888);
        assertEq(loanManager.assetsUnderManagement(), 1_000_000e6 + 10_000e6 + 88888);

        vm.warp(START + 1_000_000);
        assertEq(loanManager.assetsUnderManagement(), 1_000_000e6 + 10_000e6 + 100_000);

        vm.warp(START + 1_000_000 + 1);
        assertEq(loanManager.assetsUnderManagement(), 1_000_000e6 + 10_000e6 + 100_000);

        vm.warp(START + 2_000_000);
        assertEq(loanManager.assetsUnderManagement(), 1_000_000e6 + 10_000e6 + 100_000);
    }

}

contract DisburseLiquidationFundsTests is LoanManagerBaseTest {

    function test_disburseLiquidationFunds_mapleTreasuryNotSet() external {
        globals.setMapleTreasury(address(0));

        MockLoan loan = new MockLoan(address(collateralAsset), address(fundsAsset));

        fundsAsset.mint(address(loanManager), 300);

        vm.expectRevert("LM:DLF:ZERO_ADDRESS");
        loanManager.disburseLiquidationFunds(address(loan), 100, 100, 100);
    }

}

contract DistributeClaimedFunds is LoanManagerBaseTest {

    function test_distributeClaimedFunds_mapleTreasuryNotSet() external {
        globals.setMapleTreasury(address(0));

        MockLoan loan = new MockLoan(address(collateralAsset), address(fundsAsset));

        fundsAsset.mint(address(loanManager), 200);

        // Queue next payment to add loan to 
        loanManager.__queueNextPayment(address(loan), START, START + 100);

        vm.expectRevert("LM:DCF:ZERO_ADDRESS");
        loanManager.distributeClaimedFunds(address(loan), 100, 100);
    }

}

contract SetLoanTransferAdmin_SetterTests is LoanManagerBaseTest {

    address SET_ADDRESS = address(new Address());

    function test_setLoanTransferAdmin_notPoolDelegate() external {
        vm.expectRevert("LM:SLTA:NOT_PD");
        loanManager.setLoanTransferAdmin(SET_ADDRESS);
    }

    function test_setLoanTransferAdmin_success() external {
        assertEq(loanManager.loanTransferAdmin(), address(0));

        vm.prank(poolDelegate);
        loanManager.setLoanTransferAdmin(SET_ADDRESS);

        assertEq(loanManager.loanTransferAdmin(), SET_ADDRESS);

        vm.prank(poolDelegate);
        loanManager.setLoanTransferAdmin(address(0));

        assertEq(loanManager.loanTransferAdmin(), address(0));
    }

}

contract SetOwnershipToTests is LoanManagerBaseTest {

    address loan1 = address(new MockLoan(address(collateralAsset), address(fundsAsset)));
    address loan2 = address(new MockLoan(address(collateralAsset), address(fundsAsset)));
    address loan3 = address(new MockLoan(address(collateralAsset), address(fundsAsset)));

    address loanTransferAdmin = address(new Address());
    address destination       = address(new Address());

    function setUp() public override {
        super.setUp();

        vm.prank(poolDelegate);
        loanManager.setLoanTransferAdmin(loanTransferAdmin);
    }

    function test_setOwnershipTo_notLoanTransferAdmin() external {
        address[] memory loans = new address[](3);
        loans[0] = loan1;
        loans[1] = loan2;
        loans[2] = loan3;

        address[] memory destinations = new address[](3);
        destinations[0] = destination;
        destinations[1] = destination;
        destinations[2] = destination;

        vm.expectRevert("LM:SOT:NOT_LTA");
        loanManager.setOwnershipTo(loans, destinations);

        // Set admin to zero to revoke privilege
        vm.prank(poolDelegate);
        loanManager.setLoanTransferAdmin(address(0));

        vm.prank(loanTransferAdmin);
        vm.expectRevert("LM:SOT:NOT_LTA");
        loanManager.setOwnershipTo(loans, destinations);
    }

    function test_setOwnershipTo_success() external {
        address[] memory loans = new address[](3);
        loans[0] = loan1;
        loans[1] = loan2;
        loans[2] = loan3;

        address[] memory destinations = new address[](3);
        destinations[0] = destination;
        destinations[1] = destination;
        destinations[2] = destination;

        vm.prank(loanTransferAdmin);
        loanManager.setOwnershipTo(loans, destinations);
    }

}

contract TakeOwnershipTests is LoanManagerBaseTest {

    address loan1 = address(new MockLoan(address(collateralAsset), address(fundsAsset)));
    address loan2 = address(new MockLoan(address(collateralAsset), address(fundsAsset)));
    address loan3 = address(new MockLoan(address(collateralAsset), address(fundsAsset)));

    address loanTransferAdmin = address(new Address());

    function setUp() public override {
        super.setUp();

        vm.prank(poolDelegate);
        loanManager.setLoanTransferAdmin(loanTransferAdmin);
    }

    function test_takeOwnership_notLoanTransferAdmin() external {
        address[] memory loans = new address[](3);
        loans[0] = loan1;
        loans[1] = loan2;
        loans[2] = loan3;

        vm.expectRevert("LM:TO:NOT_LTA");
        loanManager.takeOwnership(loans);

        // Set admin to zero to revoke privilege
        vm.prank(poolDelegate);
        loanManager.setLoanTransferAdmin(address(0));

        vm.prank(loanTransferAdmin);
        vm.expectRevert("LM:TO:NOT_LTA");
        loanManager.takeOwnership(loans);
    }

    function test_takeOwnership_success() external {
        address[] memory loans = new address[](3);
        loans[0] = loan1;
        loans[1] = loan2;
        loans[2] = loan3;

        vm.prank(loanTransferAdmin);
        loanManager.takeOwnership(loans);
    }

}

