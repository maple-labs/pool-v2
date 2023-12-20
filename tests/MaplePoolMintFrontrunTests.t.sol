// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { Test }       from "../modules/forge-std/src/Test.sol";
import { stdError }   from "../modules/forge-std/src/StdError.sol";
import { MockERC20 }  from "../modules/erc20/contracts/test/mocks/MockERC20.sol";
import { IMaplePool } from "../contracts/interfaces/IMaplePool.sol";

import { MaplePool }                   from "../contracts/MaplePool.sol";
import { MaplePoolManager }            from "../contracts/MaplePoolManager.sol";
import { MaplePoolManagerFactory }     from "../contracts/proxy/MaplePoolManagerFactory.sol";
import { MaplePoolManagerInitializer } from "../contracts/proxy/MaplePoolManagerInitializer.sol";

import { MockGlobals, MockPoolManager, MockWithdrawalManager } from "./mocks/Mocks.sol";

import { GlobalsBootstrapper } from "./bootstrap/GlobalsBootstrapper.sol";

contract MaplePoolMintFrontrunTests is Test, GlobalsBootstrapper {

    address POOL_DELEGATE = makeAddr("POOL_DELEGATE");
    address USER1         = makeAddr("USER1");
    address USER2         = makeAddr("USER2");

    MockERC20               asset;
    MockWithdrawalManager   withdrawalManager;
    MaplePool               pool;
    MaplePoolManagerFactory factory;

    address poolManager;
    address implementation;
    address initializer;

    function setUp() public virtual {
        asset = new MockERC20("Asset", "A", 0);

        _deployAndBootstrapGlobals(address(asset), POOL_DELEGATE);

        factory = new MaplePoolManagerFactory(globals);

        implementation = address(new MaplePoolManager());
        initializer    = address(new MaplePoolManagerInitializer());

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        MockGlobals(globals).setValidPoolDeployer(address(this), true);
    }

    function _deploy(uint256 bootstrapMint_) internal {
        MockGlobals(globals).__setBootstrapMint(bootstrapMint_);

        bytes memory arguments = abi.encode(POOL_DELEGATE, address(asset), 0, "Pool", "POOL1");

        poolManager = address(MaplePoolManager(MaplePoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(POOL_DELEGATE)))));

        pool = MaplePool(MaplePoolManager(poolManager).pool());

        withdrawalManager = new MockWithdrawalManager();

        address mockPoolManager = address(new MockPoolManager());
        vm.etch(poolManager, mockPoolManager.code);

        MockPoolManager(poolManager).__setCanCall(true, "");

        MockPoolManager(poolManager).setWithdrawalManager(address(withdrawalManager));
    }

    function _deposit(address pool_, address poolManager_, address user_, uint256 assetAmount_) internal returns (uint256 shares_) {
        vm.startPrank(user_);
        asset.approve(pool_, assetAmount_);
        shares_ = IMaplePool(pool_).deposit(assetAmount_, user_);
        vm.stopPrank();

        MockPoolManager(poolManager_).__setTotalAssets(IMaplePool(pool_).totalAssets() + assetAmount_);
    }

    function test_depositFrontRun_zeroShares() external {
        _deploy(0);

        uint256 attackerDepositAmount  = 1;
        uint256 attackerTransferAmount = 1e8;
        uint256 victimDepositAmount    = 1e8;

        asset.mint(USER1, attackerDepositAmount + attackerTransferAmount);
        asset.mint(USER2, victimDepositAmount);

        _deposit(address(pool), address(poolManager), USER1, attackerDepositAmount);

        vm.prank(USER1);
        asset.transfer(address(pool), attackerTransferAmount);

        MockPoolManager(address(poolManager)).__setTotalAssets(pool.totalAssets() + attackerTransferAmount);

        vm.startPrank(USER2);
        asset.approve(address(pool), victimDepositAmount);

        vm.expectRevert("P:M:ZERO_SHARES");
        pool.deposit(victimDepositAmount, USER2);
    }

    function test_depositFrontRun_theft() external {
        _deploy(0);

        uint256 attackerDepositAmount  = 1;
        uint256 attackerTransferAmount = 1e8;
        uint256 victimDepositAmount    = 2e8;

        asset.mint(USER1, attackerDepositAmount + attackerTransferAmount);
        asset.mint(USER2, victimDepositAmount);

        _deposit(address(pool), address(poolManager), USER1, attackerDepositAmount);

        vm.prank(USER1);
        asset.transfer(address(pool), attackerTransferAmount);
        MockPoolManager(address(poolManager)).__setTotalAssets(pool.totalAssets() + attackerTransferAmount);

        _deposit(address(pool), address(poolManager), USER2, victimDepositAmount);

        assertEq(pool.balanceOfAssets(USER1),      1.5e8);
        assertEq(pool.balanceOfAssets(USER2),      1.5e8);
        assertEq(pool.balanceOfAssets(address(0)), 0);
    }

    function test_depositFrontRun_theftReverted() external {
        _deploy(0.00001e8);

        uint256 attackerDepositAmount  = 1;
        uint256 attackerTransferAmount = 1e8;
        uint256 victimDepositAmount    = 2e8;

        asset.mint(USER1, attackerDepositAmount + attackerTransferAmount);
        asset.mint(USER2, victimDepositAmount);

        vm.startPrank(USER1);
        asset.approve(address(pool), attackerDepositAmount);

        // Call reverts because `attackerDepositAmount` is less thank BOOTSTRAP_MINT causing underflow.
        vm.expectRevert(stdError.arithmeticError);
        pool.deposit(attackerDepositAmount, USER1);
    }

    function test_depositFrontRun_theftThwarted() external {
        _deploy(0.00001e8);

        uint256 attackerDepositAmount  = 0.00001e8 + 1;
        uint256 attackerTransferAmount = 1e8;
        uint256 victimDepositAmount    = 2e8;

        asset.mint(USER1, attackerDepositAmount + attackerTransferAmount);
        asset.mint(USER2, victimDepositAmount);

        _deposit(address(pool), address(poolManager), USER1, attackerDepositAmount);

        vm.prank(USER1);
        asset.transfer(address(pool), attackerTransferAmount);

        MockPoolManager(address(poolManager)).__setTotalAssets(pool.totalAssets() + attackerTransferAmount);

        _deposit(address(pool), address(poolManager), USER2, victimDepositAmount);

        assertEq(pool.balanceOfAssets(USER1),      0.00099933e8);  // Attacker losses the 1e8 transfer amount.
        assertEq(pool.balanceOfAssets(USER2),      1.99967356e8);
        assertEq(pool.balanceOfAssets(address(0)), 0.99933711e8);
    }

    function testFuzz_depositFrontRun_theftThwarted(uint256 attackerTransferAmount) external {
        _deploy(0.00001e8);

        uint256 attackerDepositAmount = 0.00001001e8;
        uint256 victimDepositAmount   = 2e8;

        attackerTransferAmount = bound(attackerTransferAmount, 1e8, 100e8);

        asset.mint(USER1, attackerDepositAmount + attackerTransferAmount);
        asset.mint(USER2, victimDepositAmount);

        _deposit(address(pool), address(poolManager), USER1, attackerDepositAmount);

        vm.prank(USER1);
        asset.transfer(address(pool), attackerTransferAmount);

        MockPoolManager(address(poolManager)).__setTotalAssets(pool.totalAssets() + attackerTransferAmount);

        _deposit(address(pool), address(poolManager), USER2, victimDepositAmount);

        assertTrue(pool.balanceOfAssets(USER1) < attackerTransferAmount);

        assertTrue(pool.balanceOfAssets(USER2) > (95 * victimDepositAmount) / 100);
    }

    function testFuzz_depositFrontRun_honestTenPercentHarm(uint256 user1DepositAmount) external {
        _deploy(0.00001e8);

        user1DepositAmount = bound(user1DepositAmount, 0.0001e8, 100e8);

        uint256 user2DepositAmount = 2e8;

        asset.mint(USER1, user1DepositAmount);
        asset.mint(USER2, user2DepositAmount);

        _deposit(address(pool), address(poolManager), USER1, user1DepositAmount);
        _deposit(address(pool), address(poolManager), USER2, user2DepositAmount);

        assertTrue(pool.balanceOfAssets(USER1) >= (90 * user1DepositAmount) / 100);

        assertApproxEqRel(pool.balanceOfAssets(USER2), 2e8, 1);
    }

    function testFuzz_depositFrontRun_honestOnePercentHarm(uint256 user1DepositAmount) external {
        _deploy(0.000001e8);

        user1DepositAmount = bound(user1DepositAmount, 0.0001e8, 100e8);

        uint256 user2DepositAmount = 2e8;

        asset.mint(USER1, user1DepositAmount);
        asset.mint(USER2, user2DepositAmount);

        _deposit(address(pool), address(poolManager), USER1, user1DepositAmount);
        _deposit(address(pool), address(poolManager), USER2, user2DepositAmount);

        assertTrue(pool.balanceOfAssets(USER1) >= (99 * user1DepositAmount) / 100);

        assertApproxEqRel(pool.balanceOfAssets(USER2), 2e8, 1);
    }

}
