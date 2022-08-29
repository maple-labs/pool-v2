// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IMapleGlobalsLike, IMapleProxyFactoryLike } from "../interfaces/Interfaces.sol";
import { IPoolManagerInitializer }                   from "../interfaces/IPoolManagerInitializer.sol";

import { Pool }               from "../Pool.sol";
import { PoolDelegateCover }  from "../PoolDelegateCover.sol";
import { PoolManagerStorage } from "./PoolManagerStorage.sol";

contract PoolManagerInitializer is IPoolManagerInitializer, PoolManagerStorage {

    function decodeArguments(bytes calldata encodedArguments_) public pure override
        returns (
            address poolDelegate_,
            address asset_,
            uint256 intialSupply_,
            string memory name_,
            string memory symbol_
        )
    {
        ( poolDelegate_, asset_, intialSupply_, name_, symbol_ ) = abi.decode(encodedArguments_, (address, address, uint256, string, string));
    }

    function encodeArguments(
        address poolDelegate_,
        address asset_,
        uint256 intialSupply_,
        string memory name_,
        string memory symbol_
    )
        external pure override returns (bytes memory encodedArguments_)
    {
        encodedArguments_ = abi.encode(poolDelegate_, asset_, intialSupply_, name_, symbol_);
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

    function _initialize(address poolDelegate_, address asset_, uint256 intialSupply_, string memory name_, string memory symbol_) internal {
        address globals_ = IMapleProxyFactoryLike(msg.sender).mapleGlobals();

        require((poolDelegate = poolDelegate_) != address(0), "PMI:I:ZERO_PD");
        require((asset = asset_)               != address(0), "PMI:I:ZERO_ASSET");

        require(IMapleGlobalsLike(globals_).isPoolDelegate(poolDelegate_),                 "PMI:I:NOT_PD");
        require(IMapleGlobalsLike(globals_).ownedPoolManager(poolDelegate_) == address(0), "PMI:I:POOL_OWNER");
        require(IMapleGlobalsLike(globals_).isPoolAsset(asset_),                           "PMI:I:ASSET_NOT_ALLOWED");

        address migrationAdmin_ = IMapleGlobalsLike(globals_).migrationAdmin();

        pool              = address(new Pool(address(this), asset_, migrationAdmin_, intialSupply_, name_, symbol_));
        poolDelegateCover = address(new PoolDelegateCover(address(this), asset));

        emit Initialized(poolDelegate_, asset_, address(pool));
    }

}
