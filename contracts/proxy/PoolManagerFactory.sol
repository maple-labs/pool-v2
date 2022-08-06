// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { MapleProxyFactory } from "../../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

import { IGlobalsLike } from "../interfaces/Interfaces.sol";

contract PoolManagerFactory is MapleProxyFactory {

    constructor(address globals_) MapleProxyFactory(globals_) { }

    function createInstance(bytes calldata arguments_, bytes32 salt_) public override returns (address instance_) {
        require(IGlobalsLike(mapleGlobals).isPoolDeployer(msg.sender), "PMF:CI:NOT_DEPLOYER");

        instance_ = super.createInstance(arguments_, salt_);
    }
}
