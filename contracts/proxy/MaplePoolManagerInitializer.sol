// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { IGlobalsLike, IMapleProxyFactoryLike } from "../interfaces/Interfaces.sol";
import { IMaplePoolManagerInitializer } from "../interfaces/IMaplePoolManagerInitializer.sol";

import { MaplePool } from "../MaplePool.sol";
import { MaplePoolManagerStorage } from "./MaplePoolManagerStorage.sol";

contract MaplePoolManagerInitializer is IMaplePoolManagerInitializer, MaplePoolManagerStorage {

    fallback() external {
        _locked = 1;

        (address poolDelegate_, address asset_, uint256 initialSupply_, string memory name_, string memory symbol_) =
            abi.decode(msg.data, (address, address, uint256, string, string));

        _initialize(poolDelegate_, asset_, initialSupply_, name_, symbol_);
    }

    function _initialize(
        address poolDelegate_,
        address asset_,
        uint256 initialSupply_,
        string memory name_,
        string memory symbol_
    )
        internal
    {
        address globals_ = IMapleProxyFactoryLike(msg.sender).mapleGlobals();

        require((poolDelegate = poolDelegate_) != address(0), "PMI:I:ZERO_PD");
        require((asset = asset_) != address(0),               "PMI:I:ZERO_ASSET");

        require(IGlobalsLike(globals_).isPoolDelegate(poolDelegate_),                 "PMI:I:NOT_PD");
        require(IGlobalsLike(globals_).ownedPoolManager(poolDelegate_) == address(0), "PMI:I:POOL_OWNER");
        require(IGlobalsLike(globals_).isPoolAsset(asset_),                           "PMI:I:ASSET_NOT_ALLOWED");

        address migrationAdmin_ = IGlobalsLike(globals_).migrationAdmin();

        require(initialSupply_ == 0 || migrationAdmin_ != address(0), "PMI:I:INVALID_POOL_PARAMS");

        pool = address(
            new MaplePool(
                address(this), asset_, migrationAdmin_, IGlobalsLike(globals_).bootstrapMint(asset_), initialSupply_, name_, symbol_
            )
        );

        emit Initialized(poolDelegate_, asset_, address(pool));
    }

}
