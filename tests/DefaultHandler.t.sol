
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import {
    MockAuctioneer,
    MockGlobals,
    MockLiquidationStrategy,
    MockLoan,
    MockPoolCoverManager
} from "./mocks/Mocks.sol";

import { InvestmentManager } from "../contracts/interest/InvestmentManager.sol";
import { Pool }              from "../contracts/Pool.sol";
import { PoolManager }       from "../contracts/PoolManager.sol";

contract DefaultHandlerTest is TestUtils {

    address constant LP       = address(2);
    address constant BORROWER = address(3);

    address implementation;
    address initializer;

    uint256 collateralPrice;

    InvestmentManager    investmentManager;
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

        investmentManager = new InvestmentManager(address(pool), address(poolManager), address(poolCoverManager));

        poolManager.setInvestmentManager(address(investmentManager), true);
        poolManager.setInvestmentManager(address(this),              true); // Hacky way to directly call increase/decrease unrealizedLosses
        poolManager.setPoolCoverManager(address(poolCoverManager));
    }

    function test_unrealizedLosses() external {

    }

    // TODO: Add auctioneer to this repo

    function test_liquidation_shortfall() external {
        uint256 principalRequested = 1_000_000_000e18;
        uint256 collateralRequired = principalRequested / collateralPrice / 2;  // 50% collateralized

        _mintAndDeposit(principalRequested);

        MockLoan loan = _createFundAndDrawdownLoan(principalRequested, collateralRequired);

        uint256 principalToCover = loan.principal();

        // NOTE: This is only possible because of MockLoan not using grace period logic.
        poolManager.triggerCollateralLiquidation(address(loan), address(auctioneer));

        (uint256 principal, address liquidator) = investmentManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);
        assertEq(auctioneer.getExpectedAmount(collateralRequired), collateralRequired * collateralPrice);

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);

        // Perform Liquidation -- InvestmentManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(auctioneer));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        0);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      collateralRequired * collateralPrice);

        investmentManager.finishCollateralLiquidation(address(loan));

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

        (uint256 principal, address liquidator) = investmentManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);
        assertEq(auctioneer.getExpectedAmount(collateralRequired), collateralRequired * collateralPrice);

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);

        // Perform Liquidation -- InvestmentManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(auctioneer));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        0);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      collateralRequired * collateralPrice);

        investmentManager.finishCollateralLiquidation(address(loan));

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

        (uint256 principal, address liquidator) = investmentManager.liquidationInfo(address(loan));

        assertEq(principal, principalToCover);
        assertEq(auctioneer.getExpectedAmount(collateralRequired), collateralRequired * collateralPrice);

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        collateralRequired);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);

        // Perform Liquidation -- InvestmentManager acts as Auctioneer
        MockLiquidationStrategy mockLiquidationStrategy = new MockLiquidationStrategy(address(auctioneer));

        mockLiquidationStrategy.flashBorrowLiquidation(liquidator, collateralRequired, address(collateralAsset), address(fundsAsset));

        assertEq(collateralAsset.balanceOf(address(loan)),              0);
        assertEq(collateralAsset.balanceOf(address(investmentManager)), 0);
        assertEq(collateralAsset.balanceOf(address(liquidator)),        0);
        assertEq(fundsAsset.balanceOf(address(loan)),                   0);
        assertEq(fundsAsset.balanceOf(address(liquidator)),             0);
        assertEq(fundsAsset.balanceOf(address(investmentManager)),      collateralRequired * collateralPrice);

        investmentManager.finishCollateralLiquidation(address(loan));

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

        poolManager.fund(principalRequested_, address(loan), address(investmentManager));

        collateralAsset.mint(address(loan), collateralRequired_);

        loan.drawdownFunds(principalRequested_, address(this));
    }

}
