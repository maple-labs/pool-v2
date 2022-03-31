// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { RevenueDistributionToken as RDT } from "../modules/revenue-distribution-token/contracts/RevenueDistributionToken.sol";
import { Staker }                          from "../modules/revenue-distribution-token/contracts/test/accounts/Staker.sol";
import { MockERC20 }                       from "../modules/revenue-distribution-token/modules/erc20/contracts/test/mocks/MockERC20.sol";

import {
    AuthTests,
    ConstructorTest,
    DepositFailureTests,
    DepositTests,
    DepositWithPermitFailureTests,
    DepositWithPermitTests,
    EndToEndRevenueStreamingTests,
    MintFailureTests,
    MintTests,
    MintWithPermitFailureTests,
    MintWithPermitTests,
    RedeemCallerNotOwnerTests,
    RedeemFailureTests,
    RedeemRevertOnTransfers,
    RedeemTests,
    RevenueStreamingTests,
    WithdrawCallerNotOwnerTests,
    WithdrawFailureTests,
    WithdrawRevertOnTransfers,
    WithdrawTests
} from "../modules/revenue-distribution-token/contracts/test/RevenueDistributionToken.t.sol";

import { PoolV2 } from "../contracts/PoolV2.sol";

contract PoolV2_RDT_AuthTests is AuthTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(owner), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_ConstructorTest is ConstructorTest { }

contract PoolV2_RDT_DepositFailureTests is DepositFailureTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_DepositTests is DepositTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_DepositWithPermitFailureTests is DepositWithPermitFailureTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_DepositWithPermitTests is DepositWithPermitTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_EndToEndRevenueStreamingTests is EndToEndRevenueStreamingTests {

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

contract PoolV2_RDT_MintTests is MintTests {

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

contract PoolV2_RDT_MintWithPermitTests is MintWithPermitTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_RedeemCallerNotOwnerTests is RedeemCallerNotOwnerTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_RedeemFailureTests is RedeemFailureTests {

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

contract PoolV2_RDT_RedeemTests is RedeemTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_RevenueStreamingTests is RevenueStreamingTests {

    function setUp() override public {
        super.setUp();

        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));

        // Deposit the minimum amount of the asset to allow the vesting schedule updates to occur.
        asset.mint(address(firstStaker), startingAssets);

        firstStaker.erc20_approve(address(asset), address(rdToken), startingAssets);
        firstStaker.rdToken_deposit(address(rdToken), startingAssets);
    }

}

contract PoolV2_RDT_WithdrawCallerNotOwnerTests is WithdrawCallerNotOwnerTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_WithdrawFailureTests is WithdrawFailureTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}

contract PoolV2_RDT_WithdrawRevertOnTransfers is WithdrawRevertOnTransfers {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(revertingAsset), 1e30)));
    }

}

contract PoolV2_RDT_WithdrawTests is WithdrawTests {

    function setUp() override public {
        super.setUp();
        rdToken = RDT(address(new PoolV2("Token", "TKN", address(this), address(asset), 1e30)));
    }

}
