// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import { ERC20BaseTest } from "../modules/erc20/contracts/test/ERC20.t.sol";
import { ERC20PermitTest } from "../modules/erc20/contracts/test/ERC20.t.sol";
import { MockERC20 } from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { MockERC20Pool, MockPoolManager } from "./utils/Mocks.sol";

contract Pool_ERC20TestBase {

    address internal pool;

    MockERC20 internal asset;

    function _setupPoolWithERC20() internal {
        asset = new MockERC20("Asset", "AT", 18);

        MockPoolManager poolManager = new MockPoolManager();

        poolManager.__setCanCall(true, "");

        pool = address(new MockERC20Pool(address(poolManager), address(asset), "Token", "TKN"));
    }

}

contract Pool_ERC20Test is ERC20BaseTest, Pool_ERC20TestBase {

    function setUp() public override {
        super.setUp();

        _setupPoolWithERC20();

        _token = MockERC20(pool); // Pool does not contain `mint` and `burn` functions
    }

}

contract Pool_ERC20PermitTest is ERC20PermitTest, Pool_ERC20TestBase {

    function setUp() public override {
        super.setUp();

        _setupPoolWithERC20();

        _token = MockERC20(pool); // Pool does not contain `mint` and `burn` functions
    }

    function test_domainSeparator() public override {
        assertEq(_token.DOMAIN_SEPARATOR(), 0xe0dff6fbb8f5eaff9256159b12a6d15330ab3f89be7a9bf5d6e2a580ac6bbb9a);
    }

}
