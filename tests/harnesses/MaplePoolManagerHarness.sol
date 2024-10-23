// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { MaplePoolManager } from "../../contracts/MaplePoolManager.sol";

contract MaplePoolManagerHarness is MaplePoolManager {

    function __handleCover(uint256 losses_, uint256 platformFees_) external {
        _handleCover(losses_, platformFees_);
    }

    function __setIsStrategy(address strategy_, bool isStrategy_) external {
        isStrategy[strategy_] = isStrategy_;
    }

    function __setPoolPermissionManager(address poolPermissionManager_) external {
        poolPermissionManager = poolPermissionManager_;
    }

    function __pushToStrategyList(address strategy_) external {
        strategyList.push(strategy_);
    }

    function __setConfigured(bool configured_) external {
        configured = configured_;
    }

    function __getStrategyListValue(uint256 index_) external view returns (address value_) {
        value_ = index_ < strategyList.length ? strategyList[index_] : address(0);
    }

}
