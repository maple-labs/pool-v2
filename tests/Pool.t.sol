// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                   from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { Pool }                   from "../contracts/Pool.sol";
import { PoolManager }            from "../contracts/PoolManager.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import { MockGlobals } from "./mocks/Mocks.sol";

contract PoolBase is TestUtils {

    address POOL_DELEGATE = address(new Address());

    MockERC20          asset;
    MockGlobals        globals;
    Pool               pool;
    PoolManager        poolManager;
    PoolManagerFactory factory;

    address implementation;
    address initializer;

    function setUp() public virtual {
        globals = new MockGlobals(address(this));
        factory = new PoolManagerFactory(address(globals));
        asset   = new MockERC20("Asset", "AT", 18);

        implementation = address(new PoolManager());
        initializer    = address(new PoolManagerInitializer());

        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "POOL1";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), POOL_DELEGATE, address(asset), poolName_, poolSymbol_);

        poolManager = PoolManager(PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(POOL_DELEGATE))));

        pool = Pool(poolManager.pool());
    }

}

contract DepositFailureTests is PoolBase {

    function setUp() public override {
        super.setUp();
        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);
    }

    function test_deposit_zeroReceiver() public {
        asset.mint(address(this),    1);
        asset.approve(address(pool), 1);

        vm.expectRevert("P:M:ZERO_RECEIVER");
        pool.deposit(1, address(0));

        pool.deposit(1, address(this));
    }

    function test_deposit_zeroAssets() public {
        asset.mint(address(this),    1);
        asset.approve(address(pool), 1);

        vm.expectRevert("P:M:ZERO_SHARES");
        pool.deposit(0, address(this));

        pool.deposit(1, address(this));
    }

    function test_deposit_badApprove(uint256 depositAmount_) public {
        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);

        asset.mint(address(this),    depositAmount_);
        asset.approve(address(pool), depositAmount_ - 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.deposit(depositAmount_, address(this));

        asset.approve(address(pool), depositAmount_);
        pool.deposit(depositAmount_, address(this));
    }

    function test_deposit_insufficientBalance(uint256 depositAmount_) public {
        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);

        asset.mint(address(this),    depositAmount_);
        asset.approve(address(pool), depositAmount_ + 1);

        vm.expectRevert("P:M:TRANSFER_FROM");
        pool.deposit(depositAmount_ + 1, address(this));

        asset.approve(address(pool), depositAmount_);
        pool.deposit(depositAmount_, address(this));
    }

    function test_deposit_zeroShares() public {
        // TODO: Use __setTotalAssets for this
    }

    function test_deposit_aboveLiquidityCap(uint256 depositAmount_) public {
        depositAmount_ = constrictToRange(depositAmount_, 1, 1e29);

        asset.mint(address(this),    depositAmount_);
        asset.approve(address(pool), depositAmount_);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(depositAmount_ - 1);

        vm.expectRevert("P:D:DEPOSIT_GT_LIQ_CAP");
        pool.deposit(depositAmount_, address(this));
    }

}
