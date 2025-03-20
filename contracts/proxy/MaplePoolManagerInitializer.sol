// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import { IGlobalsLike, IMapleProxyFactoryLike } from "../interfaces/Interfaces.sol";
import { IMaplePoolManagerInitializer }         from "../interfaces/IMaplePoolManagerInitializer.sol";

import { MaplePool }               from "../MaplePool.sol";
import { MaplePoolDelegateCover }  from "../MaplePoolDelegateCover.sol";
import { MaplePoolManagerStorage } from "./MaplePoolManagerStorage.sol";

contract MaplePoolManagerInitializer is IMaplePoolManagerInitializer, MaplePoolManagerStorage {

    function decodeArguments(bytes calldata encodedArguments_) public pure override
        returns (
            address poolDelegate_,
            address asset_,
            uint256 initialSupply_,
            string memory name_,
            string memory symbol_
        )
    {
        (
            poolDelegate_,
            asset_,
            initialSupply_,
            name_,
            symbol_
        ) = abi.decode(encodedArguments_, (address, address, uint256, string, string));
    }

    function encodeArguments(
        address poolDelegate_,
        address asset_,
        uint256 initialSupply_,
        string memory name_,
        string memory symbol_
    )
        external pure override returns (bytes memory encodedArguments_)
    {
        encodedArguments_ = abi.encode(poolDelegate_, asset_, initialSupply_, name_, symbol_);
    }

    fallback() external {
        _locked = 1;

        (
            address poolDelegate_,
            address asset_,
            uint256 initialSupply_,
            string memory name_,
            string memory symbol_
        ) = decodeArguments(msg.data);

        _initialize(poolDelegate_, asset_, initialSupply_,  name_, symbol_);
    }

    function _initialize(
        address poolDelegate_,
        address asset_,
        uint256 initialSupply_,
        string memory name_,
        string memory symbol_
    ) internal {
        address globals_ = IMapleProxyFactoryLike(msg.sender).mapleGlobals();

        require((poolDelegate = poolDelegate_) != address(0), "PMI:I:ZERO_PD");
        require((asset = asset_)               != address(0), "PMI:I:ZERO_ASSET");

        require(IGlobalsLike(globals_).isPoolDelegate(poolDelegate_),                 "PMI:I:NOT_PD");
        require(IGlobalsLike(globals_).ownedPoolManager(poolDelegate_) == address(0), "PMI:I:POOL_OWNER");
        require(IGlobalsLike(globals_).isPoolAsset(asset_),                           "PMI:I:ASSET_NOT_ALLOWED");

        address migrationAdmin_ = IGlobalsLike(globals_).migrationAdmin();

        require(initialSupply_ == 0 || migrationAdmin_ != address(0), "PMI:I:INVALID_POOL_PARAMS");

        pool = address(
            new MaplePool(
                address(this),
                asset_,
                migrationAdmin_,
                IGlobalsLike(globals_).bootstrapMint(asset_),
                initialSupply_,
                name_,
                symbol_
            )
        );

        poolDelegateCover = address(new MaplePoolDelegateCover(address(this), asset));

        emit Initialized(poolDelegate_, asset_, address(pool));
    }

}
