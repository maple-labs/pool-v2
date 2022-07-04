// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IPoolManagerInitializer } from "../interfaces/IPoolManagerInitializer.sol";

import { PoolManagerStorage } from "./PoolManagerStorage.sol";

import { Pool } from "../Pool.sol";

contract PoolManagerInitializer is IPoolManagerInitializer, PoolManagerStorage {

    function encodeArguments(
        address globals_,
        address owner_,
        address asset_,
        string memory name_,
        string memory symbol_
    )
        external pure override returns (bytes memory encodedArguments_)
    {
        encodedArguments_ = abi.encode(globals_, owner_, asset_, name_, symbol_);
    }

    function decodeArguments(bytes calldata encodedArguments_) public pure override
        returns (
            address globals_,
            address owner_,
            address asset_,
            string memory name_,
            string memory symbol_
        )
    {
        ( globals_, owner_, asset_, name_, symbol_ ) = abi.decode(encodedArguments_, (address, address, address, string, string));
    }

    fallback() external {
        (
            address globals_,
            address owner_,
            address asset_,
            string memory name_,
            string memory symbol_
        ) = decodeArguments(msg.data);

        _initialize(globals_, owner_, asset_, name_, symbol_);
    }

    function _initialize(address globals_, address owner_, address asset_, string memory name_, string memory symbol_) internal {
        // TODO: Perform all checks on globals.

        require((globals = globals_) != address(0), "PMI:I:ZERO_GLOBALS");
        require((owner = owner_)     != address(0), "PMI:I:ZERO_OWNER");
        require((asset = asset_)     != address(0), "PMI:I:ZERO_ASSET");

        pool = address(new Pool(address(this), asset_, name_, symbol_));

        emit Initialized(globals_, owner_, asset_, address(pool));
    }

}
