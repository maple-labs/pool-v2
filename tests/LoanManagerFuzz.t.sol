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

// TODO: Can we add tests for 2 claims on the same loan without any payments between them?

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
        uint256 paymentDueDate
    )
        internal
    {
        ( , , uint256 startDate_, uint256 paymentDueDate_, uint256 incomingNetInterest_, uint256 refinanceInterest_, ) = loanManager.payments(loanManager.paymentIdOf(loan));

        assertEq(incomingNetInterest_, incomingNetInterest);
        assertEq(refinanceInterest_,   refinanceInterest);
        assertEq(startDate_,           startDate);
        assertEq(paymentDueDate_,      paymentDueDate);
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
        internal
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
        internal
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

contract SingleLoanClaimTests is LoanManagerClaimBaseTest {

    function testFuzz_claim_latePayment_interestOnly(
        uint256 principal,
        uint256 interest,
        uint256 lateInterest,
        uint256 paymentInterval,
        uint256 lateInterval
    ) external {
        principal       = constrictToRange(principal,       100,     1e29);
        interest        = constrictToRange(interest,        10,      principal / 10);
        lateInterest    = constrictToRange(lateInterest,    1,       interest / 10);
        paymentInterval = constrictToRange(paymentInterval, 1 days,  100 days);
        lateInterval    = constrictToRange(lateInterval,    1 hours, paymentInterval);

        MockLoan loan = new MockLoan(address(collateralAsset), address(fundsAsset));

        // Set next payment information for loanManager to use.
        loan.__setPrincipal(principal);
        loan.__setPrincipalRequested(principal);
        loan.__setNextPaymentInterest(interest);
        loan.__setNextPaymentDueDate(START + paymentInterval);

        vm.prank(address(poolManager));
        loanManager.fund(address(loan));

        vm.warp(START + paymentInterval + lateInterval);

        uint256 netInterest        = interest * 80/100;
        uint256 issuanceRate       = netInterest * 1e30 / paymentInterval;
        uint256 roundedNetInterest = issuanceRate * paymentInterval / 1e30;

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: roundedNetInterest,
            refinanceInterest:   0,
            startDate:           START,
            paymentDueDate:      START + paymentInterval
        });

        _assertLoanManagerState({
            accruedInterest:       roundedNetInterest,
            accountedInterest:     0,
            principalOut:          principal,
            assetsUnderManagement: principal + roundedNetInterest,
            issuanceRate:          issuanceRate,
            domainStart:           START,
            domainEnd:             START + paymentInterval
        });

        _assertBalances({
            poolBalance:         0,
            treasuryBalance:     0,
            poolDelegateBalance: 0
        });

        _assertTotalAssets(principal + roundedNetInterest);

        _makeLatePayment({
            loan:                address(loan),
            interestAmount:      interest,             // 4000 seconds late at the premium interest rate (10_000 * 0.01 + 4000 * 0.015 = 160)
            lateInterestAmount:  lateInterest,
            principalAmount:     0,
            nextInterestPayment: interest,
            nextPaymentDueDate:  START + paymentInterval * 2
        });

        _assertPaymentInfo({
            loan:                address(loan),
            incomingNetInterest: roundedNetInterest,
            refinanceInterest:   0,
            startDate:           START + paymentInterval,
            paymentDueDate:      START + paymentInterval * 2
        });

        _assertLoanManagerState({
            accruedInterest:       0,
            accountedInterest:     issuanceRate * lateInterval / 1e30,
            principalOut:          principal,
            assetsUnderManagement: principal + issuanceRate * lateInterval / 1e30,
            issuanceRate:          issuanceRate,
            domainStart:           START + paymentInterval + lateInterval,
            domainEnd:             START + paymentInterval * 2
        });

        uint256 treasuryFee          = (interest + lateInterest) * 5/100;
        uint256 poolDelegateFee      = (interest + lateInterest) * 15/100;
        uint256 poolInterestReceived = interest + lateInterest - treasuryFee - poolDelegateFee;

        _assertBalances({
            poolBalance:         poolInterestReceived,
            treasuryBalance:     treasuryFee,
            poolDelegateBalance: poolDelegateFee
        });

        _assertTotalAssets(principal + poolInterestReceived + issuanceRate * lateInterval / 1e30);
    }

}
