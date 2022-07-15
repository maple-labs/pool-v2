// SDPX-License-Identifier: AGLP-3.0-only
pragma solidity ^0.8.7;

import { PoolManager } from "../../contracts/PoolManager.sol";

contract PoolManagerHarness is PoolManager { 

    function setLoanManagerForLoan(address loan_, address loanManager_) external {
        loanManagers[loan_] = loanManager_;
    }

}
