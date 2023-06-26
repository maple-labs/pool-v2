// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

interface IMaplePoolManagerInitializer {

    event Initialized(address owner_, address asset_, address pool_);

    function decodeArguments(bytes calldata encodedArguments_) external pure
        returns (address owner_, address asset_, uint256 initialSupply_, string memory name_, string memory symbol_);

    function encodeArguments(
        address owner_,
        address asset_,
        uint256 initialSupply_,
        string memory name_,
        string memory symbol_
    )
        external pure returns (bytes memory encodedArguments_);

}
