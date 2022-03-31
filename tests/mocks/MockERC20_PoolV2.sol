// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { PoolV2 } from "../../contracts/PoolV2.sol";

contract MockERC20_PoolV2 is PoolV2 {

    constructor(string memory name_, string memory symbol_, address owner_, address asset_, uint256 precision_)
        PoolV2(name_, symbol_, owner_, asset_, precision_) { }

    function mint(address recipient_, uint256 amount_) external {
        _mint(recipient_, amount_);
    }

    function burn(address owner_, uint256 amount_) external {
        _burn(owner_, amount_);
    }

}
