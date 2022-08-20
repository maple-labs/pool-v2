// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { IPool } from "../contracts/interfaces/IPool.sol";

import { Pool }                   from "../contracts/Pool.sol";
import { PoolManager }            from "../contracts/PoolManager.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import {
    MockGlobals,
    MockReenteringERC20,
    MockRevertingERC20,
    MockPoolManager,
    MockWithdrawalManager
} from "./mocks/Mocks.sol";

import { GlobalsBootstrapper } from "./bootstrap/GlobalsBootstrapper.sol";

contract PoolBase is TestUtils, GlobalsBootstrapper {

    address POOL_DELEGATE = address(new Address());

    MockReenteringERC20   asset;
    MockWithdrawalManager withdrawalManager;
    Pool                  pool;
    PoolManagerFactory    factory;

    address poolManager;
    address implementation;
    address initializer;

    address user = address(new Address());

    function setUp() public virtual {
        asset = new MockReenteringERC20();

        _deployAndBootstrapGlobals(address(asset), POOL_DELEGATE);

        factory = new PoolManagerFactory(address(globals));

        implementation = address(new PoolManager());
        initializer    = address(new PoolManagerInitializer());

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "POOL1";

        MockGlobals(globals).setValidPoolDeployer(address(this), true);

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), POOL_DELEGATE, address(asset), 0, poolName_, poolSymbol_);

        poolManager = address(PoolManager(PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(POOL_DELEGATE)))));

        pool = Pool(PoolManager(poolManager).pool());

        withdrawalManager = new MockWithdrawalManager();

        address mockPoolManager = address(new MockPoolManager());
        vm.etch(poolManager, mockPoolManager.code);

        MockPoolManager(poolManager).__setCanCall(true, "");

        MockPoolManager(poolManager).setWithdrawalManager(address(withdrawalManager));
    }

    // Returns an ERC-2612 `permit` digest for the `owner` to sign
    function _getDigest(address owner_, address spender_, uint256 value_, uint256 nonce_, uint256 deadline_) internal view returns (bytes32 digest_) {
        return keccak256(
            abi.encodePacked(
                '\x19\x01',
                asset.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(asset.PERMIT_TYPEHASH(), owner_, spender_, value_, nonce_, deadline_))
            )
        );
    }

    // Returns a valid `permit` signature signed by this contract's `owner` address
    function _getValidPermitSignature(address owner_, address spender_, uint256 value_, uint256 nonce_, uint256 deadline_, uint256 ownerSk_) internal returns (uint8 v_, bytes32 r_, bytes32 s_) {
        return vm.sign(ownerSk_, _getDigest(owner_, spender_, value_, nonce_, deadline_));
    }

    function _deposit(address pool_, address poolManager_, address user_, uint256 assetAmount_) internal returns (uint256 shares_) {
        address asset_ = IPool(pool_).asset();
        MockERC20(asset_).mint(user_, assetAmount_);

        vm.startPrank(user_);
        MockERC20(asset_).approve(pool_, assetAmount_);
        shares_ = IPool(pool_).deposit(assetAmount_, user_);
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

contract ConstructorTests is PoolBase {

    function setUp() public override {}

    function test_constructor_zeroManager() public {
        address asset = address(new MockERC20("Asset", "AT", 18));

        vm.expectRevert("P:C:ZERO_ADDRESS");
        new Pool(address(0), asset, address(0), 0, "Pool", "POOL1");

        new Pool(address(new Address()), asset, address(0), 0, "Pool", "POOL1");
    }

    function test_constructor_invalidDecimals() public {
        address asset = address(new MockRevertingERC20("Asset", "AT", 18));
        MockRevertingERC20(asset).__setIsRevertingDecimals(true);

        address poolDelegate = address(new Address());

        vm.expectRevert("ERC20:D:REVERT");
        new Pool(poolDelegate, asset, address(0), 0, "Pool", "POOL1");

        asset = address(new MockERC20("Asset", "AT", 18));
        new Pool(poolDelegate, asset, address(0), 0, "Pool", "POOL1");
    }

    function test_constructor_invalidApproval() public {
        address asset = address(new MockRevertingERC20("Asset", "AT", 18));
        MockRevertingERC20(asset).__setIsRevertingApprove(true);

        address poolDelegate = address(new Address());

        vm.expectRevert("ERC20:A:REVERT");
        new Pool(poolDelegate, asset, address(0), 0, "Pool", "POOL1");

        asset = address(new MockERC20("Asset", "AT", 18));
        new Pool(poolDelegate, asset, address(0), 0, "Pool", "POOL1");
    }

}

contract DepositTests is PoolBase {

    uint256 DEPOSIT_AMOUNT = 1e18;

    function test_deposit_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        uint256 depositAmount_ = 1_000e6;

        address asset_ = IPool(pool).asset();
        MockERC20(asset_).mint(user, depositAmount_);

        vm.startPrank(user);
        MockERC20(asset_).approve(address(pool), depositAmount_);
        vm.expectRevert("TEST_MESSAGE");
        IPool(pool).deposit(depositAmount_, user);
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
        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);

        asset.mint(address(this),    depositAmount_);
        asset.approve(address(pool), depositAmount_ - 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.deposit(depositAmount_, address(this));
    }

    function testFuzz_deposit_insufficientBalance(uint256 depositAmount_) public {
        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);

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

    function testFuzz_deposit() public {
        // TODO: Generic fuzz test.
    }

}

contract DepositWithPermitTests is PoolBase {

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

        address asset_ = IPool(pool).asset();
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

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(NOT_STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, NOT_STAKER_SK);

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
        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);
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

    function testFuzz_depositWithPermit() public {
        // TODO: Generic fuzz test.
    }

}

contract MintTests is PoolBase {

    uint256 MINT_AMOUNT = 1e18;

    function test_mint_checkCall() public {
        MockPoolManager(poolManager).__setCanCall(false, "TEST_MESSAGE");

        address asset_ = IPool(pool).asset();
        MockERC20(asset_).mint(user, MINT_AMOUNT);

        vm.startPrank(user);
        MockERC20(asset_).approve(address(pool), MINT_AMOUNT);
        vm.expectRevert("TEST_MESSAGE");
        IPool(pool).mint(MINT_AMOUNT, user);
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
        mintAmount_ = constrictToRange(mintAmount_, 1, 1e29);

        asset.mint(address(this),    mintAmount_);
        asset.approve(address(pool), mintAmount_ - 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.mint(mintAmount_, address(this));
    }

    function testFuzz_mint_insufficientBalance(uint256 mintAmount_) public {
        mintAmount_ = constrictToRange(mintAmount_, 1, 1e29);

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

    function testFuzz_mint() public {
        // TODO: Generic fuzz test.
    }

}

contract MintWithPermitTests is PoolBase {

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

        address asset_ = IPool(pool).asset();
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
        mintAmount_ = constrictToRange(mintAmount_, 1, 1e29);
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

    function testFuzz_mintWithPermit() public {
        // TODO: Generic fuzz test.
    }

}

contract RedeemTests is PoolBase {

    uint256 depositAmount = 1_000e6;

    function setUp() public override {
        super.setUp();

        _deposit(address(pool), address(poolManager), user, depositAmount);

        MockPoolManager(poolManager).__setRedeemableAssets(depositAmount);
    }

    function test_redeem_reentrancy() external {
        asset.setReentrancy(address(pool));

        vm.startPrank(user);
        vm.expectRevert("P:B:TRANSFER");
        pool.redeem(depositAmount, user, user);

        asset.setReentrancy(address(0));
        pool.redeem(depositAmount, user, user);
    }

    function test_redeem_zeroShares() external {
        vm.prank(user);
        vm.expectRevert("P:B:ZERO_SHARES");
        pool.redeem(0, user, user);
    }

    function test_redeem_zeroAssets() external {
        MockPoolManager(poolManager).__setRedeemableAssets(0);

        vm.prank(user);
        vm.expectRevert("P:B:ZERO_SHARES");
        pool.redeem(0, user, user);
    }

    function test_redeem_insufficientApprove() external {
        address user2 = address(new Address());

        vm.prank(user);
        pool.approve(user2, depositAmount - 1);

        vm.prank(user2);
        vm.expectRevert(ARITHMETIC_ERROR);
        pool.redeem(depositAmount, user2, user);

        vm.prank(user);
        pool.approve(user2, depositAmount);

        vm.prank(user2);
        pool.redeem(depositAmount, user2, user);
    }

    function test_redeem_insufficientAmount() external {
        vm.prank(user);
        vm.expectRevert(ARITHMETIC_ERROR);
        pool.redeem(depositAmount + 1, user, user);
    }

    function test_redeem_success() external {
        // Add extra assets to the pool.
        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
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
        MockPoolManager(address(poolManager)).__setRedeemableAssets(1000e6);
        asset.mint(address(pool), 1000e6);

        address user2 = address(new Address());

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

contract TransferTests is PoolBase {

    address RECIPIENT = address(new Address());

    uint256 TRANSFER_AMOUNT = 1e18;

    function setUp() public override {
        super.setUp();

        asset.mint(address(this),    TRANSFER_AMOUNT);
        asset.approve(address(pool), TRANSFER_AMOUNT);

        pool.deposit(TRANSFER_AMOUNT, address(this));
    }

    function testFuzz_transfer_success() public {
        // TODO: Generic fuzz test.
    }

}

contract TransferFromTests is PoolBase {

    address RECIPIENT = address(new Address());
    address OWNER     = address(new Address());

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

    function testFuzz_transferFrom_success() public {
        // TODO: Generic fuzz test.
    }

}

contract WithdrawTests is PoolBase {

    uint256 depositAmount = 1_000e6;

    function setUp() public override {
        super.setUp();

        _deposit(address(pool), address(poolManager), user, depositAmount);

        MockPoolManager(poolManager).__setRedeemableShares(depositAmount);
        MockPoolManager(poolManager).__setRedeemableAssets(depositAmount);
    }

    function test_withdraw_reentrancy() external {
        asset.setReentrancy(address(pool));

        vm.startPrank(user);
        vm.expectRevert("P:B:TRANSFER");
        pool.withdraw(depositAmount, user, user);

        asset.setReentrancy(address(0));
        pool.withdraw(depositAmount, user, user);
    }

    function test_withdraw_zeroReceiver() external {
        vm.prank(user);
        vm.expectRevert("P:B:ZERO_RECEIVER");
        pool.withdraw(0, address(0), user);
    }

    function test_withdraw_zeroAssets() external {
        MockPoolManager(poolManager).__setRedeemableAssets(0);

        vm.prank(user);
        vm.expectRevert("P:B:ZERO_ASSETS");
        pool.withdraw(0, user, user);
    }

    function test_withdraw_zeroShares() external {
        MockPoolManager(poolManager).__setRedeemableShares(0);

        vm.prank(user);
        vm.expectRevert("P:B:ZERO_SHARES");
        pool.withdraw(0, user, user);
    }

    function test_withdraw_insufficientApprove() external {
        address user2 = address(new Address());

        vm.prank(user);
        pool.approve(user2, depositAmount - 1);

        vm.prank(user2);
        vm.expectRevert(ARITHMETIC_ERROR);
        pool.withdraw(depositAmount, user2, user);

        vm.prank(user);
        pool.approve(user2, depositAmount);

        vm.prank(user2);
        pool.withdraw(depositAmount, user2, user);
    }

    function test_withdraw_insufficientAmount() external {
        MockPoolManager(poolManager).__setRedeemableShares(depositAmount + 1);
        vm.prank(user);
        vm.expectRevert(ARITHMETIC_ERROR);
        pool.withdraw(depositAmount + 1, user, user);
    }

    function test_withdraw_success() external {
        // Add extra assets to the pool.
        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
        MockPoolManager(address(poolManager)).__setRedeemableShares(500e6);
        MockPoolManager(address(poolManager)).__setRedeemableAssets(1000e6);
        asset.mint(address(pool), 1000e6);

        assertEq(pool.totalSupply(),    1_000e6);
        assertEq(pool.totalAssets(),    2_000e6);
        assertEq(pool.balanceOf(user),  1_000e6);
        assertEq(asset.balanceOf(user), 0);

        vm.prank(user);
        uint256 redeemAmount = pool.withdraw(1_000e6, user, user);

        assertEq(redeemAmount, 500e6);

        MockPoolManager(address(poolManager)).__setTotalAssets(1_000e6);

        assertEq(pool.totalSupply(),    500e6);
        assertEq(pool.totalAssets(),    1_000e6);
        assertEq(pool.balanceOf(user),  500e6);
        assertEq(asset.balanceOf(user), 1_000e6);
    }

    function test_withdraw_success_differentUser() external {
        // Add extra assets to the pool.
        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
        MockPoolManager(address(poolManager)).__setRedeemableShares(500e6);
        MockPoolManager(address(poolManager)).__setRedeemableAssets(1000e6);
        asset.mint(address(pool), 1000e6);

        address user2 = address(new Address());

        vm.prank(user);
        pool.approve(user2, 1000e6);

        assertEq(pool.totalSupply(),          1_000e6);
        assertEq(pool.totalAssets(),          2_000e6);
        assertEq(pool.balanceOf(user),        1_000e6);
        assertEq(pool.allowance(user, user2), 1_000e6);
        assertEq(asset.balanceOf(user2),      0);

        vm.prank(user2);
        uint256 redeemAmount = pool.withdraw(1_000e6, user2, user);

        assertEq(redeemAmount, 500e6);

        MockPoolManager(address(poolManager)).__setTotalAssets(1_000e6);

        assertEq(pool.totalSupply(),          500e6);
        assertEq(pool.totalAssets(),          1_000e6);
        assertEq(pool.balanceOf(user),        500e6);
        assertEq(pool.allowance(user, user2), 500e6);
        assertEq(asset.balanceOf(user2),      1_000e6);
    }

}

contract PreviewDepositTests is PoolBase {

    function test_previewDeposit_initialState() public {
        _setupPool({ totalSupply_: 0, totalAssets_: 0, unrealizedLosses_: 0 });

        assertEq(pool.previewDeposit(0), 0);
        assertEq(pool.previewDeposit(1), 1);
        assertEq(pool.previewDeposit(2), 2);
    }

    function test_previewDeposit_worthlessShares() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 0, unrealizedLosses_: 0 });

        vm.expectRevert(ZERO_DIVISION);
        pool.previewDeposit(0);

        vm.expectRevert(ZERO_DIVISION);
        pool.previewDeposit(1);

        vm.expectRevert(ZERO_DIVISION);
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
        totalSupply_     = constrictToRange(totalSupply_,     0, 1e30);
        totalAssets_     = constrictToRange(totalAssets_,     0, 1e30);
        assetsToDeposit_ = constrictToRange(assetsToDeposit_, 0, 1e30);

        _setupPool({ totalSupply_: totalSupply_, totalAssets_: totalAssets_, unrealizedLosses_: 0 });

        if (totalSupply_ != 0 && totalAssets_ == 0) {
            vm.expectRevert(ZERO_DIVISION);
        }

        uint256 sharesToMint_ = pool.previewDeposit(assetsToDeposit_);

        if (totalSupply_ == 0) {
            assertEq(sharesToMint_, assetsToDeposit_);
        } else if (totalAssets_ != 0) {
            assertEq(sharesToMint_, assetsToDeposit_ * pool.totalSupply() / pool.totalAssets());
        }
    }

}

contract PreviewMintTests is PoolBase {

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
        totalSupply_  = constrictToRange(totalSupply_,  0, 1e30);
        totalAssets_  = constrictToRange(totalAssets_,  0, 1e30);
        sharesToMint_ = constrictToRange(sharesToMint_, 0, 1e30);

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

// contract PreviewRedeemTests is PoolBase {

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

// contract PreviewWithdrawTests is PoolBase {

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

contract ConvertToAssetsTests is PoolBase {

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
        totalSupply_     = constrictToRange(totalSupply_,     0, 1e30);
        totalAssets_     = constrictToRange(totalAssets_,     0, 1e30);
        sharesToConvert_ = constrictToRange(sharesToConvert_, 0, 1e30);

        _setupPool({ totalSupply_: totalSupply_, totalAssets_: totalAssets_, unrealizedLosses_: 0 });

        uint256 assets_ = pool.convertToAssets(sharesToConvert_);

        if (totalSupply_ == 0) {
            assertEq(assets_, sharesToConvert_);
        } else {
            assertEq(assets_, sharesToConvert_ * pool.totalAssets() / pool.totalSupply());
        }
    }
}

contract ConvertToSharesTests is PoolBase {

    function test_convertToShares_initialState() public {
        _setupPool({ totalSupply_: 0, totalAssets_: 0, unrealizedLosses_: 0 });

        assertEq(pool.convertToShares(0), 0);
        assertEq(pool.convertToShares(1), 1);
        assertEq(pool.convertToShares(2), 2);
    }

    function test_convertToShares_worthlessShares() public {
        _setupPool({ totalSupply_: 1, totalAssets_: 0, unrealizedLosses_: 0 });

        vm.expectRevert(ZERO_DIVISION);
        pool.convertToShares(0);

        vm.expectRevert(ZERO_DIVISION);
        pool.convertToShares(1);

        vm.expectRevert(ZERO_DIVISION);
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
        totalSupply_     = constrictToRange(totalSupply_,     0, 1e30);
        totalAssets_     = constrictToRange(totalAssets_,     0, 1e30);
        assetsToConvert_ = constrictToRange(assetsToConvert_, 0, 1e30);

        _setupPool({ totalSupply_: totalSupply_, totalAssets_: totalAssets_, unrealizedLosses_: 0 });

        if (totalSupply_ != 0 && totalAssets_ == 0) {
            vm.expectRevert(ZERO_DIVISION);
        }

        uint256 shares_ = pool.convertToShares(assetsToConvert_);

        if (totalSupply_ == 0) {
            assertEq(shares_, assetsToConvert_);
        } else if (totalAssets_ != 0) {
            assertEq(shares_, assetsToConvert_ * pool.totalSupply() / pool.totalAssets());
        }
    }

}

// TODO: Add tests comparing results of preview functions with results of the actual operation.
