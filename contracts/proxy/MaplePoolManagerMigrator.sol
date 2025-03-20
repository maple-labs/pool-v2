// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import { MapleProxiedInternals } from "../../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import { IMapleProxyFactoryLike, IGlobalsLike } from "../interfaces/Interfaces.sol";

import { MaplePoolManagerStorage } from "./MaplePoolManagerStorage.sol";

contract MaplePoolManagerMigrator is MapleProxiedInternals, MaplePoolManagerStorage {

    event PoolPermissionManagerSet(address poolPermissionManager_);

    fallback() external {
        address poolPermissionManager_ = abi.decode(msg.data, (address));
        address globals_               = IMapleProxyFactoryLike(_factory()).mapleGlobals();

        require(IGlobalsLike(globals_).isInstanceOf("POOL_PERMISSION_MANAGER", poolPermissionManager_), "PMM:INVALID_PPM");

        poolPermissionManager = poolPermissionManager_;

        emit PoolPermissionManagerSet(poolPermissionManager_);
    }

}
