// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

interface ILoanManagerInitializer {

    event Initialized(address indexed pool_);

    function decodeArguments(bytes calldata calldata_) external pure returns (address pool_);

    function encodeArguments(address pool_) external pure returns (bytes memory calldata_);

}
