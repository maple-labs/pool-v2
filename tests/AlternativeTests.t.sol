// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { TestUtils } from "../modules/contract-test-utils/contracts/test.sol";

import { MockERC20 } from "../modules/revenue-distribution-token/modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MockInvestmentVehicle } from "./mocks/MockInvestmentVehicle.sol";

import { PoolV2, IPoolV2 }          from "../contracts/PoolV2.sol";
import { PoolV2Discrete }           from "../contracts/PoolV2Discrete.sol";
import { GenericInvestmentManager } from "../contracts/GenericInvestmentManager.sol";

/// @dev Demonstratig the different behaviours between PoolV2(Continuos) and PoolV2-Discrete
contract AlternativeTests is TestUtils {

    MockERC20      asset;
    PoolV2         continuosPool;
    PoolV2Discrete discretePool;

    function setUp() public virtual {
        asset         = new MockERC20("MockToken", "MT", 18);
        continuosPool = new PoolV2("Revenue Distribution Token", "RDT", address(this), address(asset), 1e30);
        discretePool  = new PoolV2Discrete("Revenue Distribution Token", "RDT", address(this), address(asset), 1e30);
    }

    /******************************/
    /*** Matching Functionality ***/
    /******************************/

    function test_poolV2Continuous_simpleOpenEndedInvestment() external {
        _test_simpleOpenEndedInvestment(IPoolV2(address(continuosPool)));
    }

    function test_poolV2Discrete_simpleOpenEndedInvestment() external {
        _test_simpleOpenEndedInvestment(IPoolV2(address(discretePool)));
    }

    function _test_simpleOpenEndedInvestment(IPoolV2 pool) internal {
        address staker  = address(333);
        uint256 deposit = 1000e18;

        // Do a deposit
        _deposit(address(pool), address(asset), deposit, staker);

        uint256 principal    = 1e18;
        uint256 interestRate = 0.12e18;  // 12% a year for easy calculations
        uint256 interval     = 90 days;

        GenericInvestmentManager investmentManager = new GenericInvestmentManager();
        MockInvestmentVehicle    investment        = new MockInvestmentVehicle(principal, interestRate, interval, address(pool), address(asset), address(investmentManager));
        
        pool.setInvestmentManager(address(investmentManager));


        // Fund an investment on address
        pool.fund(principal, address(investment));

        assertEq(pool.principalOut(),        principal);
        assertEq(pool.interestOut(),         0.029589041095890410e18);                       // Roughly 90 days of 12% over a 1e18 principal
        assertEq(pool.issuanceRate(),        3805175038.051750257201646090534979423868e30);
        assertEq(pool.vestingPeriodFinish(), block.timestamp + interval);                    // Period finished was updated again
        assertEq(pool.freeAssets(),          deposit);
        assertEq(pool.totalAssets(),         deposit);

        vm.warp(block.timestamp + interval);

        // Minting extra to cover interest
        asset.mint(address(this), 1e18);

        assertEq(pool.freeAssets(),  deposit);
        assertEq(pool.totalAssets(), deposit + 0.029589041095890409e18);

        pool.claim(address(investment));

        assertEq(pool.principalOut(),        principal);                         // No principal have been repaid;
        assertEq(pool.interestOut(),         0.029589041095890410e18);           // Still same value because we're using an "infinite" loan
        assertEq(pool.vestingPeriodFinish(), block.timestamp + interval);        // Period finished was updated again
        assertEq(pool.freeAssets(),          deposit + 0.029589041095890409e18);
        assertEq(pool.totalAssets(),         deposit + 0.029589041095890409e18);
    }

     function test_poolV2Continuous_simpleEndingInvestment() external {
        _test_simpleEndingInvestment(IPoolV2(address(continuosPool)));
    }

    function test_poolV2Discrete_simpleEndingInvestment() external {
        _test_simpleEndingInvestment(IPoolV2(address(discretePool)));
    }

    function _test_simpleEndingInvestment(IPoolV2 pool) internal {
        address staker  = address(333);
        uint256 deposit = 1000e18;

        // Do a deposit
        _deposit(address(pool), address(asset), deposit, staker);

        uint256 principal    = 1e18;
        uint256 interestRate = 0.12e18; // 12% a year for easy calculations
        uint256 interval     = 90 days;

        GenericInvestmentManager investmentManager = new GenericInvestmentManager();
        MockInvestmentVehicle    investment        = new MockInvestmentVehicle(principal, interestRate, interval, address(pool), address(asset), address(investmentManager));
        
        pool.setInvestmentManager(address(investmentManager));

        // Fund an investment on address
        pool.fund(principal, address(investment));

        assertEq(pool.principalOut(),        principal);
        assertEq(pool.interestOut(),         0.029589041095890410e18);                      // Roughly 90 days of 12% over a 1e18 principal
        assertEq(pool.issuanceRate(),        3805175038.051750257201646090534979423868e30);
        assertEq(pool.vestingPeriodFinish(), block.timestamp + interval);                   // Period finished was updated again

        assertEq(pool.freeAssets(),  deposit);
        assertEq(pool.totalAssets(), deposit);

        vm.warp(block.timestamp + interval);

        // Minting extra to cover interest
        asset.mint(address(investment), 1e18);

        pool.claim(address(investment));

        assertEq(pool.principalOut(),        principal);                                    // No principal have been repaid;
        assertEq(pool.interestOut(),         0.029589041095890410e18);                      // Still same value because we're using an "infinite" loan
        assertEq(pool.issuanceRate(),        3805175038.051750257201646090534979423868e30);
        assertEq(pool.vestingPeriodFinish(), block.timestamp + interval);                   // Period finished was updated again

        assertEq(pool.freeAssets(),  deposit + 0.029589041095890409e18);
        assertEq(pool.totalAssets(), deposit + 0.029589041095890409e18);

        // ----- Same as above end -------

        vm.warp(block.timestamp + interval);
        investment.setLastPayment(true);

        assertEq(pool.freeAssets(),  deposit + 0.029589041095890409e18);
        assertEq(pool.totalAssets(), deposit + (2 * 0.029589041095890409e18));

        pool.claim(address(investment));

        assertEq(pool.vestingPeriodFinish(), block.timestamp);
        assertEq(pool.interestOut(),         0);
        assertEq(pool.principalOut(),        0);
        assertEq(pool.issuanceRate(),        0);

        assertEq(pool.freeAssets(),  deposit + (2 * 0.029589041095890409e18));  // The pool gained 2 interest payments of "value"
        assertEq(pool.totalAssets(), deposit + (2 * 0.029589041095890409e18));  // The pool gained 2 interest payments of "value"
    }

    /*******************************/
    /*** Different Functionality ***/
    /******************************/

    function test_poolV2Continuos_earlyClaiming() external {
        IPoolV2 pool = IPoolV2(continuosPool);
        
        address staker  = address(333);
        uint256 deposit = 1000e18;

        // Do a deposit
        _deposit(address(pool), address(asset), deposit, staker);

        uint256 principal    = 1e18;
        uint256 interestRate = 0.12e18; // 12% a year for easy calculations
        uint256 interval     = 90 days;

        GenericInvestmentManager investmentManager = new GenericInvestmentManager();
        MockInvestmentVehicle    investment        = new MockInvestmentVehicle(principal, interestRate, interval, address(pool), address(asset), address(investmentManager));
        
        pool.setInvestmentManager(address(investmentManager));

        // Fund an investment on address
        pool.fund(principal, address(investment));

        vm.warp(block.timestamp + (interval / 2));

        // Minting extra to cover interest
        asset.mint(address(investment), 1e18);

        pool.claim(address(investment));

        // No change when extra interest comes early. The pool continues on the current schedule
        assertEq(pool.principalOut(),        principal);                                    // No principal have been repaid;
        assertEq(pool.interestOut(),         0.029589041095890410e18);                      // Still same value because we're using an "infinite" loan
        assertEq(pool.issuanceRate(),        3805175038.051750257201646090534979423868e30);
        assertEq(pool.vestingPeriodFinish(), block.timestamp + interval + 45 days);                   // Period finished was updated again

        assertEq(pool.freeAssets(),  deposit + 0.014794520547945204e18);
        assertEq(pool.totalAssets(), deposit + 0.014794520547945204e18);

        vm.warp(block.timestamp + interval + 45 days);
        investment.setLastPayment(true);

        assertEq(pool.freeAssets(),  deposit + 0.014794520547945204e18);
        assertEq(pool.totalAssets(), deposit + (2 * 0.029589041095890409e18));

        pool.claim(address(investment));

        assertEq(pool.vestingPeriodFinish(), block.timestamp);
        assertEq(pool.interestOut(),         0);
        assertEq(pool.principalOut(),        0);
        assertEq(pool.issuanceRate(),        0);

        assertEq(pool.freeAssets(),  deposit + (2 * 0.029589041095890409e18));  // The pool gained 2 interest payments of "value"
        assertEq(pool.totalAssets(), deposit + (2 * 0.029589041095890409e18));  // The pool gained 2 interest payments of "value"
    }

    function test_poolV2Discrete_earlyClaiming() external {
        IPoolV2 pool = IPoolV2(discretePool);
        
        address staker  = address(333);
        uint256 deposit = 1000e18;

        // Do a deposit
        _deposit(address(pool), address(asset), deposit, staker);

        uint256 principal    = 1e18;
        uint256 interestRate = 0.12e18; // 12% a year for easy calculations
        uint256 interval     = 90 days;

        GenericInvestmentManager investmentManager = new GenericInvestmentManager();
        MockInvestmentVehicle    investment        = new MockInvestmentVehicle(principal, interestRate, interval, address(pool), address(asset), address(investmentManager));
        
        pool.setInvestmentManager(address(investmentManager));

        // Fund an investment on address
        pool.fund(principal, address(investment));

        vm.warp(block.timestamp + (interval / 2));

        // Minting extra to cover interest
        asset.mint(address(investment), 1e18);

        pool.claim(address(investment));

        // In discrete pool, the free assets accounts for the early interest and the issuance rate is diminished for the next payment cycle
        assertEq(pool.principalOut(),        principal);                                    // No principal have been repaid;
        assertEq(pool.interestOut(),         0.029589041095890410e18);  
        assertEq(pool.issuanceRate(),        2536783358.701166838134430727023319615912e30);
        assertEq(pool.vestingPeriodFinish(), block.timestamp + interval + 45 days);                   // Period finished was updated again

        assertEq(pool.freeAssets(),  deposit + 0.029589041095890409e18);
        assertEq(pool.totalAssets(), deposit + 0.029589041095890409e18);

        vm.warp(block.timestamp + interval + 45 days);
        investment.setLastPayment(true);

        assertEq(pool.freeAssets(),  deposit + 0.029589041095890409e18);
        assertEq(pool.totalAssets(), deposit + (2 * 0.029589041095890409e18));

        pool.claim(address(investment));

        assertEq(pool.vestingPeriodFinish(), block.timestamp);
        assertEq(pool.interestOut(),         0);
        assertEq(pool.principalOut(),        0);
        assertEq(pool.issuanceRate(),        0);

        assertEq(pool.freeAssets(),  deposit + (2 * 0.029589041095890409e18));  // The pool gained 2 interest payments of "value"
        assertEq(pool.totalAssets(), deposit + (2 * 0.029589041095890409e18));  // The pool gained 2 interest payments of "value"
    }

    /************************/
    /*** Internal Helpers ***/
    /************************/

    function _deposit(address pool_, address asset_, uint256 amount_, address staker_) internal returns (uint256 shares_) {
        MockERC20(asset_).mint(staker_, amount_);

        vm.startPrank(staker_);
        MockERC20(asset_).approve(pool_, amount_);

        shares_ =  IPoolV2(pool_).deposit(amount_, staker_);
        vm.stopPrank();
    }

}
