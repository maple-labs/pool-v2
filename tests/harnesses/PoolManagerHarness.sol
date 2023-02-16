// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { PoolManager } from "../../contracts/PoolManager.sol";

contract PoolManagerHarness is PoolManager {

    function handleCover(uint256 losses_, uint256 platformFees_) external {
        _handleCover(losses_, platformFees_);
    }

    function __setConfigured(bool _configured) external {
        configured = _configured;
    }

    function __getLoanManagerListLength() external view returns (uint256 length_) {
        return loanManagerList.length;
    }

    function __getLoanManagerListValue(uint256 index_) external view returns (address value_) {
        if (index_ >= loanManagerList.length) {
            return address(0);
        }
        return loanManagerList[index_];
    }

}
