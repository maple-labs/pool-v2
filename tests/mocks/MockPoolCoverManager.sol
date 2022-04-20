// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { MockERC20 } from "../../modules/revenue-distribution-token/modules/erc20/contracts/test/mocks/MockERC20.sol";

contract MockPoolCoverManager {

    MockERC20 public asset;

    constructor(MockERC20 asset_) {
        asset = asset_;
    }

    function distributeAssets() external returns (address[] memory recipients_, uint256[] memory assets_) {
        // Burn all assets on this contract to simulate the effects of a distribution.
        asset.burn(address(this), asset.balanceOf(address(this)));
    }

}
