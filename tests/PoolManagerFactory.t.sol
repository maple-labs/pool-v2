// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                   from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import { Pool }        from "../contracts/Pool.sol";
import { PoolManager } from "../contracts/PoolManager.sol";

import { MockGlobals } from "./mocks/Mocks.sol";

contract PoolManagerFactoryBase is TestUtils {

    address ADMIN = address(new Address());

    MockERC20          asset;
    MockGlobals        globals;
    PoolManagerFactory factory;

    address implementation;
    address initializer;

    function setUp() external {
        globals = new MockGlobals(address(this));
        factory = new PoolManagerFactory(address(globals));
        asset   = new MockERC20("Asset", "AT", 18);

        implementation = address(new PoolManager());
        initializer    = address(new PoolManagerInitializer());

        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
    }

}

contract PoolManagerFactoryTest is PoolManagerFactoryBase {

    function test_createInstance() external {
        string memory name_   = "Pool";
        string memory symbol_ = "P2";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), ADMIN, address(asset), name_, symbol_);

        address poolManagerAddress = PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(ADMIN)));

        PoolManager poolManager = PoolManager(poolManagerAddress);

        assertEq(poolManager.factory(),        address(factory));
        assertEq(poolManager.implementation(), implementation);
        assertEq(poolManager.globals(),        address(globals));
        assertEq(poolManager.admin(),          ADMIN);

        assertTrue(address(poolManager.pool()) != address(0));

        // Assert Pool was correctly initialized
        Pool pool = Pool(poolManager.pool());

        assertEq(pool.manager(), poolManagerAddress);
        assertEq(pool.asset(),   address(asset));
        assertEq(pool.name(),    name_);
        assertEq(pool.symbol(),  symbol_);

        assertEq(asset.allowance(address(pool), poolManagerAddress), type(uint256).max);
    }

}

contract PoolManagerFactoryFailureTest is PoolManagerFactoryBase {

    function test_createInstance_failWithZeroAddressAdmin() external {
        address ZERO_ADMIN = address(0);

        string memory name_   = "Pool";
        string memory symbol_ = "P2";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), ZERO_ADMIN, address(asset), name_, symbol_);

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(ADMIN)));
    }

    function test_createInstance_failWithZeroGlobals() external {
        string memory name_   = "Pool";
        string memory symbol_ = "P2";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(0), ADMIN, address(asset), name_, symbol_);

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(ADMIN)));
    }

    function test_createInstance_failWithNonERC20Asset() external {
        address asset_        = address(2);
        string memory name_   = "Pool";
        string memory symbol_ = "P2";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), ADMIN, asset_, name_, symbol_);

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(ADMIN)));
    }

}
