// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { Test }       from "../modules/forge-std/src/Test.sol";
import { stdError }   from "../modules/forge-std/src/StdError.sol";
import { MockERC20 }  from "../modules/erc20/contracts/test/mocks/MockERC20.sol";
import { IMaplePool } from "../contracts/interfaces/IMaplePool.sol";

import { MaplePool }                   from "../contracts/MaplePool.sol";
import { MaplePoolManager }            from "../contracts/MaplePoolManager.sol";
import { MaplePoolManagerFactory }     from "../contracts/proxy/MaplePoolManagerFactory.sol";
import { MaplePoolManagerInitializer } from "../contracts/proxy/MaplePoolManagerInitializer.sol";

import {
    MockGlobals,
    MockReenteringERC20,
    MockRevertingERC20,
    MockPoolManager,
    MockWithdrawalManager
} from "./mocks/Mocks.sol";

import { TestBase } from "./utils/TestBase.sol";

contract PoolTestBase is TestBase {

    address POOL_DELEGATE = makeAddr("POOL_DELEGATE");

    MockReenteringERC20     asset;
    MockWithdrawalManager   withdrawalManager;
    MaplePool               pool;
    MaplePoolManagerFactory factory;

    address poolManager;
    address implementation;
    address initializer;

    address user = makeAddr("user");

    function setUp() public virtual {
        asset = new MockReenteringERC20();

        _deployAndBootstrapGlobals(address(asset), POOL_DELEGATE);

        factory = new MaplePoolManagerFactory(address(globals));

        implementation = deploy("MaplePoolManager");
        initializer    = deploy("MaplePoolManagerInitializer");

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        string memory poolName_   = "MaplePool";
        string memory poolSymbol_ = "POOL1";

        MockGlobals(globals).setValidPoolDeployer(address(this), true);

        bytes memory arguments = abi.encode(POOL_DELEGATE, address(asset), 0, poolName_, poolSymbol_);

        poolManager = address(MaplePoolManager(MaplePoolManagerFactory(factory).createInstance(
            arguments,
            keccak256(abi.encode(POOL_DELEGATE)))
        ));

        pool = MaplePool(MaplePoolManager(poolManager).pool());

        withdrawalManager = new MockWithdrawalManager();

        address mockPoolManager = address(new MockPoolManager());
        vm.etch(poolManager, mockPoolManager.code);

        MockPoolManager(poolManager).__setCanCall(true, "");

        MockPoolManager(poolManager).setWithdrawalManager(address(withdrawalManager));
    }

    // Returns an ERC-2612 `permit` digest for the `owner` to sign
    function _getDigest(address owner_, address spender_, uint256 value_, uint256 nonce_, uint256 deadline_)
        internal view returns (bytes32 digest_)
    {
        return keccak256(
            abi.encodePacked(
                '\x19\x01',
                asset.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(asset.PERMIT_TYPEHASH(), owner_, spender_, value_, nonce_, deadline_))
            )
        );
    }

    // Returns a valid `permit` signature signed by this contract's `owner` address
    function _getValidPermitSignature(address owner_, address spender_, uint256 value_, uint256 nonce_, uint256 deadline_, uint256 ownerSk_)
        internal view returns (uint8 v_, bytes32 r_, bytes32 s_)
    {
        return vm.sign(ownerSk_, _getDigest(owner_, spender_, value_, nonce_, deadline_));
    }

    function _deposit(address pool_, address poolManager_, address user_, uint256 assetAmount_) internal returns (uint256 shares_) {
        address asset_ = IMaplePool(pool_).asset();
        MockERC20(asset_).mint(user_, assetAmount_);

        vm.startPrank(user_);
        MockERC20(asset_).approve(pool_, assetAmount_);
        shares_ = IMaplePool(pool_).deposit(assetAmount_, user_);
        vm.stopPrank();

        MockPoolManager(poolManager_).__setTotalAssets(assetAmount_);
    }

    function _setupPool(uint256 totalSupply_, uint256 totalAssets_, uint256 unrealizedLosses_) internal {
        // Mint the total amount of shares at a one to one exchange ratio.
        if (totalSupply_ > 0) {
            asset.mint(address(this), totalSupply_);
            asset.approve(address(pool), totalSupply_);
            pool.deposit(totalSupply_, address(this));
        }

        MockPoolManager(address(poolManager)).__setTotalAssets(totalAssets_);
        MockPoolManager(address(poolManager)).__setUnrealizedLosses(unrealizedLosses_);
    }

}

contract ConstructorTests is PoolTestBase {

    function setUp() public override {}

    function test_constructor_zeroManager() public {
        address asset = address(new MockERC20("Asset", "AT", 18));

        vm.expectRevert("P:C:ZERO_MANAGER");
        new MaplePool(address(0), asset, address(0), 0, 0, "MaplePool", "POOL1");

        new MaplePool(makeAddr("1"), asset, address(0), 0, 0, "MaplePool", "POOL1");
    }

    function test_constructor_invalidDecimals() public {
        address asset = address(new MockRevertingERC20("Asset", "AT", 18));
        MockRevertingERC20(asset).__setIsRevertingDecimals(true);

        address poolDelegate = makeAddr("poolDelegate");

        vm.expectRevert("ERC20:D:REVERT");
        new MaplePool(poolDelegate, asset, address(0), 0, 0, "MaplePool", "POOL1");

        asset = address(new MockERC20("Asset", "AT", 18));
        new MaplePool(poolDelegate, asset, address(0), 0, 0, "MaplePool", "POOL1");
    }

    function test_constructor_invalidApproval() public {
        address asset = address(new MockRevertingERC20("Asset", "AT", 18));
        MockRevertingERC20(asset).__setIsRevertingApprove(true);

        address poolDelegate = makeAddr("poolDelegate");

        vm.expectRevert("P:C:FAILED_APPROVE");
        new MaplePool(poolDelegate, asset, address(0), 0, 0, "MaplePool", "POOL1");

        asset = address(new MockERC20("Asset", "AT", 18));
        new MaplePool(poolDelegate, asset, address(0), 0, 0, "Pool", "POOL1");
    }

}

contract DepositTests is PoolTestBase {

    uint256 DEPOSIT_AMOUNT = 1e18;

    function test_deposit_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        uint256 depositAmount_ = 1_000e6;

        address asset_ = IMaplePool(pool).asset();
        MockERC20(asset_).mint(user, depositAmount_);

        vm.startPrank(user);
        MockERC20(asset_).approve(address(pool), depositAmount_);
        vm.expectRevert("TEST_MESSAGE");
        IMaplePool(pool).deposit(depositAmount_, user);
    }

    function test_deposit_zeroReceiver() public {
        asset.mint(address(this),    DEPOSIT_AMOUNT);
        asset.approve(address(pool), DEPOSIT_AMOUNT);

        vm.expectRevert("P:M:ZERO_RECEIVER");
        pool.deposit(DEPOSIT_AMOUNT, address(0));
    }

    function test_deposit_zeroShares() public {
        asset.mint(address(this),    DEPOSIT_AMOUNT);
        asset.approve(address(pool), DEPOSIT_AMOUNT);

        vm.expectRevert("P:M:ZERO_SHARES");
        pool.deposit(0, address(this));
    }

    function testFuzz_deposit_badApprove(uint256 depositAmount_) public {
        depositAmount_ = bound(depositAmount_, 1, 1e29);

        asset.mint(address(this),    depositAmount_);
        asset.approve(address(pool), depositAmount_ - 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.deposit(depositAmount_, address(this));
    }

    function testFuzz_deposit_insufficientBalance(uint256 depositAmount_) public {
        depositAmount_ = bound(depositAmount_, 1, 1e29);

        asset.mint(address(this),    depositAmount_);
        asset.approve(address(pool), depositAmount_ + 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.deposit(depositAmount_ + 1, address(this));
    }

    function test_deposit_reentrancy() public {
        asset.mint(address(this),    1);
        asset.approve(address(pool), 1);
        asset.setReentrancy(address(pool));

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.deposit(1, address(this));
    }

}

contract DepositWithPermitTests is PoolTestBase {

    address STAKER;
    address NOT_STAKER;

    uint256 STAKER_SK     = 1;
    uint256 NOT_STAKER_SK = 2;

    uint256 DEADLINE       = 5_000_000_000;  // Timestamp far in the future
    uint256 DEPOSIT_AMOUNT = 1e18;
    uint256 NONCE          = 0;

    function setUp() public override virtual {
        super.setUp();

        STAKER     = vm.addr(STAKER_SK);
        NOT_STAKER = vm.addr(NOT_STAKER_SK);

        vm.prank(POOL_DELEGATE);
    }

    function test_depositWithPermit_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        ( , bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, STAKER_SK);

        address asset_ = IMaplePool(pool).asset();
        MockERC20(asset_).mint(STAKER, DEPOSIT_AMOUNT);

        vm.startPrank(STAKER);
        MockERC20(asset_).approve(address(pool), DEPOSIT_AMOUNT);
        vm.expectRevert("TEST_MESSAGE");
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, 17, r, s);
    }

    function test_depositWithPermit_zeroAddress() public {
        asset.mint(STAKER, DEPOSIT_AMOUNT);

        ( , bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:MALLEABLE"));
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, 17, r, s);
    }

    function test_depositWithPermit_notStakerSignature() public {
        asset.mint(STAKER, DEPOSIT_AMOUNT);

        (
            uint8 v,
            bytes32 r,
            bytes32 s
        ) = _getValidPermitSignature(NOT_STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, NOT_STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_pastDeadline() public {
        asset.mint(STAKER, DEPOSIT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.warp(DEADLINE + 1);

        vm.expectRevert(bytes("ERC20:P:EXPIRED"));
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_replay() public {
        asset.mint(STAKER, DEPOSIT_AMOUNT * 2);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_badNonce() public {
        asset.mint(STAKER, DEPOSIT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE + 1, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_zeroReceiver() public {
        asset.mint(STAKER, 1);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 1, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:M:ZERO_RECEIVER");
        pool.depositWithPermit(1, address(0), DEADLINE, v, r, s);
    }

    function test_depositWithPermit_zeroShares() public {
        asset.mint(STAKER, 1);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 0, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:M:ZERO_SHARES");
        pool.depositWithPermit(0, STAKER, DEADLINE, v, r, s);
    }

    function testFuzz_depositWithPermit_insufficientBalance(uint256 depositAmount_) public {
        depositAmount_ = bound(depositAmount_, 1, 1e29);
        asset.mint(STAKER, depositAmount_);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), depositAmount_ + 1, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.depositWithPermit(depositAmount_ + 1, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_reentrancy() public {
        asset.mint(STAKER, 1);
        asset.setReentrancy(address(pool));

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 1, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.depositWithPermit(1, STAKER, DEADLINE, v, r, s);
    }

}

contract MintTests is PoolTestBase {

    uint256 MINT_AMOUNT = 1e18;

    function test_mint_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        address asset_ = IMaplePool(pool).asset();
        MockERC20(asset_).mint(user, MINT_AMOUNT);

        vm.startPrank(user);
        MockERC20(asset_).approve(address(pool), MINT_AMOUNT);
        vm.expectRevert("TEST_MESSAGE");
        IMaplePool(pool).mint(MINT_AMOUNT, user);
    }

    function test_mint_zeroReceiver() public {
        asset.mint(address(this),    MINT_AMOUNT);
        asset.approve(address(pool), MINT_AMOUNT);

        vm.expectRevert("P:M:ZERO_RECEIVER");
        pool.mint(MINT_AMOUNT, address(0));
    }

    function test_mint_zeroShares() public {
        asset.mint(address(this),    MINT_AMOUNT);
        asset.approve(address(pool), MINT_AMOUNT);

        vm.expectRevert("P:M:ZERO_SHARES");
        pool.mint(0, address(this));
    }

    function testFuzz_mint_badApprove(uint256 mintAmount_) public {
        mintAmount_ = bound(mintAmount_, 1, 1e29);

        asset.mint(address(this),    mintAmount_);
        asset.approve(address(pool), mintAmount_ - 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.mint(mintAmount_, address(this));
    }

    function testFuzz_mint_insufficientBalance(uint256 mintAmount_) public {
        mintAmount_ = bound(mintAmount_, 1, 1e29);

        asset.mint(address(this),    mintAmount_);
        asset.approve(address(pool), mintAmount_ + 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.mint(mintAmount_ + 1, address(this));
    }

    function test_mint_reentrancy() public {
        asset.mint(address(this),    1);
        asset.approve(address(pool), 1);
        asset.setReentrancy(address(pool));

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.mint(1, address(this));
    }

}

contract MintWithPermitTests is PoolTestBase {

    address STAKER;
    address NOT_STAKER;

    uint256 STAKER_SK     = 1;
    uint256 NOT_STAKER_SK = 2;

    uint256 DEADLINE    = 5_000_000_000;  // Timestamp far in the future
    uint256 MAX_ASSETS  = type(uint256).max;
    uint256 MINT_AMOUNT = 1e18;
    uint256 NONCE       = 0;

    function setUp() public override virtual {
        super.setUp();

        STAKER     = vm.addr(STAKER_SK);
        NOT_STAKER = vm.addr(NOT_STAKER_SK);
    }

    function test_mintWithPermit_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        ( , bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MINT_AMOUNT, NONCE, DEADLINE, STAKER_SK);

        address asset_ = IMaplePool(pool).asset();
        MockERC20(asset_).mint(STAKER, MINT_AMOUNT);

        vm.startPrank(STAKER);
        MockERC20(asset_).approve(address(pool), MINT_AMOUNT);
        vm.expectRevert("TEST_MESSAGE");
        pool.mintWithPermit(MINT_AMOUNT, STAKER, 0, DEADLINE, 17, r, s);
    }

    function test_mintWithPermit_insufficientPermit() public {
        asset.mint(STAKER, 1);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 0, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:MWP:INSUFFICIENT_PERMIT");
        pool.mintWithPermit(1, STAKER, 0, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_zeroAddress() public {
        asset.mint(STAKER, MINT_AMOUNT);

        ( , bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:MALLEABLE"));
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, 17, r, s);
    }

    function test_mintWithPermit_notStakerSignature() public {
        asset.mint(STAKER, MINT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(NOT_STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, NOT_STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_pastDeadline() public {
        asset.mint(STAKER, MINT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.warp(DEADLINE + 1);

        vm.expectRevert(bytes("ERC20:P:EXPIRED"));
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_replay() public {
        asset.mint(STAKER, MINT_AMOUNT * 2);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_badNonce() public {
        asset.mint(STAKER, MINT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE + 1, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_zeroReceiver() public {
        asset.mint(STAKER, 1);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 1, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);
        vm.expectRevert("P:M:ZERO_RECEIVER");
        pool.mintWithPermit(1, address(0), 1, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_zeroShares() public {
        asset.mint(STAKER, 1);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 1, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);
        vm.expectRevert("P:M:ZERO_SHARES");
        pool.mintWithPermit(0, STAKER, 1, DEADLINE, v, r, s);
    }

    function testFuzz_mintWithPermit_insufficientBalance(uint256 mintAmount_) public {
        mintAmount_ = bound(mintAmount_, 1, 1e29);
        asset.mint(STAKER, mintAmount_);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), mintAmount_ + 1, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.mintWithPermit(mintAmount_ + 1, STAKER, mintAmount_ + 1, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_reentrancy() public {
        asset.mint(STAKER, 1);
        asset.setReentrancy(address(pool));

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 1, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.mintWithPermit(1, STAKER, 1, DEADLINE, v, r, s);
    }

}

contract RedeemTests is PoolTestBase {

    uint256 depositAmount = 1_000e6;

    function setUp() public override {
        super.setUp();

        _deposit(address(pool), address(poolManager), user, depositAmount);

        MockPoolManager(poolManager).__setRedeemableAssets(depositAmount);
    }

    function test_redeem_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
        MockPoolManager(address(poolManager)).__setRedeemableAssets(1_000e6);
        asset.mint(address(pool), 1_000e6);

        vm.prank(user);
        vm.expectRevert("TEST_MESSAGE");
        pool.redeem(500e6, user, user);  // Redeem half of tokens at 2:1
    }

    function test_redeem_reentrancy() external {
        MockPoolManager(address(poolManager)).__setRedeemableShares(depositAmount);

        asset.setReentrancy(address(pool));

        vm.startPrank(user);
        vm.expectRevert("P:B:TRANSFER");
        pool.redeem(depositAmount, user, user);

        asset.setReentrancy(address(0));
        pool.redeem(depositAmount, user, user);
    }

    function test_redeem_zeroShares() external {
        MockPoolManager(poolManager).__setRedeemableShares(0);
        MockPoolManager(poolManager).__setRedeemableAssets(0);

        assertEq(pool.balanceOf(user),  1000e6);
        assertEq(asset.balanceOf(user), 0);

        vm.prank(user);
        pool.redeem(1, user, user);

        assertEq(pool.balanceOf(user),  1000e6);
        assertEq(asset.balanceOf(user), 0);
    }

    function test_redeem_zeroAssets() external {
        MockPoolManager(poolManager).__setRedeemableShares(1);
        MockPoolManager(poolManager).__setRedeemableAssets(0);

        assertEq(pool.balanceOf(user),  1000e6);
        assertEq(asset.balanceOf(user), 0);

        vm.prank(user);
        pool.redeem(1, user, user);

        assertEq(pool.balanceOf(user),  1000e6 - 1);
        assertEq(asset.balanceOf(user), 0);
    }

    function test_redeem_insufficientApprove() external {
        MockPoolManager(poolManager).__setRedeemableShares(depositAmount);

        address user2 = makeAddr("user2");

        vm.prank(user);
        pool.approve(user2, depositAmount - 1);

        vm.prank(user2);
        vm.expectRevert(stdError.arithmeticError);
        pool.redeem(depositAmount, user2, user);

        vm.prank(user);
        pool.approve(user2, depositAmount);

        vm.prank(user2);
        pool.redeem(depositAmount, user2, user);
    }

    function test_redeem_insufficientAmount() external {
        MockPoolManager(poolManager).__setRedeemableShares(depositAmount + 1);

        vm.prank(user);
        vm.expectRevert(stdError.arithmeticError);
        pool.redeem(depositAmount + 1, user, user);
    }

    function test_redeem_success() external {
        // Add extra assets to the pool.
        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
        MockPoolManager(address(poolManager)).__setRedeemableShares(500e6);
        MockPoolManager(address(poolManager)).__setRedeemableAssets(1_000e6);

        asset.mint(address(pool), 1_000e6);

        assertEq(pool.totalSupply(),    1_000e6);
        assertEq(pool.totalAssets(),    2_000e6);
        assertEq(pool.balanceOf(user),  1_000e6);
        assertEq(asset.balanceOf(user), 0);

        vm.prank(user);
        uint256 withdrawAmount = pool.redeem(500e6, user, user);  // Redeem half of tokens at 2:1

        assertEq(withdrawAmount, 1000e6);

        MockPoolManager(address(poolManager)).__setTotalAssets(1_000e6);

        assertEq(pool.totalSupply(),    500e6);
        assertEq(pool.totalAssets(),    1_000e6);
        assertEq(pool.balanceOf(user),  500e6);
        assertEq(asset.balanceOf(user), 1_000e6);
    }

    function test_redeem_success_differentUser() external {
        // Add extra assets to the pool.
        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
        MockPoolManager(address(poolManager)).__setRedeemableShares(500e6);
        MockPoolManager(address(poolManager)).__setRedeemableAssets(1000e6);
        asset.mint(address(pool), 1000e6);

        address user2 = makeAddr("user2");

        vm.prank(user);
        pool.approve(user2, 1000e6);

        assertEq(pool.totalSupply(),          1_000e6);
        assertEq(pool.totalAssets(),          2_000e6);
        assertEq(pool.allowance(user, user2), 1_000e6);
        assertEq(pool.balanceOf(user),        1_000e6);
        assertEq(asset.balanceOf(user2),      0);

        vm.prank(user2);
        uint256 withdrawAmount = pool.redeem(500e6, user2, user);  // Redeem half of tokens at 2:1

        assertEq(withdrawAmount, 1000e6);

        MockPoolManager(address(poolManager)).__setTotalAssets(1_000e6);

        assertEq(pool.totalSupply(),          500e6);
        assertEq(pool.totalAssets(),          1_000e6);
        assertEq(pool.allowance(user, user2), 500e6);
        assertEq(pool.balanceOf(user),        500e6);
        assertEq(asset.balanceOf(user2),      1_000e6);
    }

}

contract RemoveSharesTests is PoolTestBase {

    uint256 depositAmount = 1_000e6;

    function setUp() public override {
        super.setUp();

        _deposit(address(pool), address(poolManager), user, depositAmount);

        MockPoolManager(poolManager).__setRedeemableAssets(depositAmount);
        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
        MockPoolManager(address(poolManager)).__setRedeemableAssets(1_000e6);

        asset.mint(address(pool), 1_000e6);

        vm.prank(user);
        pool.requestRedeem(500e6, address(user));
    }

    function test_removeShares_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        vm.prank(user);
        vm.expectRevert("TEST_MESSAGE");
        pool.removeShares(500e6, address(user));
    }

    function test_removeShares_failWithoutApproval() public {
        vm.expectRevert(stdError.arithmeticError);
        pool.removeShares(500e6, address(user));
    }

    function test_removeShares_insufficientApproval() public {
        vm.prank(user);
        pool.approve(address(this), 500e6 - 1);

        assertEq(pool.allowance(user, address(this)), 500e6 - 1);

        // Fail with insufficient approval
        vm.expectRevert(stdError.arithmeticError);
        pool.removeShares(500e6, address(user));

        vm.prank(user);
        pool.approve(address(this), 500e6);

        pool.removeShares(500e6, address(user));

        assertEq(pool.allowance(user, address(this)), 0);
    }

    function test_removeShares_withApproval() public {
        vm.prank(user);
        pool.approve(address(this), 500e6);

        assertEq(pool.allowance(user, address(this)), 500e6);

        pool.removeShares(500e6, address(user));

        assertEq(pool.allowance(user, address(this)), 0);
    }

}

contract RequestRedeemTests is PoolTestBase {

    uint256 depositAmount = 1_000e6;

    function setUp() public override {
        super.setUp();

        _deposit(address(pool), address(poolManager), user, depositAmount);

        MockPoolManager(poolManager).__setPool(address(pool));
        MockPoolManager(poolManager).__setRedeemableAssets(depositAmount);
    }

    function test_requestRedeem_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
        MockPoolManager(address(poolManager)).__setRedeemableAssets(1_000e6);
        asset.mint(address(pool), 1_000e6);

        vm.prank(user);
        vm.expectRevert("TEST_MESSAGE");
        pool.requestRedeem(500e6, address(user));
    }

    function test_requestRedeem_failWithoutApproval() public {
        vm.expectRevert(stdError.arithmeticError);
        pool.requestRedeem(500e6, address(user));
    }

    function test_requestRedeem_insufficientApproval() public {
        vm.prank(user);
        pool.approve(address(this), 500e6 - 1);

        assertEq(pool.allowance(user, address(this)), 500e6 - 1);

        // Fail with insufficient approval
        vm.expectRevert(stdError.arithmeticError);
        pool.requestRedeem(500e6, address(user));

        vm.prank(user);
        pool.approve(address(this), 500e6);

        pool.requestRedeem(500e6, address(user));

        assertEq(pool.allowance(user, address(this)), 0);
    }

    function test_requestRedeem_withApproval() public {
        vm.prank(user);
        pool.approve(address(this), 500e6);

        assertEq(pool.allowance(user, address(this)), 500e6);

        pool.requestRedeem(500e6, address(user));

        assertEq(pool.allowance(user, address(this)), 0);
    }

    function test_requestRedeem_zeroShares() public {
        vm.prank(user);
        pool.approve(address(this), 500e6);

        assertEq(pool.allowance(user, address(this)), 500e6);
        assertEq(pool.balanceOf(user),                1_000e6);

        vm.prank(user);
        pool.requestRedeem(0, address(user));

        assertEq(pool.allowance(user, address(this)), 500e6);
        assertEq(pool.balanceOf(user),                1_000e6);
    }

    function test_requestRedeem_zeroSharesAndNotOwnerAndNoAllowance() public {
        assertEq(pool.allowance(user, address(this)), 0);

        vm.expectRevert("PM:RR:NO_ALLOWANCE");
        pool.requestRedeem(0, address(user));
    }

}

contract RequestWithdraw is PoolTestBase {

    uint256 depositAmount = 1_000e6;

    function setUp() public override {
        super.setUp();

        _deposit(address(pool), address(poolManager), user, depositAmount);

        MockPoolManager(poolManager).__setRedeemableAssets(depositAmount);

    }

    function test_requestWithdraw_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
        MockPoolManager(address(poolManager)).__setRedeemableAssets(1_000e6);
        asset.mint(address(pool), 1_000e6);

        vm.prank(user);
        vm.expectRevert("TEST_MESSAGE");
        pool.requestWithdraw(500e6, address(user));
    }

    function test_requestWithdraw_failWithoutApproval() public {
        vm.expectRevert(stdError.arithmeticError);
        pool.requestWithdraw(500e6, address(user));
    }

    function test_requestWithdraw_insufficientApproval() public {
        vm.prank(user);
        pool.approve(address(this), 500e6 - 1);

        assertEq(pool.allowance(user, address(this)), 500e6 - 1);

        // Fail with insufficient approval
        vm.expectRevert(stdError.arithmeticError);
        pool.requestWithdraw(500e6, address(user));

        vm.prank(user);
        pool.approve(address(this), 500e6);

        vm.expectRevert("PM:RW:NOT_ENABLED");
        pool.requestWithdraw(500e6, address(user));
    }

    function test_requestWithdraw_withApproval_failNotEnabled() public {
        vm.prank(user);
        pool.approve(address(this), 500e6);

        assertEq(pool.allowance(user, address(this)), 500e6);

        vm.expectRevert("PM:RW:NOT_ENABLED");
        pool.requestWithdraw(500e6, address(user));
    }

    function testFuzz_requestWithdraw_failNotEnabled(uint256 assets_) public {
        assets_ = bound(assets_, 0, depositAmount);
        vm.prank(user);
        pool.approve(address(this), assets_);

        assertEq(pool.allowance(user, address(this)), assets_);

        vm.expectRevert("PM:RW:NOT_ENABLED");
        pool.requestWithdraw(assets_, address(user));
    }

}

contract TransferTests is PoolTestBase {

    address RECIPIENT = makeAddr("RECIPIENT");

    uint256 TRANSFER_AMOUNT = 1e18;

    function setUp() public override {
        super.setUp();

        asset.mint(address(this),    TRANSFER_AMOUNT);
        asset.approve(address(pool), TRANSFER_AMOUNT);

        pool.deposit(TRANSFER_AMOUNT, address(this));
    }

}

contract TransferFromTests is PoolTestBase {

    address RECIPIENT = makeAddr("RECIPIENT");
    address OWNER     = makeAddr("OWNER");

    uint256 TRANSFER_AMOUNT = 1e18;

    function setUp() public override {
        super.setUp();

        vm.startPrank(OWNER);

        asset.mint(OWNER,            TRANSFER_AMOUNT);
        asset.approve(address(pool), TRANSFER_AMOUNT);

        pool.deposit(TRANSFER_AMOUNT, OWNER);
        pool.approve(address(this), type(uint256).max);

        vm.stopPrank();
    }

}

contract WithdrawTests is PoolTestBase {

    uint256 depositAmount = 1_000e6;

    function setUp() public override {
        super.setUp();

        _deposit(address(pool), address(poolManager), user, depositAmount);

        MockPoolManager(poolManager).__setRedeemableShares(depositAmount);
        MockPoolManager(poolManager).__setRedeemableAssets(depositAmount);
    }

    function test_withdraw_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
        MockPoolManager(address(poolManager)).__setRedeemableAssets(1_000e6);
        asset.mint(address(pool), 1_000e6);

        vm.prank(user);
        vm.expectRevert("TEST_MESSAGE");
        pool.withdraw(500e6, user, user);
    }

    function test_withdraw_failNotEnabled() external {
        vm.prank(user);
        vm.expectRevert("PM:PW:NOT_ENABLED");
        pool.withdraw(1, user, user);
    }

    function testFuzz_withdraw_failNotEnabled(uint256 assets_) external {
        vm.prank(user);
        vm.expectRevert("PM:PW:NOT_ENABLED");
        pool.withdraw(assets_, user, user);
    }

}

contract PreviewDepositTests is PoolTestBase {

    function test_previewDeposit_initialState() public {
        _setupPool({ totalSupply_: 0, totalAssets_: 0, unrealizedLosses_: 0 });

        assertEq(pool.previewDeposit(0), 0);
        assertEq(pool.previewDeposit(1), 1);
        assertEq(pool.previewDeposit(2), 2);
    }

    function test_previewDeposit_worthlessShares() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 0, unrealizedLosses_: 0 });

        vm.expectRevert(stdError.divisionError);
        pool.previewDeposit(0);

        vm.expectRevert(stdError.divisionError);
        pool.previewDeposit(1);

        vm.expectRevert(stdError.divisionError);
        pool.previewDeposit(2);
    }

    function test_previewDeposit_prematureYield() public {
        _setupPool({ totalSupply_: 0, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.previewDeposit(0), 0);
        assertEq(pool.previewDeposit(1), 1);
        assertEq(pool.previewDeposit(2), 2);
    }

    function test_previewDeposit_initialExchangeRate() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.previewDeposit(0), 0);
        assertEq(pool.previewDeposit(1), 1);
        assertEq(pool.previewDeposit(2), 2);
    }

    function test_previewDeposit_increasedExchangeRate() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 2, unrealizedLosses_: 0 });

        assertEq(pool.previewDeposit(0), 0);
        assertEq(pool.previewDeposit(1), 0);
        assertEq(pool.previewDeposit(2), 1);
    }

    function test_previewDeposit_decreasedExchangeRate() public {
        _setupPool({ totalSupply_: 2, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.previewDeposit(0), 0);
        assertEq(pool.previewDeposit(1), 2);
        assertEq(pool.previewDeposit(2), 4);
    }

    function testFuzz_previewDeposit(uint256 totalSupply_, uint256 totalAssets_, uint256 assetsToDeposit_) public {
        totalSupply_     = bound(totalSupply_,     0, 1e30);
        totalAssets_     = bound(totalAssets_,     0, 1e30);
        assetsToDeposit_ = bound(assetsToDeposit_, 0, 1e30);

        _setupPool({ totalSupply_: totalSupply_, totalAssets_: totalAssets_, unrealizedLosses_: 0 });

        if (totalSupply_ != 0 && totalAssets_ == 0) {
            vm.expectRevert(stdError.divisionError);
        }

        uint256 sharesToMint_ = pool.previewDeposit(assetsToDeposit_);

        if (totalSupply_ == 0) {
            assertEq(sharesToMint_, assetsToDeposit_);
        } else if (totalAssets_ != 0) {
            assertEq(sharesToMint_, assetsToDeposit_ * pool.totalSupply() / pool.totalAssets());
        }
    }

}

contract PreviewMintTests is PoolTestBase {

    function test_previewMint_initialState() public {
        _setupPool({ totalSupply_: 0, totalAssets_: 0, unrealizedLosses_: 0 });

        assertEq(pool.previewMint(0), 0);
        assertEq(pool.previewMint(1), 1);
        assertEq(pool.previewMint(2), 2);
    }

    function test_previewMint_worthlessShares() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 0, unrealizedLosses_: 0 });

        assertEq(pool.previewMint(0), 0);
        assertEq(pool.previewMint(1), 0);
        assertEq(pool.previewMint(2), 0);
    }

    function test_previewMint_prematureYield() public {
        _setupPool({ totalSupply_: 0, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.previewMint(0), 0);
        assertEq(pool.previewMint(1), 1);
        assertEq(pool.previewMint(2), 2);
    }

    function test_previewMint_initialExchangeRate() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.previewMint(0), 0);
        assertEq(pool.previewMint(1), 1);
        assertEq(pool.previewMint(2), 2);
    }

    function test_previewMint_increasedExchangeRate() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 2, unrealizedLosses_: 0 });

        assertEq(pool.previewMint(0), 0);
        assertEq(pool.previewMint(1), 2);
        assertEq(pool.previewMint(2), 4);
    }

    function test_previewMint_decreasedExchangeRate() public {
        _setupPool({ totalSupply_: 2, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.previewMint(0), 0);
        assertEq(pool.previewMint(1), 1);
        assertEq(pool.previewMint(2), 1);
    }

    function testFuzz_previewMint(uint256 totalSupply_, uint256 totalAssets_, uint256 sharesToMint_) public {
        totalSupply_  = bound(totalSupply_,  0, 1e30);
        totalAssets_  = bound(totalAssets_,  0, 1e30);
        sharesToMint_ = bound(sharesToMint_, 0, 1e30);

        _setupPool({ totalSupply_: totalSupply_, totalAssets_: totalAssets_, unrealizedLosses_: 0 });

        uint256 assetsToDeposit_ = pool.previewMint(sharesToMint_);

        if (totalSupply_ == 0) {
            assertEq(assetsToDeposit_, sharesToMint_);
        } else {
            assertEq(
                assetsToDeposit_,
                (sharesToMint_ * pool.totalAssets() / pool.totalSupply()) +
                (sharesToMint_ * pool.totalAssets() % pool.totalSupply() == 0 ? 0 : 1)
            );
        }
    }

}

contract ConvertToExitAssetsTests is PoolTestBase {

    function test_convertToExitAssets_zeroSupply() external {
        assertEq(pool.convertToExitAssets(0),   0);
        assertEq(pool.convertToExitAssets(1),   1);
        assertEq(pool.convertToExitAssets(100), 100);

        assertEq(pool.convertToExitAssets(type(uint256).max), type(uint256).max);
    }

    function testFuzz_convertToExitAssets_zeroSupply(uint256 shares) external {
        assertEq(pool.convertToExitAssets(shares), shares);
    }

    function test_convertToExitAssets() external {
        _deposit(address(pool), address(poolManager), address(this), 100);  // Set totalSupply to 100

        MockPoolManager(poolManager).__setTotalAssets(100);

        assertEq(pool.convertToExitAssets(100), 100);
        assertEq(pool.convertToExitAssets(101), 101);

        MockPoolManager(poolManager).__setTotalAssets(101);

        assertEq(pool.convertToExitAssets(100), 101);  // 100 * 101 / 100
        assertEq(pool.convertToExitAssets(150), 151);  // 150 * 101 / 100 Round down

        MockPoolManager(poolManager).__setTotalAssets(100);
        MockPoolManager(poolManager).__setUnrealizedLosses(100);

        assertEq(pool.convertToExitAssets(100),               0);  // Zero numerator
        assertEq(pool.convertToExitAssets(type(uint256).max), 0);  // Zero numerator

        MockPoolManager(poolManager).__setUnrealizedLosses(50);

        assertEq(pool.convertToExitAssets(100), 50);  // Half
    }

    function testFuzz_convertToExitAssets(uint256 totalSupply, uint256 totalAssets, uint256 unrealizedLosses, uint256 shares) external {
        totalSupply      = bound(totalSupply,      1, 1e29);
        totalAssets      = bound(totalAssets,      0, 1e29);
        unrealizedLosses = bound(unrealizedLosses, 0, totalAssets);
        shares           = bound(shares,           1, 1e29);

        _deposit(address(pool), address(poolManager), address(this), totalSupply);  // Set totalSupply

        MockPoolManager(poolManager).__setTotalAssets(totalAssets);
        MockPoolManager(poolManager).__setUnrealizedLosses(unrealizedLosses);

        assertEq(pool.convertToExitAssets(shares), shares * (totalAssets - unrealizedLosses) / totalSupply);
    }

}

// contract PreviewRedeemTests is TestBase {

//     function test_previewRedeem_initialState() public {
//         _setupPool({ totalSupply_: 0, totalAssets_: 0, unrealizedLosses_: 0 });

//         assertEq(pool.previewRedeem(0), 0);
//         assertEq(pool.previewRedeem(1), 1);
//         assertEq(pool.previewRedeem(2), 2);
//     }

//     function test_previewRedeem_worthlessShares() public {
//         _setupPool({ totalSupply_: 1, totalAssets_: 0, unrealizedLosses_: 0 });

//         assertEq(pool.previewRedeem(0), 0);
//         assertEq(pool.previewRedeem(1), 0);
//         assertEq(pool.previewRedeem(2), 0);
//     }

//     function test_previewRedeem_prematureYield() public {
//         _setupPool({ totalSupply_: 0, totalAssets_: 1, unrealizedLosses_: 0 });

//         assertEq(pool.previewRedeem(0), 0);
//         assertEq(pool.previewRedeem(1), 1);
//         assertEq(pool.previewRedeem(2), 2);
//     }

//     function test_previewRedeem_initialExchangeRate() public {
//         _setupPool({ totalSupply_: 1, totalAssets_: 1, unrealizedLosses_: 0 });

//         assertEq(pool.previewRedeem(0), 0);
//         assertEq(pool.previewRedeem(1), 1);
//         assertEq(pool.previewRedeem(2), 2);
//     }

//     function test_previewRedeem_increasedExchangeRate() public {
//         _setupPool({ totalSupply_: 1, totalAssets_: 2, unrealizedLosses_: 0 });

//         assertEq(pool.previewRedeem(0), 0);
//         assertEq(pool.previewRedeem(1), 2);
//         assertEq(pool.previewRedeem(2), 4);
//     }

//     function test_previewRedeem_decreasedExchangeRate() public {
//         _setupPool({ totalSupply_: 2, totalAssets_: 1, unrealizedLosses_: 0 });

//         assertEq(pool.previewRedeem(0), 0);
//         assertEq(pool.previewRedeem(1), 0);
//         assertEq(pool.previewRedeem(2), 1);
//     }

//     function test_previewRedeem_unrealizedLosses() public {
//         _setupPool({ totalSupply_: 2, totalAssets_: 2, unrealizedLosses_: 1 });

//         assertEq(pool.previewRedeem(0), 0);
//         assertEq(pool.previewRedeem(1), 0);
//         assertEq(pool.previewRedeem(2), 1);
//     }

//     function testFuzz_previewRedeem(uint256 totalSupply_, uint256 totalAssets_, uint256 unrealizedLosses_, uint256 sharesToRedeem_) public {
//         totalSupply_      = constrictToRange(totalSupply_,      0, 1e30);
//         totalAssets_      = constrictToRange(totalAssets_,      0, 1e30);
//         unrealizedLosses_ = constrictToRange(unrealizedLosses_, 0, totalAssets_);
//         sharesToRedeem_   = constrictToRange(sharesToRedeem_,   0, 1e30);

//         _setupPool({ totalSupply_: totalSupply_, totalAssets_: totalAssets_, unrealizedLosses_: unrealizedLosses_ });

//         uint256 assetsToWithdraw_ = pool.previewRedeem(sharesToRedeem_);

//         if (totalSupply_ == 0) {
//             assertEq(assetsToWithdraw_, sharesToRedeem_);
//         } else {
//             // assertEq(assetsToWithdraw_, sharesToRedeem_ * pool.totalAssetsWithUnrealizedLosses() / pool.totalSupply());
//         }
//     }

// }

// contract PreviewWithdrawTests is TestBase {

//     function test_previewWithdraw_initialState() public {
//         _setupPool({ totalSupply_: 0, totalAssets_: 0, unrealizedLosses_: 0 });

//         assertEq(pool.previewWithdraw(0), 0);
//         assertEq(pool.previewWithdraw(1), 1);
//         assertEq(pool.previewWithdraw(2), 2);
//     }

//     function test_previewWithdraw_worthlessShares() public {
//         _setupPool({ totalSupply_: 1, totalAssets_: 0, unrealizedLosses_: 0 });

//         vm.expectRevert(ZERO_DIVISION);
//         pool.previewWithdraw(0);

//         vm.expectRevert(ZERO_DIVISION);
//         pool.previewWithdraw(1);

//         vm.expectRevert(ZERO_DIVISION);
//         pool.previewWithdraw(2);
//     }

//     function test_previewWithdraw_prematureYield() public {
//         _setupPool({ totalSupply_: 0, totalAssets_: 1, unrealizedLosses_: 0 });

//         assertEq(pool.previewWithdraw(0), 0);
//         assertEq(pool.previewWithdraw(1), 1);
//         assertEq(pool.previewWithdraw(2), 2);
//     }

//     function test_previewWithdraw_initialExchangeRate() public {
//         _setupPool({ totalSupply_: 1, totalAssets_: 1, unrealizedLosses_: 0 });

//         assertEq(pool.previewWithdraw(0), 0);
//         assertEq(pool.previewWithdraw(1), 1);
//         assertEq(pool.previewWithdraw(2), 2);
//     }

//     function test_previewWithdraw_increasedExchangeRate() public {
//         _setupPool({ totalSupply_: 1, totalAssets_: 2, unrealizedLosses_: 0 });

//         assertEq(pool.previewWithdraw(0), 0);
//         assertEq(pool.previewWithdraw(1), 1);
//         assertEq(pool.previewWithdraw(2), 1);
//     }

//     function test_previewWithdraw_decreasedExchangeRate() public {
//         _setupPool({ totalSupply_: 2, totalAssets_: 1, unrealizedLosses_: 0 });

//         assertEq(pool.previewWithdraw(0), 0);
//         assertEq(pool.previewWithdraw(1), 2);
//         assertEq(pool.previewWithdraw(2), 4);
//     }

//     function test_previewWithdraw_unrealizedLosses() public {
//         _setupPool({ totalSupply_: 2, totalAssets_: 2, unrealizedLosses_: 1 });

//         assertEq(pool.previewWithdraw(0), 0);
//         assertEq(pool.previewWithdraw(1), 2);
//         assertEq(pool.previewWithdraw(2), 4);
//     }

//     function testFuzz_previewWithdraw(uint256 totalSupply_, uint256 totalAssets_, uint256 unrealizedLosses_, uint256 assetsToWithdraw_) public {
//         totalSupply_      = constrictToRange(totalSupply_,      0, 1e30);
//         totalAssets_      = constrictToRange(totalAssets_,      0, 1e30);
//         unrealizedLosses_ = constrictToRange(unrealizedLosses_, 0, totalAssets_);
//         assetsToWithdraw_ = constrictToRange(assetsToWithdraw_, 0, 1e30);

//         _setupPool({ totalSupply_: totalSupply_, totalAssets_: totalAssets_, unrealizedLosses_: unrealizedLosses_ });

//         if (totalSupply_ != 0 && totalAssets_ - unrealizedLosses_ == 0) {
//             vm.expectRevert(ZERO_DIVISION);
//         }

//         uint256 sharesToRedeem_ = pool.previewWithdraw(assetsToWithdraw_);

//         if (totalSupply_ == 0) {
//             assertEq(sharesToRedeem_, assetsToWithdraw_);
//         } else if (totalAssets_ - unrealizedLosses_ != 0) {
//             assertEq(
//                 sharesToRedeem_,
//                 (assetsToWithdraw_ * pool.totalSupply() / pool.totalAssets()) +
//                 (assetsToWithdraw_ * pool.totalSupply() % pool.totalAssets() == 0 ? 0 : 1)
//             );
//         }
//     }

// }

contract ConvertToAssetsTests is PoolTestBase {

    function test_convertToAssets_initialState() public {
        _setupPool({ totalSupply_: 0, totalAssets_: 0, unrealizedLosses_: 0 });

        assertEq(pool.convertToAssets(0), 0);
        assertEq(pool.convertToAssets(1), 1);
        assertEq(pool.convertToAssets(2), 2);
    }

    function test_convertToAssets_worthlessShares() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 0, unrealizedLosses_: 0 });

        assertEq(pool.convertToAssets(0), 0);
        assertEq(pool.convertToAssets(1), 0);
        assertEq(pool.convertToAssets(2), 0);
    }

    function test_convertToAssets_prematureYield() public {
        _setupPool({ totalSupply_: 0, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.convertToAssets(0), 0);
        assertEq(pool.convertToAssets(1), 1);
        assertEq(pool.convertToAssets(2), 2);
    }

    function test_convertToAssets_initialExchangeRate() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.convertToAssets(0), 0);
        assertEq(pool.convertToAssets(1), 1);
        assertEq(pool.convertToAssets(2), 2);
    }

    function test_convertToAssets_increasedExchangeRate() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 2, unrealizedLosses_: 0 });

        assertEq(pool.convertToAssets(0), 0);
        assertEq(pool.convertToAssets(1), 2);
        assertEq(pool.convertToAssets(2), 4);
    }

    function test_convertToAssets_decreasedExchangeRate() public {
        _setupPool({ totalSupply_: 2, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.convertToAssets(0), 0);
        assertEq(pool.convertToAssets(1), 0);
        assertEq(pool.convertToAssets(2), 1);
    }

    function testFuzz_convertToAssets(uint256 totalSupply_, uint256 totalAssets_, uint256 sharesToConvert_) public {
        totalSupply_     = bound(totalSupply_,     0, 1e30);
        totalAssets_     = bound(totalAssets_,     0, 1e30);
        sharesToConvert_ = bound(sharesToConvert_, 0, 1e30);

        _setupPool({ totalSupply_: totalSupply_, totalAssets_: totalAssets_, unrealizedLosses_: 0 });

        uint256 assets_ = pool.convertToAssets(sharesToConvert_);

        if (totalSupply_ == 0) {
            assertEq(assets_, sharesToConvert_);
        } else {
            assertEq(assets_, sharesToConvert_ * pool.totalAssets() / pool.totalSupply());
        }
    }
}

contract ConvertToSharesTests is PoolTestBase {

    function test_convertToShares_initialState() public {
        _setupPool({ totalSupply_: 0, totalAssets_: 0, unrealizedLosses_: 0 });

        assertEq(pool.convertToShares(0), 0);
        assertEq(pool.convertToShares(1), 1);
        assertEq(pool.convertToShares(2), 2);
    }

    function test_convertToShares_worthlessShares() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 0, unrealizedLosses_: 0 });

        vm.expectRevert(stdError.divisionError);
        pool.convertToShares(0);

        vm.expectRevert(stdError.divisionError);
        pool.convertToShares(1);

        vm.expectRevert(stdError.divisionError);
        pool.convertToShares(2);
    }

    function test_convertToShares_prematureYield() public {
        _setupPool({ totalSupply_: 0, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.convertToShares(0), 0);
        assertEq(pool.convertToShares(1), 1);
        assertEq(pool.convertToShares(2), 2);
    }

    function test_convertToShares_initialExchangeRate() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.convertToShares(0), 0);
        assertEq(pool.convertToShares(1), 1);
        assertEq(pool.convertToShares(2), 2);
    }

    function test_convertToShares_increasedExchangeRate() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 2, unrealizedLosses_: 0 });

        assertEq(pool.convertToShares(0), 0);
        assertEq(pool.convertToShares(1), 0);
        assertEq(pool.convertToShares(2), 1);
    }

    function test_convertToShares_decreasedExchangeRate() public {
        _setupPool({ totalSupply_: 2, totalAssets_: 1, unrealizedLosses_: 0 });

        assertEq(pool.convertToShares(0), 0);
        assertEq(pool.convertToShares(1), 2);
        assertEq(pool.convertToShares(2), 4);
    }

    function testFuzz_convertToShares(uint256 totalSupply_, uint256 totalAssets_, uint256 assetsToConvert_) public {
        totalSupply_     = bound(totalSupply_,     0, 1e30);
        totalAssets_     = bound(totalAssets_,     0, 1e30);
        assetsToConvert_ = bound(assetsToConvert_, 0, 1e30);

        _setupPool({ totalSupply_: totalSupply_, totalAssets_: totalAssets_, unrealizedLosses_: 0 });

        if (totalSupply_ != 0 && totalAssets_ == 0) {
            vm.expectRevert(stdError.divisionError);
        }

        uint256 shares_ = pool.convertToShares(assetsToConvert_);

        if (totalSupply_ == 0) {
            assertEq(shares_, assetsToConvert_);
        } else if (totalAssets_ != 0) {
            assertEq(shares_, assetsToConvert_ * pool.totalSupply() / pool.totalAssets());
        }
    }

}
