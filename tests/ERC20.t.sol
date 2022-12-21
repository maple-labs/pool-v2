// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";

import { ERC20 }           from "../modules/erc20/contracts/ERC20.sol";
import { ERC20User }       from "../modules/erc20/contracts/test/accounts/ERC20User.sol";
import { ERC20BaseTest }   from "../modules/erc20/contracts/test/ERC20.t.sol";
import { ERC20PermitTest } from "../modules/erc20/contracts/test/ERC20.t.sol";
import { MockERC20 }       from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { IPoolManager }        from "../contracts/interfaces/IPoolManager.sol";
import { IPoolManagerFactory } from "../contracts/interfaces/IPoolManagerFactory.sol";

import { Pool } from "../contracts/Pool.sol";

import { MockERC20Pool, MockGlobals, MockPoolManager } from "./mocks/Mocks.sol";

contract Pool_ERC20TestBase {

    address pool;

    MockERC20 asset;

    function _setupPoolWithERC20() internal {
        asset = new MockERC20("Asset", "AT", 18);

        MockPoolManager poolManager = new MockPoolManager();

        poolManager.__setCanCall(true, "");

        pool = address(new MockERC20Pool(address(poolManager), address(asset), "Token", "TKN"));
    }

}

contract Pool_ERC20Test is ERC20BaseTest, Pool_ERC20TestBase {

    function setUp() override public {
        super.setUp();

        _setupPoolWithERC20();

        _token = MockERC20(pool);  // Pool does not contain `mint` and `burn` functions
    }

}

contract Pool_ERC20PermitTest is ERC20PermitTest, Pool_ERC20TestBase {

    function setUp() override public {
        super.setUp();

        _setupPoolWithERC20();

        _token = MockERC20(pool);  // Pool does not contain `mint` and `burn` functions
    }

    function test_domainSeparator() public override {
        assertEq(_token.DOMAIN_SEPARATOR(), 0x26450e8015bd7b9fa21048f5ff3a98f55954aa7364a274646e99f55efbfe5c69);
    }

}
