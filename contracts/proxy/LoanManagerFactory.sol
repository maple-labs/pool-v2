// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IMapleProxyFactory, MapleProxyFactory } from "../../modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";

contract LoanManagerFactory is MapleProxyFactory {

    mapping(address => bool) public isInstance;

    constructor(address globals_) MapleProxyFactory(globals_) { }

    function createInstance(bytes calldata arguments_, bytes32 salt_) override(MapleProxyFactory) public returns (address instance_) {
        isInstance[instance_ = super.createInstance(arguments_, salt_)] = true;
    }

}
