// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { Test }                from "../../modules/forge-std/src/Test.sol";
import { GlobalsBootstrapper } from "./GlobalsBootstrapper.sol";

contract TestBase is Test, GlobalsBootstrapper {

    function deploy(string memory contractName) internal returns (address contract_) {
        contract_ = deployCode(string(abi.encodePacked("./out/", contractName, ".sol/", contractName, ".json")));
    }

}

