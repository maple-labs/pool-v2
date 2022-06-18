
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { TestUtils } from "../modules/contract-test-utils/contracts/test.sol";

import { MockERC20 } from "../modules/revenue-distribution-token/modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MockLiquidationStrategy, MockLoan } from "./mocks/Mocks.sol";

import { PoolV2 }   from "../contracts/PoolV2.sol";
import { TB_LT_01 } from "../contracts/TB_LT_01.sol";

contract DefaultHandlerTest is TestUtils {

    address constant LP       = address(2);
    address constant BORROWER = address(3);

    MockERC20 fundsAsset;
    MockERC20 collateralAsset;
    TB_LT_01  investmentManager;
    PoolV2    pool;

    function setUp() public virtual {
        collateralAsset   = new MockERC20("MockCollateral", "MC", 18);
        fundsAsset        = new MockERC20("MockToken", "MT", 18);
        pool              = new PoolV2("Revenue Distribution Token", "RDT", address(this), address(fundsAsset), 1e30);
        investmentManager = new TB_LT_01(address(pool));

        pool.setInvestmentManager(address(investmentManager), true);
        pool.setInvestmentManager(address(this), true); // Hacky way to directly call increase/decrease unrealizedLosses
    }

    function test_unrealizedLosses() external {
        
    }

    function test_liquidation_shortfall() external {
        uint256 principalRequested_ = 1_000_000_000 ether;
        uint256 collateralRequired_ = principalRequested_ / 1e9;

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested_, collateralRequired_);

        uint256 principalToCover = loan.principal();
        
        investmentManager.triggerDefault(address(loan)); 

        (uint256 principal, address liquidator) = investmentManager.details(address(loan));
        
        assertEq(principal, principalToCover);
        assertEq(investmentManager.getExpectedAmount(collateralRequired_), collateralRequired_ * 1e6);

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        collateralRequired_);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);

        // Perform Liquidation -- InvestmentManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(investmentManager));
        
        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired_, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        0);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      collateralRequired_ * 1e6);

        investmentManager.finishLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired_ * 1e6);
    }

    function test_liquidation_equalToPrincipal() external {
        uint256 principalRequested_ = 1_000_000 ether;
        uint256 collateralRequired_ = principalRequested_ / 1e6;

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested_, collateralRequired_);

        uint256 principalToCover = loan.principal();

        investmentManager.triggerDefault(address(loan)); 

        (uint256 principal, address liquidator) = investmentManager.details(address(loan));
        
        assertEq(principal, principalToCover);
        assertEq(investmentManager.getExpectedAmount(collateralRequired_), collateralRequired_ * 1e6);

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        collateralRequired_);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);

        // Perform Liquidation -- InvestmentManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(investmentManager));
        
        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired_, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        0);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      collateralRequired_ * 1e6);

        investmentManager.finishLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), principalRequested_);
        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired_ * 1e6);
    }

    function test_liquidation_greaterThanPrincipal() external {
        uint256 principalRequested_ = 1_000_000 ether;
        uint256 collateralRequired_ = principalRequested_ / 1e3;

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested_, collateralRequired_);

        uint256 principalToCover = loan.principal();

        investmentManager.triggerDefault(address(loan)); 

        (uint256 principal, address liquidator) = investmentManager.details(address(loan));
        
        assertEq(principal, principalToCover);
        assertEq(investmentManager.getExpectedAmount(collateralRequired_), collateralRequired_ * 1e6);

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        collateralRequired_);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);

        // Perform Liquidation -- InvestmentManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(investmentManager));
        
        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired_, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        0);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      collateralRequired_ * 1e6);

        investmentManager.finishLiquidation(address(loan));

        assertEq(fundsAsset.balanceOf(address(pool)), collateralRequired_ * 1e6);
    }

    /************************/
    /*** Internal Helpers ***/
    /************************/

    function _createFundAndDrawdownLoan(uint256 principalRequested_, uint256 collateralRequired_) internal returns(MockLoan loan){
        loan = new MockLoan(address(fundsAsset), address(collateralAsset), principalRequested_, collateralRequired_);
        
        collateralAsset.mint(address(loan), collateralRequired_);
    }
    
}
