// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { TestUtils } from "../modules/contract-test-utils/contracts/test.sol";

import { MockERC20 }            from "../modules/revenue-distribution-token/modules/erc20/contracts/test/mocks/MockERC20.sol";
import { MockPoolCoverManager }  from "./mocks/MockPoolCoverManager.sol";
import { MockInvestmentVehicle } from "./mocks/MockInvestmentVehicle.sol";

import { PoolStaker } from "./accounts/PoolStaker.sol";

import { PoolV2 } from "../contracts/PoolV2.sol";

import { GenericInvestmentManager } from "../contracts/GenericInvestmentManager.sol";


contract PoolV2Tests is TestUtils {

    MockERC20            asset;
    MockPoolCoverManager poolCoverManager;

    PoolV2 pool;

    uint256 internal immutable VESTING_PERIOD = 30 days;

    function setUp() public virtual {
        asset            = new MockERC20("MockToken", "MT", 18);
        poolCoverManager = new MockPoolCoverManager(asset);
        pool             = new PoolV2("MaplePool V2", "MPv2", address(this), address(asset), 1e30);
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

    function test_poolV2_simpleOpenEndedInvestment_withPoolCoverManager() external {
        PoolStaker staker = new PoolStaker();

        uint256 deposit = 1000e18;
        asset.mint(address(staker), deposit);

        staker.erc20_approve(address(asset), address(pool), deposit);
        staker.rdToken_deposit(address(pool), deposit);

        // Define the terms of the investment.
        uint256 principal    = 1e18;
        uint256 interestRate = 0.12e18;  // 12% a year for easy calculations
        uint256 interval     = 90 days;

        uint256 interest     = 0.029589041095890410e18;                      // Roughly 90 days of 12% over a 1e18 principal.
        uint256 issuanceRate = 3805175038.051750257201646090534979423868e30; // Expected issuance rate based on the interest.

        GenericInvestmentManager investmentManager = new GenericInvestmentManager();
        MockInvestmentVehicle    investment        = new MockInvestmentVehicle(principal, interestRate, interval, address(pool), address(asset), address(investmentManager));

        pool.setInvestmentManager(address(investmentManager));

        assertEq(pool.freeAssets(),          deposit);
        assertEq(pool.totalAssets(),         deposit);
        assertEq(pool.principalOut(),        0);
        assertEq(pool.interestOut(),         0);
        assertEq(pool.issuanceRate(),        0);
        assertEq(pool.vestingPeriodFinish(), 0);

        assertEq(asset.balanceOf(address(staker)),           0);
        assertEq(asset.balanceOf(address(pool)),             deposit);
        assertEq(asset.balanceOf(address(poolCoverManager)), 0);

        // Fund the investment.
        pool.fund(principal, address(investment));

        assertEq(pool.freeAssets(),          deposit);
        assertEq(pool.totalAssets(),         deposit);
        assertEq(pool.principalOut(),        principal);
        assertEq(pool.interestOut(),         interest);
        assertEq(pool.issuanceRate(),        issuanceRate);
        assertEq(pool.vestingPeriodFinish(), block.timestamp + interval);

        assertEq(asset.balanceOf(address(staker)),           0);
        assertEq(asset.balanceOf(address(pool)),             deposit - principal);
        assertEq(asset.balanceOf(address(poolCoverManager)), 0);

        vm.warp(block.timestamp + interval);

        assertEq(pool.freeAssets(),  deposit);
        assertEq(pool.totalAssets(), deposit + interest - 1);

        // Configure the pool cover manager.
        pool.setPoolCoverManager(address(poolCoverManager));

        // Claim interest and automatically distribute a portion of it to the pool cover manager.
        pool.claim(address(investment));

        assertEq(pool.freeAssets(),          deposit + interest - 1);
        assertEq(pool.totalAssets(),         deposit + interest - 1);
        assertEq(pool.principalOut(),        principal);
        assertEq(pool.interestOut(),         interest);
        assertEq(pool.issuanceRate(),        issuanceRate);
        assertEq(pool.vestingPeriodFinish(), block.timestamp + interval);

        // The pool cover portion is 20% of the interest.
        uint256 coverPortion = 0.2e18 * interest / 1e18;

        assertEq(asset.balanceOf(address(staker)),           0);
        assertEq(asset.balanceOf(address(pool)),             deposit - principal - coverPortion + interest);
        assertEq(asset.balanceOf(address(poolCoverManager)), 0);  // Still zero because all assets were immediately distributed.
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

    function test_poolV2_setWithdrawalManager() external {
        address withdrawalManager = address(11);

        pool.setWithdrawalManager(withdrawalManager);

        assertEq(pool.withdrawalManager(), withdrawalManager);
    }

    function test_poolV2_setPoolCoverManager() external {
        assertEq(pool.poolCoverManager(), address(0));

        pool.setPoolCoverManager(address(80085));

        assertEq(pool.poolCoverManager(), address(80085));
    }

    function test_poolV2_withdrawal_acl() external {
        address withdrawalManager = address(11);
        address staker            = address(22);

        // Set withdrawal manager
        pool.setWithdrawalManager(withdrawalManager);

        // Do a deposit
        uint256 deposit = 1000e18;
        asset.mint(staker, deposit);

        vm.startPrank(staker);
        asset.approve(address(pool), deposit);
        uint256 shares = pool.deposit(deposit, address(staker));

        vm.expectRevert("P:W:NOT_WM");
        pool.withdraw(shares, address(staker), address(staker));

        // Transfer to withdrawal manager
        pool.approve(address(withdrawalManager), shares);

        vm.stopPrank();

        // Withdraw through WM
        vm.prank(withdrawalManager);
        pool.withdraw(shares, address(this), address(staker));
    }

    function test_poolV2_redeem_acl() external {
        address withdrawalManager = address(11);
        address staker            = address(22);

        // Set withdrawal manager
        pool.setWithdrawalManager(withdrawalManager);

        // Do a deposit
        uint256 deposit = 1000e18;
        asset.mint(staker, deposit);

        vm.startPrank(staker);
        asset.approve(address(pool), deposit);
        uint256 shares = pool.deposit(deposit, address(staker));

        uint256 redeemAmount = pool.previewRedeem(shares);

        vm.expectRevert("P:R:NOT_WM");
        pool.redeem(shares, address(staker), address(staker));

        // Transfer to withdrawal manager
        pool.approve(address(withdrawalManager), redeemAmount);

        vm.stopPrank();

        // Redeem through WM
        vm.prank(withdrawalManager);
        pool.redeem(redeemAmount, address(this), address(staker));
    }

}

contract PoolV2FundTests is TestUtils {

    MockERC20            asset;
    MockPoolCoverManager poolCoverManager;

    PoolV2 pool;

    uint256 START;

    uint256 internal immutable VESTING_PERIOD = 30 days;

    function setUp() public virtual {
        asset            = new MockERC20("MockToken", "MT", 18);
        poolCoverManager = new MockPoolCoverManager(asset);
        pool             = new PoolV2("MaplePool V2", "MPv2", address(this), address(asset), 1e30);

        START = block.timestamp;
    }

    function test_poolV2_fund() external {
        PoolStaker staker = new PoolStaker();

        uint256 deposit = 1000e18;

        // Do a deposit
        asset.mint(address(staker), deposit);
        staker.erc20_approve(address(asset), address(pool), deposit);
        staker.rdToken_deposit(address(pool), deposit);

        vm.warp(START + 1 days);  // Warp so lastUpdated is different

        uint256 interestRate       = 0.12e18;
        uint256 paymentInterval    = 90 days; 
        uint256 nextPaymentDueDate = block.timestamp + paymentInterval;
        uint256 principal          = 1e18;
        uint256 principalRequested = 1e18;

        GenericInvestmentManager investmentManager = new GenericInvestmentManager();
        MockInvestmentVehicle    investment        = new MockInvestmentVehicle(principalRequested, interestRate, paymentInterval, address(pool), address(asset), address(investmentManager));

        pool.setInvestmentManager(address(investmentManager));

        assertEq(pool.principalOut(),        0);
        assertEq(pool.interestOut(),         0);
        assertEq(pool.freeAssets(),          deposit);
        assertEq(pool.lastUpdated(),         START);
        assertEq(pool.vestingPeriodFinish(), 0);
        assertEq(pool.issuanceRate(),        0);
        assertEq(pool.totalAssets(),         deposit);

        assertEq(asset.balanceOf(address(pool)),       1000e18);
        assertEq(asset.balanceOf(address(investment)), 0);

        // Fund an investment on address
        pool.fund(principal, address(investment));

        assertEq(pool.principalOut(),        principal);
        assertEq(pool.interestOut(),         0.029589041095890410e18);
        assertEq(pool.freeAssets(),          deposit);
        assertEq(pool.lastUpdated(),         START + 1 days);
        assertEq(pool.vestingPeriodFinish(), nextPaymentDueDate);
        assertEq(pool.issuanceRate(),        3805175038.051750257201646090534979423868e30);
        assertEq(pool.totalAssets(),         deposit);

        assertEq(asset.balanceOf(address(pool)),       deposit - principalRequested);
        assertEq(asset.balanceOf(address(investment)), principalRequested);
    }

}

contract PoolV2ClaimTests is TestUtils {

    MockERC20 asset;
    PoolV2    pool;

    uint256 START;

    function setUp() public virtual {
        asset = new MockERC20("MockToken", "MT", 18);
        pool             = new PoolV2("MaplePool V2", "MPv2", address(this), address(asset), 1e30);

        START = block.timestamp;
    }

    function test_poolV2_claim() external {
        PoolStaker staker = new PoolStaker();

        uint256 deposit = 1000e18;

        // Do a deposit
        asset.mint(address(staker), deposit);
        staker.erc20_approve(address(asset), address(pool), deposit);
        staker.rdToken_deposit(address(pool), deposit);

        vm.warp(START + 1 days);  // Warp so lastUpdated is different

        uint256 interestRate       = 0.12e18;
        uint256 paymentInterval    = 90 days; 
        uint256 nextPaymentDueDate = block.timestamp + paymentInterval;
        uint256 principal          = 1e18;
        uint256 principalRequested = 1e18;

        GenericInvestmentManager investmentManager = new GenericInvestmentManager();
        MockInvestmentVehicle    investment        = new MockInvestmentVehicle(principalRequested, interestRate, paymentInterval, address(pool), address(asset), address(investmentManager));

        pool.setInvestmentManager(address(investmentManager));

        // Fund an investment on address
        pool.fund(principal, address(investment));

        asset.burn(address(investment), principal);  // Burn principal to simulate drawdown
        asset.mint(address(investment), 0.029589041095890410e18);   // Mint interest into investment to simulate payment

        assertEq(pool.principalOut(),        principal);
        assertEq(pool.interestOut(),         0.029589041095890410e18);
        assertEq(pool.freeAssets(),          deposit);
        assertEq(pool.lastUpdated(),         START + 1 days);
        assertEq(pool.vestingPeriodFinish(), nextPaymentDueDate);
        assertEq(pool.issuanceRate(),        3805175038.051750257201646090534979423868e30);
        assertEq(pool.totalAssets(),         deposit);

        assertEq(asset.balanceOf(address(pool)),       deposit - principalRequested);
        assertEq(asset.balanceOf(address(investment)), 0.029589041095890410e18);

        vm.warp(nextPaymentDueDate);

        assertEq(pool.totalAssets(), deposit + 0.029589041095890409e18);  // Updated based on warp

        pool.claim(address(investment));

        assertEq(pool.principalOut(),        principal);
        assertEq(pool.interestOut(),         0.029589041095890410e18);
        assertEq(pool.freeAssets(),          deposit + 0.029589041095890409e18);
        assertEq(pool.lastUpdated(),         block.timestamp);
        assertEq(pool.vestingPeriodFinish(), START + 1 days + paymentInterval * 2);
        assertEq(pool.issuanceRate(),        3805175038.051750257201646090534979423868e30);  // Same issuance rate since funds were claimed exactly on time and same interest and paymentInterval
        assertEq(pool.totalAssets(),         deposit + 0.029589041095890409e18);

        // assertEq(asset.balanceOf(address(pool)),       deposit - principalRequested + 0.029589041095890409e18);
        assertEq(asset.balanceOf(address(investment)), 0);
    }

}
