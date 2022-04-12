// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { RevenueDistributionToken as RDT } from "../modules/revenue-distribution-token/contracts/RevenueDistributionToken.sol";
import { Staker }                          from "../modules/revenue-distribution-token/contracts/test/accounts/Staker.sol";
import { MockERC20 }                       from "../modules/revenue-distribution-token/modules/erc20/contracts/test/mocks/MockERC20.sol";

import {
    ConstructorTest,
    DepositWithPermitFailureTests,
    MintFailureTests,
    MintWithPermitFailureTests,
    RedeemRevertOnTransfers,
    WithdrawRevertOnTransfers
} from "../modules/revenue-distribution-token/contracts/test/RevenueDistributionToken.t.sol";

import { PoolV2 } from "../contracts/PoolV2.sol";

contract PoolV2_RDT_ConstructorTest is ConstructorTest { }

contract PoolV2_RDT_DepositWithPermitFailureTests is DepositWithPermitFailureTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_MintFailureTests is MintFailureTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_MintWithPermitFailureTests is MintWithPermitFailureTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_RedeemRevertOnTransfers is RedeemRevertOnTransfers {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(revertingAsset), 1e30)));
    }

}

contract PoolV2_RDT_WithdrawRevertOnTransfers is WithdrawRevertOnTransfers {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(revertingAsset), 1e30)));
    }

}
