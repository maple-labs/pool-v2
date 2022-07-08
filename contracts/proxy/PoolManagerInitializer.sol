// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IGlobalsLike }            from "../interfaces/Interfaces.sol";
import { IPoolManagerInitializer } from "../interfaces/IPoolManagerInitializer.sol";

import { Pool }               from "../Pool.sol";
import { PoolManagerStorage } from "./PoolManagerStorage.sol";

contract PoolManagerInitializer is IPoolManagerInitializer, PoolManagerStorage {

    function encodeArguments(
        address globals_,
        address admin_,
        address asset_,
        string memory name_,
        string memory symbol_
    )
        external pure override returns (bytes memory encodedArguments_)
    {
        encodedArguments_ = abi.encode(globals_, admin_, asset_, name_, symbol_);
    }

    function decodeArguments(bytes calldata encodedArguments_) public pure override
        returns (
            address globals_,
            address admin_,
            address asset_,
            string memory name_,
            string memory symbol_
        )
    {
        ( globals_, admin_, asset_, name_, symbol_ ) = abi.decode(encodedArguments_, (address, address, address, string, string));
    }

    fallback() external {
        (
            address globals_,
            address admin_,
            address asset_,
            string memory name_,
            string memory symbol_
        ) = decodeArguments(msg.data);

        _initialize(globals_, admin_, asset_, name_, symbol_);
    }

    function _initialize(address globals_, address admin_, address asset_, string memory name_, string memory symbol_) internal {
        // TODO: Perform all checks on globals.

        require((globals = globals_) != address(0), "PMI:I:ZERO_GLOBALS");
        require((admin = admin_)     != address(0), "PMI:I:ZERO_ADMIN");
        require((asset = asset_)     != address(0), "PMI:I:ZERO_ASSET");

        require(IGlobalsLike(globals_).isPoolDelegate(admin_), "PMI:I:NOT_PD");

        pool = address(new Pool(address(this), asset_, name_, symbol_));

        emit Initialized(globals_, admin_, asset_, address(pool));
    }

}
