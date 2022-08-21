// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { LoanManager }            from "../contracts/LoanManager.sol";
import { LoanManagerFactory }     from "../contracts/proxy/LoanManagerFactory.sol";
import { LoanManagerInitializer } from "../contracts/proxy/LoanManagerInitializer.sol";

import { MockGlobals, MockPool } from "./mocks/Mocks.sol";

contract LoanManagerFactoryBase is TestUtils {

    address governor;
    address implementation;
    address initializer;

    MockGlobals globals;
    MockPool    pool;

    LoanManagerFactory factory;

    function setUp() public virtual {
        governor       = address(new Address());
        implementation = address(new LoanManager());
        initializer    = address(new LoanManagerInitializer());

        globals = new MockGlobals(governor);
        pool    = new MockPool();

        vm.startPrank(governor);
        factory = new LoanManagerFactory(address(globals));
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        MockGlobals(globals).setValidPoolDeployer(address(this), true);
    }

    function test_createInstance_notPoolDeployer() external {
        MockGlobals(globals).setValidPoolDeployer(address(this), false);
        vm.expectRevert("LMF:CI:NOT_DEPLOYER");
        LoanManager(factory.createInstance(abi.encode(address(pool)), "SALT"));

        MockGlobals(globals).setValidPoolDeployer(address(this), true);
        LoanManager(factory.createInstance(abi.encode(address(pool)), "SALT"));
    }

    function testFail_createInstance_notPool() external {
        factory.createInstance(abi.encode(address(1)), "SALT");
    }

    function testFail_createInstance_collision() external {
        factory.createInstance(abi.encode(address(pool)), "SALT");
        factory.createInstance(abi.encode(address(pool)), "SALT");
    }

    function test_createInstance_success() external {
        pool.__setAsset(address(1));
        pool.__setManager(address(2));

        LoanManager loanManager_ = LoanManager(factory.createInstance(abi.encode(address(pool)), "SALT"));

        assertEq(loanManager_.pool(),        address(pool));
        assertEq(loanManager_.fundsAsset(),  address(1));
        assertEq(loanManager_.poolManager(), address(2));
    }

}
