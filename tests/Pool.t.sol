// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                   from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { IPool } from "../contracts/interfaces/IPool.sol";

import { Pool }                   from "../contracts/Pool.sol";
import { PoolManager }            from "../contracts/PoolManager.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import {
    MockGlobals,
    MockReenteringERC20,
    MockRevertingERC20,
    MockPoolManager
} from "./mocks/Mocks.sol";

contract PoolBase is TestUtils {

    address POOL_DELEGATE = address(new Address());

    MockReenteringERC20 asset;
    MockGlobals         globals;
    Pool                pool;
    PoolManager         poolManager;
    PoolManagerFactory  factory;

    address implementation;
    address initializer;

    function setUp() public virtual {
        globals = new MockGlobals(address(this));
        factory = new PoolManagerFactory(address(globals));
        asset   = new MockReenteringERC20();

        implementation = address(new PoolManager());
        initializer    = address(new PoolManagerInitializer());

        globals.setValidPoolDelegate(POOL_DELEGATE, true);

        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "POOL1";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), POOL_DELEGATE, address(asset), poolName_, poolSymbol_);

        poolManager = PoolManager(PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(POOL_DELEGATE))));

        pool = Pool(poolManager.pool());
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

    function _openPool() public {
        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
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

}

contract ConstructorTests is PoolBase {

    function setUp() public override {}

    function test_constructor_zeroManager() public {
        address asset = address(new MockERC20("Asset", "AT", 18));

        vm.expectRevert("P:C:ZERO_ADDRESS");
        new Pool(address(0), asset, "Pool", "POOL1");

        new Pool(address(new Address()), asset, "Pool", "POOL1");
    }

    function test_constructor_invalidDecimals() public {
        address asset = address(new MockRevertingERC20("Asset", "AT", 18));
        MockRevertingERC20(asset).__setIsRevertingDecimals(true);

        address admin = address(new Address());

        vm.expectRevert("ERC20:D:REVERT");
        new Pool(admin, asset, "Pool", "POOL1");

        asset = address(new MockERC20("Asset", "AT", 18));
        new Pool(admin, asset, "Pool", "POOL1");
    }

    function test_constructor_invalidApproval() public {
        address asset = address(new MockRevertingERC20("Asset", "AT", 18));
        MockRevertingERC20(asset).__setIsRevertingApprove(true);

        address admin = address(new Address());

        vm.expectRevert("ERC20:A:REVERT");
        new Pool(admin, asset, "Pool", "POOL1");

        asset = address(new MockERC20("Asset", "AT", 18));
        new Pool(admin, asset, "Pool", "POOL1");
    }

}

contract DepositTests is PoolBase {

    uint256 DEPOSIT_AMOUNT = 1e18;

    function setUp() public override {
        super.setUp();
        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);
    }

    function test_deposit_notOpenToPublic() public {
        asset.mint(address(this),    DEPOSIT_AMOUNT);
        asset.approve(address(pool), DEPOSIT_AMOUNT);

        vm.expectRevert("P:D:LENDER_NOT_ALLOWED");
        pool.deposit(DEPOSIT_AMOUNT, address(this));

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        pool.deposit(DEPOSIT_AMOUNT, address(this));
    }

    function test_deposit_notAllowed() public {
        asset.mint(address(this),    DEPOSIT_AMOUNT);
        asset.approve(address(pool), DEPOSIT_AMOUNT);

        vm.expectRevert("P:D:LENDER_NOT_ALLOWED");
        pool.deposit(DEPOSIT_AMOUNT, address(this));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(address(this), true);

        pool.deposit(DEPOSIT_AMOUNT, address(this));
    }

    function testFuzz_deposit_aboveLiquidityCap(uint256 depositAmount_) public {
        _openPool();

        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);

        asset.mint(address(this),    depositAmount_);
        asset.approve(address(pool), depositAmount_);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(depositAmount_ - 1);

        vm.expectRevert("P:D:DEPOSIT_GT_LIQ_CAP");
        pool.deposit(depositAmount_, address(this));
    }

    function test_deposit_zeroReceiver() public {
        _openPool();

        asset.mint(address(this),    DEPOSIT_AMOUNT);
        asset.approve(address(pool), DEPOSIT_AMOUNT);

        vm.expectRevert("P:M:ZERO_RECEIVER");
        pool.deposit(DEPOSIT_AMOUNT, address(0));
    }

    function test_deposit_zeroShares() public {
        _openPool();

        asset.mint(address(this),    DEPOSIT_AMOUNT);
        asset.approve(address(pool), DEPOSIT_AMOUNT);

        vm.expectRevert("P:M:ZERO_SHARES");
        pool.deposit(0, address(this));
    }

    function testFuzz_deposit_badApprove(uint256 depositAmount_) public {
        _openPool();

        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);

        asset.mint(address(this),    depositAmount_);
        asset.approve(address(pool), depositAmount_ - 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.deposit(depositAmount_, address(this));
    }

    function testFuzz_deposit_insufficientBalance(uint256 depositAmount_) public {
        _openPool();

        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);

        asset.mint(address(this),    depositAmount_);
        asset.approve(address(pool), depositAmount_ + 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.deposit(depositAmount_ + 1, address(this));
    }

    function test_deposit_reentrancy() public {
        _openPool();

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
        poolManager.setLiquidityCap(type(uint256).max);
    }

    function test_depositWithPermit_notOpenToPublic() public {
        asset.mint(STAKER, DEPOSIT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:DWP:LENDER_NOT_ALLOWED");
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        vm.prank(STAKER);
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_notAllowed() public {
        asset.mint(STAKER, DEPOSIT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:DWP:LENDER_NOT_ALLOWED");
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(STAKER, true);

        vm.prank(STAKER);
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);
    }

    function testFuzz_depositWithPermit_aboveLiquidityCap(uint256 depositAmount_) public {
        _openPool();

        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);

        asset.mint(STAKER, depositAmount_);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), depositAmount_, NONCE, DEADLINE, STAKER_SK);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(depositAmount_ - 1);

        vm.prank(STAKER);
        vm.expectRevert("P:DWP:DEPOSIT_GT_LIQ_CAP");
        pool.depositWithPermit(depositAmount_, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_zeroAddress() public {
        _openPool();

        asset.mint(STAKER, DEPOSIT_AMOUNT);

        ( , bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:MALLEABLE"));
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, 17, r, s);
    }

    function test_depositWithPermit_notStakerSignature() public {
        _openPool();

        asset.mint(STAKER, DEPOSIT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(NOT_STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, NOT_STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_pastDeadline() public {
        _openPool();

        asset.mint(STAKER, DEPOSIT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.warp(DEADLINE + 1);

        vm.expectRevert(bytes("ERC20:P:EXPIRED"));
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_replay() public {
        _openPool();

        asset.mint(STAKER, DEPOSIT_AMOUNT * 2);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_badNonce() public {
        _openPool();

        asset.mint(STAKER, DEPOSIT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), DEPOSIT_AMOUNT, NONCE + 1, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.depositWithPermit(DEPOSIT_AMOUNT, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_zeroReceiver() public {
        _openPool();

        asset.mint(STAKER, 1);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 1, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:M:ZERO_RECEIVER");
        pool.depositWithPermit(1, address(0), DEADLINE, v, r, s);
    }

    function test_depositWithPermit_zeroShares() public {
        _openPool();

        asset.mint(STAKER, 1);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 0, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:M:ZERO_SHARES");
        pool.depositWithPermit(0, STAKER, DEADLINE, v, r, s);
    }

    function testFuzz_depositWithPermit_insufficientBalance(uint256 depositAmount_) public {
        _openPool();

        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);
        asset.mint(STAKER, depositAmount_);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), depositAmount_ + 1, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.depositWithPermit(depositAmount_ + 1, STAKER, DEADLINE, v, r, s);
    }

    function test_depositWithPermit_reentrancy() public {
        _openPool();

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

    function setUp() public override {
        super.setUp();
        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);
    }

    function test_mint_notOpenToPublic() public {
        asset.mint(address(this),    MINT_AMOUNT);
        asset.approve(address(pool), MINT_AMOUNT);

        vm.expectRevert("P:M:LENDER_NOT_ALLOWED");
        pool.mint(MINT_AMOUNT, address(this));

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        pool.mint(MINT_AMOUNT, address(this));
    }

    function test_mint_notAllowed() public {
        asset.mint(address(this),    MINT_AMOUNT);
        asset.approve(address(pool), MINT_AMOUNT);

        vm.expectRevert("P:M:LENDER_NOT_ALLOWED");
        pool.mint(MINT_AMOUNT, address(this));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(address(this), true);

        pool.mint(MINT_AMOUNT, address(this));
    }

    function testFuzz_mint_aboveLiquidityCap(uint256 mintAmount_) public {
        _openPool();

        mintAmount_ = constrictToRange(mintAmount_, 1, 1e29);

        asset.mint(address(this),    mintAmount_);
        asset.approve(address(pool), mintAmount_);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(mintAmount_ - 1);

        vm.expectRevert("P:M:DEPOSIT_GT_LIQ_CAP");
        pool.mint(mintAmount_, address(this));
    }

    function test_mint_zeroReceiver() public {
        _openPool();

        asset.mint(address(this),    MINT_AMOUNT);
        asset.approve(address(pool), MINT_AMOUNT);

        vm.expectRevert("P:M:ZERO_RECEIVER");
        pool.mint(MINT_AMOUNT, address(0));
    }

    function test_mint_zeroShares() public {
        _openPool();

        asset.mint(address(this),    MINT_AMOUNT);
        asset.approve(address(pool), MINT_AMOUNT);

        vm.expectRevert("P:M:ZERO_SHARES");
        pool.mint(0, address(this));
    }

    function testFuzz_mint_badApprove(uint256 mintAmount_) public {
        _openPool();

        mintAmount_ = constrictToRange(mintAmount_, 1, 1e29);

        asset.mint(address(this),    mintAmount_);
        asset.approve(address(pool), mintAmount_ - 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.mint(mintAmount_, address(this));
    }

    function testFuzz_mint_insufficientBalance(uint256 mintAmount_) public {
        _openPool();

        mintAmount_ = constrictToRange(mintAmount_, 1, 1e29);

        asset.mint(address(this),    mintAmount_);
        asset.approve(address(pool), mintAmount_ + 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.mint(mintAmount_ + 1, address(this));
    }

    function test_mint_reentrancy() public {
        _openPool();

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

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);
    }

    function test_mintWithPermit_insufficientPermit() public {
        _openPool();

        asset.mint(STAKER, 1);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 0, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:MWP:INSUFFICIENT_PERMIT");
        pool.mintWithPermit(1, STAKER, 0, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_notOpenToPublic() public {
        asset.mint(STAKER, MINT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:MWP:LENDER_NOT_ALLOWED");
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        vm.prank(STAKER);
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_notAllowed() public {
        asset.mint(STAKER, MINT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:MWP:LENDER_NOT_ALLOWED");
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(STAKER, true);

        vm.prank(STAKER);
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function testFuzz_mintWithPermit_aboveLiquidityCap(uint256 mintAmount_) public {
        _openPool();

        mintAmount_ = constrictToRange(mintAmount_, 1, 1e29);

        asset.mint(STAKER, mintAmount_);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, STAKER_SK);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(mintAmount_ - 1);

        vm.prank(STAKER);
        vm.expectRevert("P:MWP:DEPOSIT_GT_LIQ_CAP");
        pool.mintWithPermit(mintAmount_, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_zeroAddress() public {
        _openPool();

        asset.mint(STAKER, MINT_AMOUNT);

        ( , bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:MALLEABLE"));
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, 17, r, s);
    }

    function test_mintWithPermit_notStakerSignature() public {
        _openPool();

        asset.mint(STAKER, MINT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(NOT_STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, NOT_STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_pastDeadline() public {
        _openPool();

        asset.mint(STAKER, MINT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.warp(DEADLINE + 1);

        vm.expectRevert(bytes("ERC20:P:EXPIRED"));
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_replay() public {
        _openPool();

        asset.mint(STAKER, MINT_AMOUNT * 2);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_badNonce() public {
        _openPool();

        asset.mint(STAKER, MINT_AMOUNT);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), MAX_ASSETS, NONCE + 1, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);

        vm.expectRevert(bytes("ERC20:P:INVALID_SIGNATURE"));
        pool.mintWithPermit(MINT_AMOUNT, STAKER, MAX_ASSETS, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_zeroReceiver() public {
        _openPool();

        asset.mint(STAKER, 1);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 1, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);
        vm.expectRevert("P:M:ZERO_RECEIVER");
        pool.mintWithPermit(1, address(0), 1, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_zeroShares() public {
        _openPool();

        asset.mint(STAKER, 1);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), 1, NONCE, DEADLINE, STAKER_SK);

        vm.startPrank(STAKER);
        vm.expectRevert("P:M:ZERO_SHARES");
        pool.mintWithPermit(0, STAKER, 1, DEADLINE, v, r, s);
    }

    function testFuzz_mintWithPermit_insufficientBalance(uint256 mintAmount_) public {
        _openPool();

        mintAmount_ = constrictToRange(mintAmount_, 1, 1e29);
        asset.mint(STAKER, mintAmount_);

        ( uint8 v, bytes32 r, bytes32 s ) = _getValidPermitSignature(STAKER, address(pool), mintAmount_ + 1, NONCE, DEADLINE, STAKER_SK);

        vm.prank(STAKER);
        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.mintWithPermit(mintAmount_ + 1, STAKER, mintAmount_ + 1, DEADLINE, v, r, s);
    }

    function test_mintWithPermit_reentrancy() public {
        _openPool();

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

    // TODO: Should be tested in similar manner to mint.

}

contract TransferTests is PoolBase {

    address RECIPIENT = address(new Address());

    uint256 TRANSFER_AMOUNT = 1e18;

    function setUp() public override {
        super.setUp();

        vm.startPrank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);
        poolManager.setAllowedLender(address(this), true);
        vm.stopPrank();

        asset.mint(address(this),    TRANSFER_AMOUNT);
        asset.approve(address(pool), TRANSFER_AMOUNT);

        pool.deposit(TRANSFER_AMOUNT, address(this));
    }

    function test_transfer_notOpenToPublic() public {
        vm.expectRevert("P:T:RECIPIENT_NOT_ALLOWED");
        pool.transfer(RECIPIENT, TRANSFER_AMOUNT);

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        pool.transfer(RECIPIENT, TRANSFER_AMOUNT);
    }

    function test_transfer_recipientNotAllowed() public {
        vm.expectRevert("P:T:RECIPIENT_NOT_ALLOWED");
        pool.transfer(RECIPIENT, TRANSFER_AMOUNT);

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(RECIPIENT, true);

        pool.transfer(RECIPIENT, TRANSFER_AMOUNT);
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

        vm.startPrank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);
        poolManager.setAllowedLender(OWNER, true);
        vm.stopPrank();

        vm.startPrank(OWNER);

        asset.mint(OWNER,            TRANSFER_AMOUNT);
        asset.approve(address(pool), TRANSFER_AMOUNT);

        pool.deposit(TRANSFER_AMOUNT, OWNER);
        pool.approve(address(this), type(uint256).max);

        vm.stopPrank();
    }

    function test_transfer_notOpenToPublic() public {
        vm.expectRevert("P:TF:RECIPIENT_NOT_ALLOWED");
        pool.transferFrom(OWNER, RECIPIENT, TRANSFER_AMOUNT);

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        pool.transferFrom(OWNER, RECIPIENT, TRANSFER_AMOUNT);
    }

    function test_transfer_recipientNotAllowed() public {
        vm.expectRevert("P:TF:RECIPIENT_NOT_ALLOWED");
        pool.transferFrom(OWNER, RECIPIENT, TRANSFER_AMOUNT);

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(RECIPIENT, true);

        pool.transferFrom(OWNER, RECIPIENT, TRANSFER_AMOUNT);
    }

    function testFuzz_transferFrom_success() public {
        // TODO: Generic fuzz test.
    }

}

contract WithdrawTests is PoolBase {

    address user;

    function setUp() public override {
        super.setUp();

        // Replace manager with mock.
        address mockPoolManager = address(new MockPoolManager());
        vm.etch(address(poolManager), mockPoolManager.code);

        user = address(new Address());
    }

    // TODO: Update reentrancy tests, these are the wrong failure messages.
    function test_withdraw_reentrancy() external {
        uint256 depositAmount_ = 1_000e6;
        _deposit(address(pool), address(poolManager), user, depositAmount_);

        vm.prank(user);
        pool.approve(address(poolManager), depositAmount_);
        asset.setReentrancy(address(pool));

        vm.startPrank(address(poolManager));
        vm.expectRevert("P:B:TRANSFER");
        pool.withdraw(depositAmount_, user, user);
        vm.stopPrank();

        asset.setReentrancy(address(0));
        vm.prank(address(poolManager));
        pool.withdraw(depositAmount_, user, user);
    }

    function test_withdraw_notManager() external {
        uint256 depositAmount_ = 1_000e6;
        _deposit(address(pool), address(poolManager), user, depositAmount_);

        vm.prank(user);
        pool.approve(address(poolManager), depositAmount_);

        vm.expectRevert("P:W:NOT_MANAGER");
        pool.withdraw(depositAmount_, user, user);
    }

    function test_withdraw_zeroShares() external {
        uint256 depositAmount_ = 1_000e6;
        _deposit(address(pool), address(poolManager), user, depositAmount_);

        vm.prank(user);
        pool.approve(address(poolManager), depositAmount_);

        vm.prank(address(poolManager));
        vm.expectRevert("P:B:ZERO_SHARES");
        pool.withdraw(0, user, user);
    }

    function test_withdraw_badApprove() external {
        uint256 depositAmount_ = 1_000e6;
        _deposit(address(pool), address(poolManager), user, depositAmount_);

        vm.prank(address(poolManager));
        vm.expectRevert(ARITHMETIC_ERROR);
        pool.withdraw(depositAmount_, user, user);
    }

    function test_withdraw_insufficientApprove() external {
        uint256 depositAmount_ = 1_000e6;
        _deposit(address(pool), address(poolManager), user, depositAmount_);

        vm.prank(user);
        pool.approve(address(poolManager), depositAmount_ - 1);

        vm.prank(address(poolManager));
        vm.expectRevert(ARITHMETIC_ERROR);
        pool.withdraw(depositAmount_, user, user);
    }

    function test_withdraw_insufficientAmount() external {
        uint256 depositAmount_ = 1_000e6;
        _deposit(address(pool), address(poolManager), user, depositAmount_);

        vm.prank(user);
        pool.approve(address(poolManager), depositAmount_);

        vm.prank(address(poolManager));
        vm.expectRevert(ARITHMETIC_ERROR);
        pool.withdraw(depositAmount_ + 1, user, user);
    }

    function test_withdraw_insufficientAmount_unrealizedLosses() external {
        uint256 depositAmount_ = 1_000e6;
        _deposit(address(pool), address(poolManager), user, depositAmount_);

        vm.prank(user);
        pool.approve(address(poolManager), depositAmount_);

        uint256 unrealizedLosses_ = depositAmount_ / 2;
        MockPoolManager(address(poolManager)).__setUnrealizedLosses(unrealizedLosses_);

        uint256 withdrawAmount_ = unrealizedLosses_;

        vm.prank(address(poolManager));
        vm.expectRevert(ARITHMETIC_ERROR);
        pool.withdraw(withdrawAmount_ + 1, user, user);
    }

    function test_withdraw_success() external {
        uint256 depositAmount_ = 1_000e6;
        _deposit(address(pool), address(poolManager), user, depositAmount_);

        // Add extra assets to the pool.
        MockPoolManager(address(poolManager)).__setTotalAssets(2_000e6);
        asset.mint(address(pool), 1000e6);

        vm.prank(user);
        pool.approve(address(poolManager), depositAmount_);

        assertEq(pool.totalSupply(),                         1_000e6);
        assertEq(pool.totalAssets(),                         2_000e6);
        assertEq(pool.totalAssetsWithUnrealizedLosses(),     2_000e6);
        assertEq(pool.balanceOf(user),                       1_000e6);
        assertEq(pool.allowance(user, address(poolManager)), 1_000e6);
        assertEq(asset.balanceOf(user),                      0);

        vm.prank(address(poolManager));
        pool.withdraw(1_000e6, user, user);
        MockPoolManager(address(poolManager)).__setTotalAssets(1_000e6);

        assertEq(pool.totalSupply(),                         500e6);
        assertEq(pool.totalAssets(),                         1_000e6);
        assertEq(pool.totalAssetsWithUnrealizedLosses(),     1_000e6);
        assertEq(pool.balanceOf(user),                       500e6);
        assertEq(pool.allowance(user, address(poolManager)), 500e6);
        assertEq(asset.balanceOf(user),                      1_000e6);
    }

}

contract PreviewDepositTests is PoolBase {

    function testFuzz_previewDeposit_success() public {
        // TODO: Check conversion and rounding works correctly.
    }

}

contract PreviewMintTests is PoolBase {

    function testFuzz_previewMint_success() public {
        // TODO: Check conversion and rounding works correctly.
    }

}

contract PreviewRedeemTests is PoolBase {

    function testFuzz_previewRedeem_success() public {
        // TODO: Check conversion and rounding works correctly.
    }

}

contract PreviewWithdrawTests is PoolBase {

    function testFuzz_previewWithdraw_success() public {
        // TODO: Check conversion and rounding works correctly.
    }

}
