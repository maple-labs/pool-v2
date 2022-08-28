// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { ILoanManagerInitializer } from "../interfaces/ILoanManagerInitializer.sol";
import { IPoolLike }               from "../interfaces/Interfaces.sol";

import { LoanManagerStorage } from "./LoanManagerStorage.sol";

contract LoanManagerInitializer is ILoanManagerInitializer, LoanManagerStorage {

    function encodeArguments(address pool_) external pure override returns (bytes memory calldata_) {
        calldata_ = abi.encode(pool_);
    }

    function decodeArguments(bytes calldata calldata_) public pure override returns (address pool_) {
        pool_ = abi.decode(calldata_, (address));
    }

    fallback() external {
        _locked = 1;

        address pool_ = decodeArguments(msg.data);

        pool        = pool_;
        fundsAsset  = IPoolLike(pool_).asset();
        poolManager = IPoolLike(pool_).manager();

        emit Initialized(pool_);
    }

}
