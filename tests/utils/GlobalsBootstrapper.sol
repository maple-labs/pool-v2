// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { Test }        from "../../modules/forge-std/src/Test.sol";
import { MockGlobals } from "../mocks/Mocks.sol";

/**
 *  @dev Used to setup the MockGlobals contract for test contracts.
 */
contract GlobalsBootstrapper is Test {

    address internal GOVERNOR = makeAddr("GOVERNOR");
    address internal TREASURY = makeAddr("TREASURY");

    address internal globals;

    function _bootstrapGlobals(address liquidityAsset_, address poolDelegate_) internal {
        vm.startPrank(GOVERNOR);
        MockGlobals(globals).setValidPoolAsset(address(liquidityAsset_), true);
        MockGlobals(globals).setValidPoolDelegate(poolDelegate_, true);
        MockGlobals(globals).setMapleTreasury(TREASURY);
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
