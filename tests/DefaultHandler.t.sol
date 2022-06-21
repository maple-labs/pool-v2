
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { TestUtils } from "../modules/contract-test-utils/contracts/test.sol";

import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MockLiquidationStrategy, MockLoan, MockPoolCoverManager } from "./mocks/Mocks.sol";

import { PB_ST_05 as InvestmentManager } from "../contracts/InvestmentManager.sol";
import { Pool }                          from "../contracts/Pool.sol";
import { PoolManager }                   from "../contracts/PoolManager.sol";

contract DefaultHandlerTest is TestUtils {

    address constant LP       = address(2);
    address constant BORROWER = address(3);

    InvestmentManager investmentManager;
    MockERC20         fundsAsset;
    MockERC20         collateralAsset;
    Pool              pool;
    PoolManager       poolManager;

    function setUp() public virtual {
        collateralAsset   = new MockERC20("MockCollateral", "MC", 18);
        fundsAsset        = new MockERC20("MockToken", "MT", 18);
        poolManager       = new PoolManager(address(this), 1e30);
        pool              = new Pool("Pool", "MPL-LP", address(poolManager), address(fundsAsset));
        investmentManager = new InvestmentManager(address(pool));

        poolManager.setInvestmentManager(address(investmentManager), true);
        poolManager.setInvestmentManager(address(this),              true); // Hacky way to directly call increase/decrease unrealizedLosses
        poolManager.setPoolCoverManager(address(new MockPoolCoverManager()));
    }

    function test_unrealizedLosses() external {

    }

    function test_liquidation_shortfall() external {
        uint256 principalRequested = 1_000_000_000e18;
        uint256 collateralRequired = principalRequested / 1e9;

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired);

        uint256 principalToCover = loan.principal();

        poolManager.triggerCollateralLiquidation(address(loan));

        (uint256 principal, address liquidator) = investmentManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);
        assertEq(investmentManager.getExpectedAmount(collateralRequired), collateralRequired * 1e6);

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);

        // Perform Liquidation -- InvestmentManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(investmentManager));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        0);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      collateralRequired * 1e6);

        investmentManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * 1e6);
    }

    function test_liquidation_equalToPrincipal() external {
        uint256 principalRequested = 1_000_000e18;
        uint256 collateralRequired = principalRequested / 1e6;

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired);

        uint256 principalToCover = loan.principal();

        investmentManager.triggerCollateralLiquidation(address(loan));

        (uint256 principal, address liquidator) = investmentManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);
        assertEq(investmentManager.getExpectedAmount(collateralRequired), collateralRequired * 1e6);

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);

        // Perform Liquidation -- InvestmentManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(investmentManager));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        0);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      collateralRequired * 1e6);

        investmentManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * 1e6);
    }

    function test_liquidation_greaterThanPrincipal() external {
        uint256 principalRequested = 1_000_000e18;
        uint256 collateralRequired = principalRequested / 1e3;

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired);

        uint256 principalToCover = loan.principal();

        investmentManager.triggerCollateralLiquidation(address(loan));

        (uint256 principal, address liquidator) = investmentManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);
        assertEq(investmentManager.getExpectedAmount(collateralRequired), collateralRequired * 1e6);

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);

        // Perform Liquidation -- InvestmentManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(investmentManager));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        0);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      collateralRequired * 1e6);

        investmentManager.finishCollateralLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired * 1e6);
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

        poolManager.fund(principalRequested_, address(loan), address(investmentManager));

        collateralAsset.mint(address(loan), collateralRequired_);

        loan.drawdownFunds(principalRequested_, address(this));
    }

}
