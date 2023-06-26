// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { MaplePoolManager } from "../../contracts/MaplePoolManager.sol";

contract MaplePoolManagerHarness is MaplePoolManager {

    function __handleCover(uint256 losses_, uint256 platformFees_) external {
        _handleCover(losses_, platformFees_);
    }

    function __setIsLoanManager(address loanManager_, bool isLoanManager_) external {
        isLoanManager[loanManager_] = isLoanManager_;
    }

    function __pushToLoanManagerList(address loanManager_) external {
        loanManagerList.push(loanManager_);
    }

    function __setConfigured(bool configured_) external {
        configured = configured_;
    }

    function __getLoanManagerListValue(uint256 index_) external view returns (address value_) {
        value_ = index_ < loanManagerList.length ? loanManagerList[index_] : address(0);
    }

}
