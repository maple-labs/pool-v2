// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { MaplePoolManager }            from "../../contracts/MaplePoolManager.sol";
import { MaplePoolManagerInitializer } from "../../contracts/proxy/MaplePoolManagerInitializer.sol";

contract MaplePoolManagerHarness is MaplePoolManager {

    function __setIsStrategy(address strategy_, bool isStrategy_) external {
        isStrategy[strategy_] = isStrategy_;
    }

    function __setIsStrategyManager(address strategyManager_, bool isStrategyManager_) external {
        isStrategyManager[strategyManager_] = isStrategyManager_;
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

    function __setLocked(uint256 locked_) external {
        _locked = locked_;
    }

    function __getStrategyListValue(uint256 index_) external view returns (address value_) {
        value_ = index_ < strategyList.length ? strategyList[index_] : address(0);
    }

}

contract MaplePoolManagerInitializerHarness is MaplePoolManagerInitializer {

    function __initialize(
        address poolDelegate_,
        address asset_,
        uint256 initialSupply_,
        string memory name_,
        string memory symbol_
    ) external {
        _initialize(poolDelegate_, asset_, initialSupply_, name_, symbol_);
    }

}
