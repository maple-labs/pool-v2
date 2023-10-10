// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { MapleProxiedInternals } from "../../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import { IMapleProxyFactoryLike, IGlobalsLike } from "../interfaces/Interfaces.sol";

import { MaplePoolManagerStorage } from "./MaplePoolManagerStorage.sol";

contract MaplePoolManagerWMMigrator is MapleProxiedInternals, MaplePoolManagerStorage {

    event WithdrawalManagerSet(address withdrawalManager_);

    fallback() external {
        address withdrawalManager_ = abi.decode(msg.data, (address));
        address globals_           = IMapleProxyFactoryLike(_factory()).mapleGlobals();

        require(IGlobalsLike(globals_).isInstanceOf("WITHDRAWAL_MANAGER", withdrawalManager_), "PMM:INVALID_WM");
        require(IGlobalsLike(globals_).isInstanceOf("QUEUE_POOL_MANAGER", address(this)),      "PMM:INVALID_PM");

        withdrawalManager = withdrawalManager_;

        emit WithdrawalManagerSet(withdrawalManager_);
    }

}
