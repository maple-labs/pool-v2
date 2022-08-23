// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { console, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }          from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

contract PoolBase is TestUtils {

    function test_log_values() public {
        console.log("type(uint256).max", type(uint256).max);
        console.log("type(uint16).max", type(uint16).max);
        console.log("type(uint24).max", type(uint24).max);
        console.log("type(uint32).max", type(uint32).max);
        console.log("type(uint64).max", type(uint64).max);
        console.log("type(uint88).max", type(uint88).max);
        console.log("type(uint112).max", type(uint112).max);
        console.log("type(uint120).max", type(uint120).max);
        console.log("type(uint128).max", type(uint128).max);
        console.log("type(uint208).max", type(uint208).max);
    }
}

