// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, console, TestUtils }           from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                             from "../modules/erc20/contracts/test/mocks/MockERC20.sol";
import { IMapleProxyFactory, MapleProxyFactory } from "../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

import { LoanManagerFactory }     from "../contracts/proxy/LoanManagerFactory.sol";
import { LoanManagerInitializer } from "../contracts/proxy/LoanManagerInitializer.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import { GlobalsBootstrapper } from "./bootstrap/GlobalsBootstrapper.sol";

import { LoanManager }  from "../contracts/LoanManager.sol";
import { Pool }         from "../contracts/Pool.sol";
import { PoolManager }  from "../contracts/PoolManager.sol";
import { PoolDeployer } from "../contracts/PoolDeployer.sol";

import {
    MockGlobals,
    MockLoan,
    MockLiquidationStrategy,
    MockProxied,
    MockWithdrawalManagerInitializer
} from "./mocks/Mocks.sol";

import { ILoanManagerLike } from "./interfaces/Interfaces.sol";

/// @dev Suite of tests that use PoolManagers, Pools, LoanManagers and Factories
contract IntegrationTestBase is GlobalsBootstrapper {

    uint256 COLLATERAL_PRICE = 2;
    uint256 FUNDS_PRICE      = 1;

    address BORROWER = address(new Address());
    address LP       = address(new Address());
    address PD       = address(new Address());

    address loanManagerImplementation = address(new LoanManager());
    address loanManagerInitializer    = address(new LoanManagerInitializer());

    address poolManagerImplementation = address(new PoolManager());
    address poolManagerInitializer    = address(new PoolManagerInitializer());

    address withdrawalManagerImplementation = address(new MockProxied());
    address withdrawalManagerInitializer    = address(new MockWithdrawalManagerInitializer());

    address poolDeployer;
    address poolDelegateCover;

    MockERC20 collateralAsset;
    MockERC20 fundsAsset;

    LoanManager        loanManager;
    LoanManagerFactory loanManagerFactory;

    Pool               pool;
    PoolManager        poolManager;
    PoolManagerFactory poolManagerFactory;

    IMapleProxyFactory withdrawalManagerFactory;

    function setUp() public virtual {
        collateralAsset = new MockERC20("CollateralAsset", "CA", 18);
        fundsAsset      = new MockERC20("FundsAsset",      "FA", 18);

        _deployAndBootstrapGlobals(address(fundsAsset), PD);

        // Deploy factories.
        poolManagerFactory       = new PoolManagerFactory(globals);
        loanManagerFactory       = new LoanManagerFactory(globals);
        withdrawalManagerFactory = new MapleProxyFactory(globals);

        // Register implementations used by factories.
        vm.startPrank(GOVERNOR);
        poolManagerFactory.registerImplementation(1, poolManagerImplementation, poolManagerInitializer);
        poolManagerFactory.setDefaultVersion(1);

        loanManagerFactory.registerImplementation(1, loanManagerImplementation, loanManagerInitializer);
        loanManagerFactory.setDefaultVersion(1);

        withdrawalManagerFactory.registerImplementation(1, withdrawalManagerImplementation, withdrawalManagerInitializer);
        withdrawalManagerFactory.setDefaultVersion(1);
        vm.stopPrank();

        // Deploy pool deployer.
        poolDeployer = address(new PoolDeployer(globals));

        // Configure additional globals settings.
        MockGlobals(globals).setValidBorrower(BORROWER, true);
        MockGlobals(globals).setValidPoolDeployer(poolDeployer, true);

        // Deploy pool, pool manager, loan manager, withdrawal manager, pool delegate cover.
        _deployPoolInfra();

        // Configure PoolManager.
        vm.startPrank(PD);
        poolManager.setLiquidityCap(type(uint256).max);
        poolManager.setAllowedLender(LP, true);
        poolManager.setOpenToPublic();
        vm.stopPrank();

    }

    /************************/
    /*** Helper Functions ***/
    /************************/

    function _deployPoolInfra() internal {
        address[3] memory factories_ = [
            address(poolManagerFactory),
            address(loanManagerFactory),
            address(withdrawalManagerFactory)
        ];

        address[3] memory initializers_ = [
            poolManagerInitializer,
            loanManagerInitializer,
            withdrawalManagerInitializer
        ];

        uint256 coverAmountRequired = 0;  // This will be added to the cover contract at test time, to be able to test different liquidation scenarios.
        uint256[5] memory configParams_ = [
            1_000_000e18,
            0,
            coverAmountRequired,
            1 days,
            3 days
        ];

        vm.startPrank(PD);

        ( address poolManager_, address loanManager_, ) = PoolDeployer(poolDeployer).deployPool(
            factories_,
            initializers_,
            address(fundsAsset),
            "Pool",
            "Pool-LP",
            configParams_
        );

        // Store relevant contracts to storage.
        poolManager       = PoolManager(poolManager_);
        loanManager       = LoanManager(loanManager_);
        pool              = Pool(poolManager.pool());
        poolDelegateCover = poolManager.poolDelegateCover();

        vm.stopPrank();
    }

    function _mintAndDeposit(uint256 amount_) internal {
        address depositor = address(1);  // Use a non-address(this) address for deposit
        fundsAsset.mint(depositor, amount_);
        vm.startPrank(depositor);
        fundsAsset.approve(address(pool), amount_);
        pool.deposit(amount_, address(this));
        vm.stopPrank();
    }

    function _createFundAndDrawdownLoan(uint256 principalRequested_, uint256 collateralRequired_, uint256 nextPaymentDueDate_, uint256 nextPaymentInterest_) internal returns (MockLoan loan) {
        loan = new MockLoan(address(collateralAsset), address(fundsAsset));

        loan.__setBorrower(BORROWER);

        loan.__setPrincipalRequested(principalRequested_);
        loan.__setCollateralRequired(collateralRequired_);
        loan.__setNextPaymentDueDate(nextPaymentDueDate_);
        loan.__setNextPaymentInterest(nextPaymentInterest_);

        loan.__setPrincipal(principalRequested_);
        loan.__setCollateral(collateralRequired_);

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
        fundsAsset.mint(address(loanManager), interestAmount + principalAmount);
        loan_.__setPrincipal(loan_.principal() - principalAmount);
        loan_.__setNextPaymentInterest(nextInterestPayment);
        loan_.__setNextPaymentDueDate(nextPaymentDueDate);
    }

    function _assertLoanInfo(
        LoanManager.LoanInfo memory loanInfo_,
        uint256 incomingNetInterest_,
        uint256 refinanceInterest_,
        uint256 issuanceRate_,
        uint256 startDate_,
        uint256 paymentDueDate_
    ) internal {
        assertEq(loanInfo_.incomingNetInterest, incomingNetInterest_);
        assertEq(loanInfo_.refinanceInterest,   refinanceInterest_);
        assertEq(loanInfo_.issuanceRate,        issuanceRate_);
        assertEq(loanInfo_.startDate,           startDate_);
        assertEq(loanInfo_.paymentDueDate,      paymentDueDate_);
    }

    function _assertLoanManager(
        uint256 accruedInterest_,
        uint256 accountedInterest_,
        uint256 principalOut_,
        uint256 assetsUnderManagement_,
        uint256 issuanceRate_,
        uint256 domainStart_,
        uint256 domainEnd_,
        uint256 unrealizedLosses_
    ) internal {
        assertEq(loanManager.getAccruedInterest(),    accruedInterest_);
        assertEq(loanManager.accountedInterest(),     accountedInterest_);
        assertEq(loanManager.principalOut(),          principalOut_);
        assertEq(loanManager.assetsUnderManagement(), assetsUnderManagement_);
        assertEq(loanManager.issuanceRate(),          issuanceRate_);
        assertEq(loanManager.domainStart(),           domainStart_);
        assertEq(loanManager.domainEnd(),             domainEnd_);
        assertEq(loanManager.unrealizedLosses(),      unrealizedLosses_);
    }

    function _assertAssetBalances(
        address asset_,
        address loan_,
        uint256 loanBalance_,
        uint256 poolBalance_,
        uint256 poolManagerBalance_
    ) internal {
        assertEq(MockERC20(asset_).balanceOf(address(loan_)),       loanBalance_);
        assertEq(MockERC20(asset_).balanceOf(address(pool)),        poolBalance_);
        assertEq(MockERC20(asset_).balanceOf(address(poolManager)), poolManagerBalance_);
    }

    function _assertPoolAndPoolManager(
        uint256 totalAssets_,
        uint256 unrealizedLosses_
    ) internal {
        assertEq(pool.totalAssets(),             totalAssets_);
        assertEq(poolManager.totalAssets(),      totalAssets_);
        assertEq(poolManager.unrealizedLosses(), unrealizedLosses_);
    }

}

contract FeeDistributionTest is IntegrationTestBase {

    uint256 principalRequested        = 1_000_000e18;
    uint256 platformManagementFeeRate = 0.03e18;
    uint256 delegateManagementFeeRate = 0.07e18;

    function setUp() public override {
        super.setUp();

        MockGlobals(globals).setPlatformManagementFeeRate(address(poolManager), platformManagementFeeRate);
        MockGlobals(globals).setValidBorrower(BORROWER, true);

        vm.prank(PD);
        poolManager.setDelegateManagementFeeRate(delegateManagementFeeRate);
    }

    function test_feeDistribution() external {
        _depositLP(LP, principalRequested);

        MockLoan loan_ = _createFundAndDrawdownLoan(principalRequested, 0, block.timestamp + 30 days, 0);

        vm.warp(loan_.nextPaymentDueDate());

        uint256 interestPayment = 1_000e18;

        assertEq(fundsAsset.balanceOf(address(loan_)),    0);
        assertEq(fundsAsset.balanceOf(address(pool)),     0);
        assertEq(fundsAsset.balanceOf(address(TREASURY)), 0);
        assertEq(fundsAsset.balanceOf(address(PD)),       0);

        // Simulate an interest payment
        fundsAsset.mint(address(loanManager), interestPayment);

        vm.prank(address(loan_));
        loanManager.claim(0, interestPayment, block.timestamp + 30 days);

        assertEq(fundsAsset.balanceOf(address(loan_)),    0);
        assertEq(fundsAsset.balanceOf(address(pool)),     900e18); // 10% of the interest paid
        assertEq(fundsAsset.balanceOf(address(TREASURY)), 30e18);  // 30% of 100e18 (10% of interest paid)
        assertEq(fundsAsset.balanceOf(address(PD)),       70e18);  // 70% of 100e18 (10% of interest paid)
    }

}

contract TriggerDefaultWarningTest is IntegrationTestBase {

    // TODO: Update all tests to use management fees

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(PD);

        MockGlobals(globals).__setLatestPrice(address(fundsAsset),      FUNDS_PRICE);
        MockGlobals(globals).__setLatestPrice(address(collateralAsset), COLLATERAL_PRICE);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), MockGlobals(globals).HUNDRED_PERCENT());

        vm.stopPrank();
    }

    /**
     *    @dev Loan 1
     *
     *    CONFIGURATION:
     *    Start date:        5_000_000
     *    Management fee:    0%
     *    Principal:         1_000_000
     *    Collateral:        300_000 (in collateral asset, worth 600_000 in funds asset)
     *    Cover:             50_000
     *    Incoming interest: 100
     *    Issuance rate:     0.01e30 (100 / 10_000)
     *    Payment Interval:  10_000
     *
     *    DEFAULT WARNING:
     *    Next Payment due date: 6_000 (60% of the payment interval)
     *    Unrealized Losses:     1_000_000 + .6 * 100 (principal + accrued interest)
     *
     *    TRIGGER COLLATERAL LIQUIDATION:
     *    Shortfall: 1_000_000 + .6 * 100 = 1_000_060 (principal + full payment interest)
     *
     *    FINISH COLLATERAL LIQUIDATION:
     *    Collateral liquidated:     600_000 fundsAsset (100% of the collateral)
     *    Remaining losses:          1_000_060 - 600_000 = 400_060
     *    Cover liquidated:          50_000 fundsAsset (100% of the cover)
     *    Remaining loss to realize: 1_000_060 - 650_000 = 350_060
     *    Cash returned to pool:     650_000 (which should also be total assets)
     */
    function test_liquidation_triggerDefaultWarning_fullLiquidation() external {
        uint256 coverAmount = 50_000;

        vm.startPrank(PD);
        MockERC20(fundsAsset).approve(address(poolManager), coverAmount);
        MockERC20(fundsAsset).mint(PD, coverAmount);

        poolManager.depositCover(coverAmount);
        vm.stopPrank();

        uint256 START = 5_000_000;
        vm.warp(START);

        uint256 principalRequested = 1_000_000;
        uint256 collateralRequired = principalRequested / COLLATERAL_PRICE * 6 / 10;  // 60% collateralized (300k)

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired, START + 10_000, 100);

        LoanManager.LoanInfo memory loanInfo = ILoanManagerLike(address(loanManager)).loans(loanManager.loanIdOf(address(loan)));

        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_000_000,
            paymentDueDate_:      5_010_000
        });

        _assertLoanManager({
            accruedInterest_:       0,
            accountedInterest_:     0,
            principalOut_:          1_000_000,
            assetsUnderManagement_: 1_000_000,
            issuanceRate_:          0.01e30,
            domainStart_:           5_000_000,
            domainEnd_:             5_010_000,
            unrealizedLosses_:      0
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_000,
            unrealizedLosses_: 0
        });

        vm.warp(START + 6_000);

        loanInfo = ILoanManagerLike(address(loanManager)).loans(loanManager.loanIdOf(address(loan)));

        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_000_000,
            paymentDueDate_:      5_010_000
        });

        _assertLoanManager({
            accruedInterest_:       60,
            accountedInterest_:     0,
            principalOut_:          1_000_000,
            assetsUnderManagement_: 1_000_060,
            issuanceRate_:          0.01e30,
            domainStart_:           5_000_000,
            domainEnd_:             5_010_000,
            unrealizedLosses_:      0
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_060,
            unrealizedLosses_: 0
        });

        vm.prank(PD);
        poolManager.triggerDefaultWarning(address(loan), block.timestamp);

        loanInfo = ILoanManagerLike(address(loanManager)).loans(loanManager.loanIdOf(address(loan)));

        // Loan info doesn't change, in case we want to revert the default warning.
        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_000_000,
            paymentDueDate_:      5_010_000
        });

        _assertLoanManager({
            accruedInterest_:       0,         // Issuance rate is now 0, so no interest accrued.
            accountedInterest_:     60,        // Accrued interest up until trigger default warning is 60, which we have reflected as a loss.
            principalOut_:          1_000_000, // Principal out should be unchanged, and will decrease in the liquidation flow.
            assetsUnderManagement_: 1_000_060, // Assets under management is now only the principal out, since we unaccrued the interest. Since they still have a chance to pay, principal out is still included.
            issuanceRate_:          0,
            domainStart_:           5_006_000,
            domainEnd_:             5_006_000,
            unrealizedLosses_:      1_000_060
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_060,
            unrealizedLosses_: 1_000_060
        });

        // NOTE: This is an atomic triggerDefaultWarning and triggerCollateralLiquidation call, in practice this won't happen.
        // NOTE: This is only possible because of MockLoan not using grace period logic.

        vm.prank(PD);
        poolManager.triggerCollateralLiquidation(address(loan));

        uint256 loanId = loanManager.loanIdOf(address(loan));

        assertEq(loanId, 0);  // Loan should be deleted.

        _assertLoanManager({
            accruedInterest_:       0,
            accountedInterest_:     60,
            principalOut_:          1_000_000,
            assetsUnderManagement_: 1_000_060,
            issuanceRate_:          0,
            domainStart_:           5_006_000,
            domainEnd_:             5_006_000,
            unrealizedLosses_:      1_000_060
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_060,
            unrealizedLosses_: 1_000_060
        });

        ( uint256 defaultAmount, address liquidator ) = loanManager.liquidationInfo(address(loan));

        assertEq(defaultAmount, 1_000_060);  // Principal + accrued interest

        assertEq(loanManager.getExpectedAmount(address(collateralAsset), collateralRequired), 600_000);

        assertEq(collateralAsset.balanceOf(address(loan)),        0);
        assertEq(collateralAsset.balanceOf(address(loanManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),  300_000);
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
        assertEq(fundsAsset.balanceOf(address(loanManager)),      600_000);  // 300k @ $2

        vm.prank(PD);
        poolManager.finishCollateralLiquidation(address(loan));

        _assertLoanManager({
            accruedInterest_:       0,
            accountedInterest_:     0,
            principalOut_:          0,
            assetsUnderManagement_: 0,
            issuanceRate_:          0,
            domainStart_:           5_006_000,
            domainEnd_:             5_006_000,
            unrealizedLosses_:      0
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        650_000,  // Collateral + cover
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      650_000,
            unrealizedLosses_: 0
        });
    }

    /**
     *    @dev Loan 1
     *
     *    CONFIGURATION:
     *    Start date:        5_000_000
     *    Management fee:    0%
     *    Principal:         1_000_000
     *    Collateral:        300_000 (in collateral asset, worth 600_000 in funds asset)
     *    Cover:             50_000
     *    Incoming interest: 100 (100 per each 10_000 seconds)
     *    Issuance rate:     0.01e30 (100 / 10_000)
     *    Payment Interval:  10_000
     *
     *    DEFAULT WARNING:
     *    Next Payment due date: 6_000 (60% of the payment interval)
     *    Unrealized Losses:     1_000_000 + .6 * 100 (principal + accrued interest)
     *
     *    MAKE PAYMENT:
     *    Late payment timestamp: START + 7_000 (1_000 seconds late)
     *    Late interest:          30 = 3 * 100 * 1_000 / 10_000 (3 * 100 per 10_000 seconds, 3 times the normal rate)
     *    Total interest:         120 = 100 + 30
     *    Cash returned to pool:  10_130 = 10_000 + 130
     *    Resulting total assets: 1_000_140 = 1_000_000 + 130 + 10 already accrued interest from next payment.
     */
    function test_liquidation_triggerDefaultWarning_payInGracePeriod() external {
        uint256 coverAmount = 50_000;

        vm.startPrank(PD);
        MockERC20(fundsAsset).approve(address(poolManager), coverAmount);
        MockERC20(fundsAsset).mint(PD, coverAmount);

        poolManager.depositCover(coverAmount);
        vm.stopPrank();

        uint256 START = 5_000_000;
        vm.warp(START);

        uint256 principalRequested = 1_000_000;
        uint256 collateralRequired = principalRequested / COLLATERAL_PRICE * 6 / 10;  // 60% collateralized

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired, START + 10_000, 100);

        LoanManager.LoanInfo memory loanInfo = ILoanManagerLike(address(loanManager)).loans(loanManager.loanIdOf(address(loan)));

        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_000_000,
            paymentDueDate_:      5_010_000
        });

        _assertLoanManager({
            accruedInterest_:       0,
            accountedInterest_:     0,
            principalOut_:          1_000_000,
            assetsUnderManagement_: 1_000_000,
            issuanceRate_:          0.01e30,
            domainStart_:           5_000_000,
            domainEnd_:             5_010_000,
            unrealizedLosses_:      0
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_000,
            unrealizedLosses_: 0
        });

        vm.warp(START + 6_000);

        loanInfo = ILoanManagerLike(address(loanManager)).loans(loanManager.loanIdOf(address(loan)));

        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_000_000,
            paymentDueDate_:      5_010_000
        });

        _assertLoanManager({
            accruedInterest_:       60,
            accountedInterest_:     0,
            principalOut_:          1_000_000,
            assetsUnderManagement_: 1_000_060,
            issuanceRate_:          0.01e30,
            domainStart_:           5_000_000,
            domainEnd_:             5_010_000,
            unrealizedLosses_:      0
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_060,
            unrealizedLosses_: 0
        });

        vm.prank(PD);
        poolManager.triggerDefaultWarning(address(loan), block.timestamp);

        loanInfo = ILoanManagerLike(address(loanManager)).loans(loanManager.loanIdOf(address(loan)));

        // Loan info doesn't change, in case we want to revert the default warning.
        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_000_000,
            paymentDueDate_:      5_010_000  // TODO: Investigate updating this value on default warning.
        });

        _assertLoanManager({
            accruedInterest_:       0,          // Issuance rate is now 0, so no interest accrued.
            accountedInterest_:     60,         // Accrued interest up until trigger default warning is 60, which we have reflected as a loss.
            principalOut_:          1_000_000,  // Principal out should be unchanged, and will decrease in the liquidation flow.
            assetsUnderManagement_: 1_000_060,  // Assets under management is now only the principal out, since we unaccrued the interest. Since they still have a chance to pay, principal out is still included.
            issuanceRate_:          0,
            domainStart_:           5_006_000,
            domainEnd_:             5_006_000,
            unrealizedLosses_:      1_000_060
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_060,
            unrealizedLosses_: 1_000_060
        });

        // Make payment in grace period, returning the loan to healthy status.

        _makePayment({
            loanAddress:         address(loan),
            interestAmount:      100 + 30,  // Assume 3x late interest rate.
            principalAmount:     10_000,
            nextInterestPayment: 100,
            paymentTimestamp:    START + 7_000,  // Pay 1_000 into the grace period.
            nextPaymentDueDate:  START + 6_000 + 10_000
        });

        vm.prank(address(loan));
        loanManager.claim(10_000, 100 + 30, START + 6_000 + 10_000);

        // Next payment should be queued
        loanInfo = ILoanManagerLike(address(loanManager)).loans(loanManager.loanIdOf(address(loan)));

        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_006_000,
            paymentDueDate_:      5_016_000
        });

        _assertLoanManager({
            accruedInterest_:       0,         // We should have accrued 10 from next payment, but since we are making a late payment, this will be discretely updated.
            accountedInterest_:     10,        // 10 from discrete update missing from second payment that started accruing t - 1000. TDW payment interest has been decremented from accounted interest.
            principalOut_:          990_000,   // 1_000_000 - 10_000 principal paid
            assetsUnderManagement_: 990_010,
            issuanceRate_:          0.01e30,
            domainStart_:           5_007_000, // _advanceLoanAccounting accrues interest up until block.timestamp
            domainEnd_:             5_016_000,
            unrealizedLosses_:      0
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        10_130,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_140,
            unrealizedLosses_: 0
        });

   }

    // TODO: test where TDW is not the first payment

    /**
     *    @dev Loan 1
     *
     *    CONFIGURATION:
     *    Start date:        5_000_000
     *    Management fee:    0%
     *    Principal:         1_000_000
     *    Collateral:        300_000 (in collateral asset, worth 600_000 in funds asset)
     *    Cover:             50_000
     *    Incoming interest: 100 (100 per each 10_000 seconds)
     *    Issuance rate:     0.01e30 (100 / 10_000)
     *    Payment Interval:  10_000
     *
     *    DEFAULT WARNING:
     *    Next Payment due date: 6_000 (60% of the payment interval)
     *    Unrealized Losses:     1_000_000 + .6 * 100 (principal + accrued interest)
     *
     *    REMOVE DEFAULT WARNING:
     *    Remove warning timestamp: START + 8_000 (2_000 into the warning grace period)
     *    Expected accrued interest: 80 = 100 * 8 / 10
     *    Resulting total assets: 1_000_080
     */
    function test_liquidation_triggerDefaultWarning_removeDefaultWarning() external {
        uint256 coverAmount = 50_000;

        vm.startPrank(PD);
        MockERC20(fundsAsset).approve(address(poolManager), coverAmount);
        MockERC20(fundsAsset).mint(PD, coverAmount);

        poolManager.depositCover(coverAmount);
        vm.stopPrank();

        uint256 START = 5_000_000;
        vm.warp(START);

        uint256 principalRequested = 1_000_000;
        uint256 collateralRequired = principalRequested / COLLATERAL_PRICE * 6 / 10;  // 60% collateralized

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired, START + 10_000, 100);

        LoanManager.LoanInfo memory loanInfo = ILoanManagerLike(address(loanManager)).loans(loanManager.loanIdOf(address(loan)));

        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_000_000,
            paymentDueDate_:      5_010_000
        });

        _assertLoanManager({
            accruedInterest_:       0,
            accountedInterest_:     0,
            principalOut_:          1_000_000,
            assetsUnderManagement_: 1_000_000,
            issuanceRate_:          0.01e30,
            domainStart_:           5_000_000,
            domainEnd_:             5_010_000,
            unrealizedLosses_:      0
        });
        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_000,
            unrealizedLosses_: 0
        });

        vm.warp(START + 6_000);

        loanInfo = ILoanManagerLike(address(loanManager)).loans(loanManager.loanIdOf(address(loan)));

        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_000_000,
            paymentDueDate_:      5_010_000
        });

        _assertLoanManager({
            accruedInterest_:       60,
            accountedInterest_:     0,
            principalOut_:          1_000_000,
            assetsUnderManagement_: 1_000_060,
            issuanceRate_:          0.01e30,
            domainStart_:           5_000_000,
            domainEnd_:             5_010_000,
            unrealizedLosses_:      0
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_060,
            unrealizedLosses_: 0
        });

        vm.prank(PD);
        poolManager.triggerDefaultWarning(address(loan), block.timestamp);

        loanInfo = ILoanManagerLike(address(loanManager)).loans(loanManager.loanIdOf(address(loan)));

        // Loan info doesn't change, in case we want to revert the default warning.
        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_000_000,
            paymentDueDate_:      5_010_000
        });

        _assertLoanManager({
            accruedInterest_:       0,          // Issuance rate is now 0, so no interest accrued.
            accountedInterest_:     60,         // Accrued interest up until trigger default warning is 60, which we have reflected as a loss.
            principalOut_:          1_000_000,  // Principal out should be unchanged, and will decrease in the liquidation flow.
            assetsUnderManagement_: 1_000_060,  // Assets under management is now only the principal out, since we unaccrued the interest. Since they still have a chance to pay, principal out is still included.
            issuanceRate_:          0,
            domainStart_:           5_006_000,
            domainEnd_:             5_006_000,
            unrealizedLosses_:      1_000_060
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_060,
            unrealizedLosses_: 1_000_060
        });

        vm.warp(START + 8_000);

        vm.prank(PD);
        poolManager.removeDefaultWarning(address(loan));

        _assertLoanInfo({
            loanInfo_:            loanInfo,
            incomingNetInterest_: 100,
            refinanceInterest_:   0,
            issuanceRate_:        0.01e30,
            startDate_:           5_000_000,
            paymentDueDate_:      5_010_000
        });

        _assertLoanManager({
            accruedInterest_:       0,
            accountedInterest_:     80,
            principalOut_:          1_000_000,
            assetsUnderManagement_: 1_000_080,
            issuanceRate_:          0,
            domainStart_:           5_008_000,
            domainEnd_:             5_010_000,
            unrealizedLosses_:      0
        });

        _assertAssetBalances({
            asset_:              address(fundsAsset),
            loan_:               address(loan),
            loanBalance_:        0,
            poolBalance_:        0,
            poolManagerBalance_: 0
        });

        _assertPoolAndPoolManager({
            totalAssets_:      1_000_080,
            unrealizedLosses_: 0
        });

    }

}

contract LoanManagerTest is IntegrationTestBase {

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(PD);

        MockGlobals(globals).__setLatestPrice(address(fundsAsset),      FUNDS_PRICE);
        MockGlobals(globals).__setLatestPrice(address(collateralAsset), COLLATERAL_PRICE);
        MockGlobals(globals).setMaxCoverLiquidationPercent(address(poolManager), MockGlobals(globals).HUNDRED_PERCENT());

        vm.stopPrank();
    }

    // TODO: function test_unrealizedLosses() external { }

    function test_liquidation_shortfall() external {
        uint256 principalRequested = 1_000_000_000e18;
        uint256 collateralRequired = principalRequested / COLLATERAL_PRICE / 2;  // 50% collateralized

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired, block.timestamp + 30 days, 0);

        uint256 principalToCover = loan.principal();

        // NOTE: This is only possible because of MockLoan not using grace period logic.
        vm.prank(PD);
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

        vm.prank(PD);
        poolManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested / COLLATERAL_PRICE);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * COLLATERAL_PRICE);
    }

    function test_liquidation_equalToPrincipal() external {
        uint256 principalRequested = 1_000_000e18;
        uint256 collateralRequired = principalRequested / COLLATERAL_PRICE;

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired, block.timestamp + 30 days, 0);

        uint256 principalToCover = loan.principal();

        // NOTE: This is only possible because of MockLoan not using grace period logic.
        vm.prank(PD);
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

        vm.prank(PD);
        poolManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * COLLATERAL_PRICE);
    }

    function test_liquidation_greaterThanPrincipal() external {
        uint256 principalRequested = 1_000_000e18;
        uint256 collateralRequired = principalRequested;

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired, block.timestamp + 30 days, 0);

        uint256 principalToCover = loan.principal();

        // NOTE: This is only possible because of MockLoan not using grace period logic.
        vm.prank(PD);
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

        vm.prank(PD);
        poolManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested * COLLATERAL_PRICE);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * COLLATERAL_PRICE);
    }

}
