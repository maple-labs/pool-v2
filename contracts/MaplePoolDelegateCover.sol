// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { ERC20Helper } from "../modules/erc20-helper/src/ERC20Helper.sol";

import { IMaplePoolDelegateCover } from "./interfaces/IMaplePoolDelegateCover.sol";

/*

    ███╗   ███╗ █████╗ ██████╗ ██╗     ███████╗    ██████╗ ██████╗      ██████╗ ██████╗ ██╗   ██╗███████╗██████╗
    ████╗ ████║██╔══██╗██╔══██╗██║     ██╔════╝    ██╔══██╗██╔══██╗    ██╔════╝██╔═══██╗██║   ██║██╔════╝██╔══██╗
    ██╔████╔██║███████║██████╔╝██║     █████╗      ██████╔╝██║  ██║    ██║     ██║   ██║██║   ██║█████╗  ██████╔╝
    ██║╚██╔╝██║██╔══██║██╔═══╝ ██║     ██╔══╝      ██╔═══╝ ██║  ██║    ██║     ██║   ██║╚██╗ ██╔╝██╔══╝  ██╔══██╗
    ██║ ╚═╝ ██║██║  ██║██║     ███████╗███████╗    ██║     ██████╔╝    ╚██████╗╚██████╔╝ ╚████╔╝ ███████╗██║  ██║
    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝    ╚═╝     ╚═════╝      ╚═════╝ ╚═════╝   ╚═══╝  ╚══════╝╚═╝  ╚═╝

*/

contract MaplePoolDelegateCover is IMaplePoolDelegateCover {

    address public override asset;
    address public override poolManager;

    constructor(address poolManager_, address asset_) {
        require((poolManager = poolManager_) != address(0), "PDC:C:ZERO_PM_ADDRESS");
        require((asset       = asset_)       != address(0), "PDC:C:ZERO_A_ADDRESS");
    }

    function moveFunds(uint256 amount_, address recipient_) external override {
        require(msg.sender == poolManager,                        "PDC:MF:NOT_MANAGER");
        require(ERC20Helper.transfer(asset, recipient_, amount_), "PDC:MF:TRANSFER_FAILED");
    }

}
