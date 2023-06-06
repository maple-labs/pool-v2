// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { IMapleProxyFactory, MapleProxyFactory } from "../../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

import { IPoolManagerFactory } from "../interfaces/IPoolManagerFactory.sol";

import { IGlobalsLike } from "../interfaces/Interfaces.sol";

contract PoolManagerFactory is IPoolManagerFactory, MapleProxyFactory {

    constructor(address globals_) MapleProxyFactory(globals_) { }

    function createInstance(bytes calldata arguments_, bytes32 salt_)
        public override(IMapleProxyFactory, MapleProxyFactory) returns (address instance_)
    {
        require(IGlobalsLike(mapleGlobals).isPoolDeployer(msg.sender), "PMF:CI:NOT_DEPLOYER");

        instance_ = super.createInstance(arguments_, salt_);
    }

}
