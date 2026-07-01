// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IMapleProxied } from "../../modules/maple-proxy-factory/contracts/interfaces/IMapleProxied.sol";

import { MapleProxiedInternals } from "../../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import {
    IGlobalsLike,
    IMapleProxyFactoryLike,
    IStrategyLike
} from "../interfaces/Interfaces.sol";

import { MaplePoolManagerStorage } from "./MaplePoolManagerStorage.sol";

contract MaplePoolManagerMigratorV500 is MapleProxiedInternals, MaplePoolManagerStorage {

    event StrategyRemoved(address indexed strategy);

    fallback() external {
        address globals_ = IMapleProxyFactoryLike(_factory()).mapleGlobals();

        for (uint256 i_ = strategyList.length; i_ > 0;) {
            i_--;

            address strategy_        = strategyList[i_];
            address strategyFactory_ = IMapleProxied(strategy_).factory();

            if (!IGlobalsLike(globals_).isInstanceOf("FT_LOAN_MANAGER_FACTORY", strategyFactory_)) continue;

            require(IStrategyLike(strategy_).assetsUnderManagement() == 0, "PMM:NON_ZERO_AUM");

            strategyList[i_] = strategyList[strategyList.length - 1];

            strategyList.pop();

            delete isStrategy[strategy_];

            emit StrategyRemoved(strategy_);
        }
    }

}
