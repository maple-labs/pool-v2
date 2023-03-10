// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import { Pool }        from "../contracts/Pool.sol";
import { PoolManager } from "../contracts/PoolManager.sol";

import { MockGlobals } from "./mocks/Mocks.sol";

import { GlobalsBootstrapper } from "./bootstrap/GlobalsBootstrapper.sol";

contract PoolManagerFactoryBase is TestUtils, GlobalsBootstrapper {

    address internal PD = address(new Address());

    MockERC20          internal asset;
    PoolManagerFactory internal factory;

    address internal implementation;
    address internal initializer;

    function setUp() public virtual {
        asset = new MockERC20("Asset", "AT", 18);
        _deployAndBootstrapGlobals(address(asset), PD);

        factory = new PoolManagerFactory(address(globals));

        implementation = address(new PoolManager());
        initializer    = address(new PoolManagerInitializer());

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        MockGlobals(globals).setValidPoolDeployer(address(this), true);
    }

}

contract PoolManagerFactoryTest is PoolManagerFactoryBase {

    function test_createInstance() external {
        address migrationAdmin = address(new Address());

        uint256 bootstrapMint = 200;

        MockGlobals(globals).setMigrationAdmin(migrationAdmin);
        MockGlobals(globals).__setBootstrapMint(bootstrapMint);

        string memory name_   = "Pool";
        string memory symbol_ = "P2";

        uint256 initialSupply = 100;

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(PD, address(asset), initialSupply, name_, symbol_);

        address poolManagerAddress = PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(PD)));

        PoolManager poolManager = PoolManager(poolManagerAddress);

        assertEq(poolManager.factory(),        address(factory));
        assertEq(poolManager.implementation(), implementation);
        assertEq(poolManager.poolDelegate(),   PD);

        assertTrue(address(poolManager.pool()) != address(0));

        // Assert Pool was correctly initialized
        Pool pool = Pool(poolManager.pool());

        assertEq(pool.BOOTSTRAP_MINT(),          bootstrapMint);
        assertEq(pool.manager(),                 poolManagerAddress);
        assertEq(pool.asset(),                   address(asset));
        assertEq(pool.name(),                    name_);
        assertEq(pool.symbol(),                  symbol_);
        assertEq(pool.totalSupply(),             initialSupply);
        assertEq(pool.balanceOf(migrationAdmin), initialSupply);

        assertEq(asset.allowance(address(pool), poolManagerAddress), type(uint256).max);
    }

}

contract PoolManagerFactoryFailureTest is PoolManagerFactoryBase {

    function test_createInstance_notPoolDeployer() external {
        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(PD, address(asset), 0, "Pool", "P2");

        MockGlobals(globals).setValidPoolDeployer(address(this), false);
        vm.expectRevert("PMF:CI:NOT_DEPLOYER");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(PD)));

        MockGlobals(globals).setValidPoolDeployer(address(this), true);
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(PD)));
    }

    function test_createInstance_failWithZeroAddressPoolDelegate() external {
        address ZERO_PD = address(0);

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(ZERO_PD, address(asset), 0, "Pool", "P2");

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(PD)));
    }

    function test_createInstance_failWithInvalidPoolDelegate() external {
        address owner_ = address(2);

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(owner_), address(asset), 0, "Pool", "P2");

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(owner_)));
    }

    function test_createInstance_failWithActivePoolDelegate() external {
        MockGlobals(globals).__setOwnedPoolManager(PD, address(13));

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(PD, address(asset), 0, "Pool", "P2");

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(PD)));
    }

    function test_createInstance_failWithNonERC20Asset() external {
        address asset_ = address(2);

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(PD, asset_, 0, "Pool", "P2");

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(PD)));
    }

    function test_createInstance_failWithDisallowedAsset() external {
        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(PD, address(asset), 0, "Pool", "P2");

        MockGlobals(globals).setValidPoolAsset(address(asset), false);

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(PD)));
    }

    function test_createInstance_failWithZeroAdmin() external {
        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(PD, address(asset), 1, "Pool", "P2");

        vm.expectRevert("MPF:CI:FAILED");
        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(PD)));

        MockGlobals(globals).setMigrationAdmin(address(1));

        PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(PD)));
    }

}
