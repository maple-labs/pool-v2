// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils } from "../../modules/contract-test-utils/contracts/test.sol";

import { MockGlobals } from "../mocks/Mocks.sol";

/**
 *  @dev Used to setup the MockGlobals contract for test contracts.
 */
contract GlobalsBootstrapper is TestUtils {

    address globals;
    address GOVERNOR = address(new Address());
    address TREASURY = address(new Address());

    function _bootstrapGlobals(address liquidityAsset_, address poolDelegate_) internal {
        vm.startPrank(GOVERNOR);
        MockGlobals(globals).setValidPoolAsset(address(liquidityAsset_), true);
        MockGlobals(globals).setValidPoolDelegate(poolDelegate_, true);
        MockGlobals(globals).setTreasury(TREASURY);
        vm.stopPrank();
    }

    function _deployAndBootstrapGlobals(address liquidityAsset_, address poolDelegate_) internal {
        _deployGlobals();
        _bootstrapGlobals(liquidityAsset_, poolDelegate_);
    }

    function _deployGlobals() internal {
        globals = address(new MockGlobals(GOVERNOR));
    }

}
