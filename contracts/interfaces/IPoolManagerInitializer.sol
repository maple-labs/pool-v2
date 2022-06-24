// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

interface IPoolManagerInitializer {

    event Initialized(address globals_,
            address owner_,
            address pool_,
            address asset_,
            uint256 precision_,
            string  poolName_,
            string  poolSymbol_);
    
    function encodeArguments(
        address globals_,
        address owner_,
        address asset_,
        uint256 precision_,
        string memory poolName_,
        string memory poolSymbol_
    ) external pure returns (bytes memory encodedArguments_);

    function decodeArguments(bytes calldata encodedArguments_)
        external pure returns (
            address globals_,
            address owner_,
            address asset_,
            uint256 precision_,
            string memory poolName_,
            string memory poolSymbol_
        );
        
}
