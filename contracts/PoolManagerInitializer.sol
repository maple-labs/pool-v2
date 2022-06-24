// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IPoolManagerInitializer } from "./interfaces/IPoolManagerInitializer.sol";

import { Pool } from "./Pool.sol";

contract PoolManagerInitializer is IPoolManagerInitializer {

    // TODO TODO TODO change to storage contract
    uint256 public precision;

    address public globals; 
    address public owner;
    
    Pool public pool;
    
    function encodeArguments(
        address globals_,
        address owner_,
        address asset_,
        uint256 precision_,
        string memory poolName_,
        string memory poolSymbol_
    ) external pure override returns (bytes memory encodedArguments_) {
        return abi.encode(globals_, owner_, asset_, precision_, poolName_, poolSymbol_);
    }

    function decodeArguments(bytes calldata encodedArguments_)
        public pure override returns (
            address globals_,
            address owner_,
            address asset_,
            uint256 precision_,
            string memory poolName_,
            string memory poolSymbol_
        )
    {
        (
            globals_,
            owner_,
            asset_,
            precision_,
            poolName_,
            poolSymbol_
        ) = abi.decode(encodedArguments_, (address, address, address, uint256, string, string));
    }

    fallback() external {
        (
            address globals_,
            address owner_,
            address asset_,
            uint256 precision_,
            string memory poolName_,
            string memory poolSymbol_
        ) = decodeArguments(msg.data);

        _initialize(globals_, owner_, asset_, precision_, poolName_, poolSymbol_);
    }

    /**
     *  @dev   Initializes the PoolManager and deploys the pool.
     *  @param globals_    The address of Maple Globals contract.
     *  @param owner_      The address of the pool's manager
     *  @param asset_      The liquidty asset for the pool
     *  @param precision_  Precision for pool
     *  @param poolName_   Name for pool ERC20
     *  @param poolSymbol_ Symbol for pool ERC20
     */
    function _initialize(
        address globals_,
        address owner_,
        address asset_,
        uint256 precision_,
        string memory poolName_,
        string memory poolSymbol_
    )
        internal
    {
        // Todo perform all checks with globals
        require(owner_   != address(0), "PMI:I:ZERO_OWNER");
        require(globals_ != address(0), "PMI:I:ZERO_GLOBALS");

        Pool pool_ = new Pool(poolName_, poolSymbol_, address(this), asset_);

        pool      = pool_;
        precision = precision_;
        globals   = globals_;
        owner     = owner_;

        emit Initialized(globals_, owner_, address(pool_), asset_, precision_, poolName_, poolSymbol_);
    }

}
