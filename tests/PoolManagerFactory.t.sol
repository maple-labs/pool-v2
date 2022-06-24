// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";
import { TestUtils } from "../modules/contract-test-utils/contracts/test.sol";

import { Pool }                   from "../contracts/Pool.sol";
import { PoolManager }            from "../contracts/PoolManager.sol";
import { PoolManagerFactory }     from "../contracts/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/PoolManagerInitializer.sol";

import { MockGlobals } from "./mocks/Mocks.sol";

contract PoolManagerFactoryBase is TestUtils {

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
        address owner_     = address(1);
        uint256 precision_ = uint256(9);

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "P2";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), owner_, address(asset), precision_, poolName_, poolSymbol_);

        address poolManagerAddress = PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(owner_)));

        PoolManager poolManager = PoolManager(poolManagerAddress); 

        assertEq(poolManager.factory(),        address(factory));
        assertEq(poolManager.implementation(), implementation);
        assertEq(poolManager.globals(),        address(globals));
        assertEq(poolManager.owner(),          owner_);
        assertEq(poolManager.precision(),      precision_);
        
        assertTrue(address(poolManager.pool()) != address(0));

        // Assert Pool was correctly initialized
        Pool pool = Pool(poolManager.pool());

        assertEq(pool.manager(), poolManagerAddress);
        assertEq(pool.asset(),   address(asset));
        assertEq(pool.name(),    poolName_);
        assertEq(pool.symbol(),  poolSymbol_);

        assertEq(asset.allowance(address(pool), poolManagerAddress), type(uint256).max); 
    }

}

contract PoolManagerFactoryFailureTest is PoolManagerFactoryBase {

    function test_createInstance_failWithZeroAddressOwner() external {
        address owner_     = address(0);
        uint256 precision_ = uint256(9);

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "P2";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), owner_, address(asset), precision_, poolName_, poolSymbol_);

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(owner_)));
    }

    function test_createInstance_failWithZeroGlobals() external {
        address owner_     = address(1);
        uint256 precision_ = uint256(9);

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "P2";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(0), owner_, address(asset), precision_, poolName_, poolSymbol_);

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(owner_)));
    }

    function test_createInstance_failWithNonERC20Asset() external {
        address owner_     = address(1);
        address asset_     = address(2);
        uint256 precision_ = uint256(9);

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "P2";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), owner_, asset_, precision_, poolName_, poolSymbol_);

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(owner_)));
    }

}
