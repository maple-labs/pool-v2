// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { ERC20Helper } from "../modules/erc20-helper/src/ERC20Helper.sol";

contract PoolDelegateCover {

    address public asset;
    address public poolManager;

    constructor(address poolManager_, address asset_) {
        asset       = asset_;
        poolManager = poolManager_;
    }

    // TODO: Add a deposit function with ACL to PM. Do transferFrom from PM to this contract.

    function moveFunds(uint256 amount_, address recipient_) external {
        require(msg.sender == poolManager,                        "PDC:MF:NOT_MANAGER");
        require(ERC20Helper.transfer(asset, recipient_, amount_), "PDC:MF:TRANSFER_FAILED");
    }

}
