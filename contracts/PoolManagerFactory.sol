// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IMapleProxyFactory, MapleProxyFactory } from "../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

/// @title PoolManagerFactory deploys PoolManager and pool instances.
contract PoolManagerFactory is MapleProxyFactory {

    /// @param mapleGlobals_ The address of a Maple Globals contract.
    constructor(address mapleGlobals_) MapleProxyFactory(mapleGlobals_) { }

    // TODO Investigate adding a isPool mapping here

}
