// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

interface IPoolManagerInitializer {

    event Initialized(address globals_, address owner_, address asset_, address pool_);

    function encodeArguments(address globals_, address owner_, address asset_, string memory name_, string memory symbol_) external pure
        returns (bytes memory encodedArguments_);

    function decodeArguments(bytes calldata encodedArguments_) external pure
        returns (address globals_, address owner_, address asset_, string memory name_, string memory symbol_);

}
