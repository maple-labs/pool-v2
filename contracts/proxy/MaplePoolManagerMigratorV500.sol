// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { IMapleProxied } from "../../modules/maple-proxy-factory/contracts/interfaces/IMapleProxied.sol";

import { MapleProxiedInternals } from "../../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import {
    IGlobalsLike,
    IMapleProxyFactoryLike,
    IStrategyLike
} from "../interfaces/Interfaces.sol";

import { MaplePoolManagerStorage } from "./MaplePoolManagerStorage.sol";

// Note: Before migrating all non-OTLM strategies will be emptied
contract MaplePoolManagerMigratorV500 is MapleProxiedInternals, MaplePoolManagerStorage {

    event StrategyRemoved(address indexed strategy);

    fallback() external {
        address globals_ = IMapleProxyFactoryLike(_factory()).mapleGlobals();

        for (uint256 i_ = strategyList.length; i_ > 0;) {
            i_--;

            address strategy_ = strategyList[i_];

            if (_isOpenTermLoanManager(globals_, strategy_)) continue;

            if (_isFixedTermLoanManager(globals_, strategy_)) {
                require(IStrategyLike(strategy_).assetsUnderManagement() == 0, "PMM:NON_ZERO_AUM");
            }

            strategyList[i_] = strategyList[strategyList.length - 1];

            strategyList.pop();

            delete isStrategy[strategy_];

            emit StrategyRemoved(strategy_);
        }
    }

    function _isFixedTermLoanManager(address globals_, address strategy_) internal view returns (bool isFixedTermLoanManager_) {
        isFixedTermLoanManager_ =
            IGlobalsLike(globals_).isInstanceOf("FT_LOAN_MANAGER_FACTORY", IMapleProxied(strategy_).factory());
    }

    function _isOpenTermLoanManager(address globals_, address strategy_) internal view returns (bool isOpenTermLoanManager_) {
        isOpenTermLoanManager_ =
            IGlobalsLike(globals_).isInstanceOf("OT_LOAN_MANAGER_FACTORY", IMapleProxied(strategy_).factory());
    }

}
