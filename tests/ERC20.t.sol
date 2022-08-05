// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";

import { ERC20 }           from "../modules/erc20/contracts/ERC20.sol";
import { ERC20User }       from "../modules/erc20/contracts/test/accounts/ERC20User.sol";
import { ERC20BaseTest }   from "../modules/erc20/contracts/test/ERC20.t.sol";
import { ERC20PermitTest } from "../modules/erc20/contracts/test/ERC20.t.sol";
import { MockERC20 }       from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolManager }            from "../contracts/PoolManager.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import { ConstructablePoolManager, MockERC20Pool, MockGlobals } from "./mocks/Mocks.sol";

// TODO: Investigate using GlobalsBootstrapper for this base, there's an inheritance issue, most likely due to a different version of TestUtils being used in ERC20 module
contract Pool_ERC20TestBase {

    address POOL_DELEGATE = address(new Address());

    MockERC20          asset;
    MockERC20Pool      pool;
    MockGlobals        globals;
    PoolManager        poolManager;
    PoolManagerFactory factory;

    function _setupPoolWithERC20() internal {
        asset       = new MockERC20("Asset", "AT", 18);
        globals     = new MockGlobals(address(this));
        poolManager = new ConstructablePoolManager(address(globals), POOL_DELEGATE, address(asset));
        pool        = new MockERC20Pool(address(poolManager), address(asset), "Pool", "POOL1");
    }

}

contract Pool_ERC20Test is ERC20BaseTest, Pool_ERC20TestBase {

    function setUp() override public {
        super.setUp();

        _setupPoolWithERC20();

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        _token = MockERC20(address(pool));  // Pool does not contain `mint` and `burn` functions
    }

}

contract Pool_ERC20PermitTest is ERC20PermitTest, Pool_ERC20TestBase {

    function setUp() override public {
        super.setUp();

        _setupPoolWithERC20();

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        _token = MockERC20(poolManager.pool());  // Pool does not contain `mint` and `burn` functions
    }

    function test_domainSeparator() public override {
        assertEq(_token.DOMAIN_SEPARATOR(), 0x3f755d8ef1a1b85565f0b1f2101d5f21e141daf9df1e2dfc2693c2c62f2a5d27);
    }

}
