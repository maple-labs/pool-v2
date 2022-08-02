// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { MapleProxyFactory } from "../../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

contract PoolManagerFactory is MapleProxyFactory {

    constructor(address globals_) MapleProxyFactory(globals_) { }

}
