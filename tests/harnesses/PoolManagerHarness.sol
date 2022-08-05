// SDPX-License-Identifier: AGLP-3.0-only
pragma solidity ^0.8.7;

import { PoolManager } from "../../contracts/PoolManager.sol";

contract PoolManagerHarness is PoolManager {

    function __setLoanManagerForLoan(address loan_, address loanManager_) external {
        loanManagers[loan_] = loanManager_;
    }

    function __setUnrealizedLosses(uint256 unrealizedLosses_) external {
        unrealizedLosses = unrealizedLosses_;
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
