// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { TestUtils } from "../modules/contract-test-utils/contracts/test.sol";

import { MockERC20 } from "../modules/revenue-distribution-token/modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolStaker } from "./accounts/PoolStaker.sol";

import { PoolV2 } from "../contracts/PoolV2.sol";

import { GenericInvestmentVehicle } from "../contracts/GenericInvestmentVehicle.sol";

contract PoolV2Tests is TestUtils { 
    
    MockERC20 asset;
    PoolV2    pool;

    function setUp() public virtual { 
        asset = new MockERC20("MockToken", "MT", 18);
        pool  = new PoolV2("Revenue Distribution Token", "RDT", address(this), address(asset), 1e30);
    }

    function test_poolV2_simpleDeposit() external {
        PoolStaker staker = new PoolStaker();

        uint256 deposit = 1000e18;

        asset.mint(address(staker), deposit);

        assertEq(pool.freeAssets(),   0);
        assertEq(pool.totalAssets(),  0);
        assertEq(pool.principalOut(), 0);
        assertEq(pool.interestOut(),  0);
        assertEq(pool.issuanceRate(), 0);

        assertEq(asset.balanceOf(address(staker)), deposit);
        assertEq(asset.balanceOf(address(pool)),   0);

        staker.erc20_approve(address(asset), address(pool), deposit);
        staker.rdToken_deposit(address(pool), deposit);

        assertEq(pool.freeAssets(),   deposit);
        assertEq(pool.totalAssets(),  deposit);
        assertEq(pool.principalOut(), 0);
        assertEq(pool.interestOut(),  0);
        assertEq(pool.issuanceRate(), 0);

        assertEq(asset.balanceOf(address(staker)), 0);
        assertEq(asset.balanceOf(address(pool)),   deposit);
    }

    function test_poolV2_simpleOpenEndedInvestment() external {
        PoolStaker staker = new PoolStaker();  

        uint256 deposit = 1000e18;
        
        // Do a deposit
        asset.mint(address(staker), deposit);

        assertEq(pool.freeAssets(),   0);
        assertEq(pool.totalAssets(),  0);
        assertEq(pool.principalOut(), 0);
        assertEq(pool.interestOut(),  0);
        assertEq(pool.issuanceRate(), 0);

        assertEq(asset.balanceOf(address(staker)), deposit);
        assertEq(asset.balanceOf(address(pool)),   0);

        staker.erc20_approve(address(asset), address(pool), deposit);
        staker.rdToken_deposit(address(pool), deposit);

        assertEq(pool.freeAssets(),   deposit);
        assertEq(pool.totalAssets(),  deposit);
        assertEq(pool.principalOut(), 0);
        assertEq(pool.interestOut(),  0);
        assertEq(pool.issuanceRate(), 0);

        assertEq(asset.balanceOf(address(staker)), 0);
        assertEq(asset.balanceOf(address(pool)),   deposit);

        uint256 principal    = 1e18;
        uint256 interestRate = 0.12e18;  // 12% a year for easy calculations
        uint256 interval     = 90 days; 

        GenericInvestmentVehicle investment = new GenericInvestmentVehicle(principal, interestRate, interval, address(pool), address(asset)); 

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

    function test_poolV2_simpleEndingInvestment() external {
        // ----- Same as above start -------
        PoolStaker staker = new PoolStaker();  

        uint256 deposit = 1000e18;
        
        // Do a deposit
        asset.mint(address(staker), deposit);

        assertEq(pool.freeAssets(),   0);
        assertEq(pool.totalAssets(),  0);
        assertEq(pool.principalOut(), 0);
        assertEq(pool.interestOut(),  0);
        assertEq(pool.issuanceRate(), 0);

        assertEq(asset.balanceOf(address(staker)), deposit);
        assertEq(asset.balanceOf(address(pool)),   0);

        staker.erc20_approve(address(asset), address(pool), deposit);
        staker.rdToken_deposit(address(pool), deposit);

        assertEq(pool.freeAssets(),   deposit);
        assertEq(pool.totalAssets(),  deposit);
        assertEq(pool.principalOut(), 0);
        assertEq(pool.interestOut(),  0);
        assertEq(pool.issuanceRate(), 0);

        assertEq(asset.balanceOf(address(staker)), 0);
        assertEq(asset.balanceOf(address(pool)),   deposit);

        uint256 principal    = 1e18;
        uint256 interestRate = 0.12e18; // 12% a year for easy calculations
        uint256 interval     = 90 days; 

        GenericInvestmentVehicle investment = new GenericInvestmentVehicle(principal, interestRate, interval, address(pool), address(asset)); 

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

}
