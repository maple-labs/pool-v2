// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

interface IPoolDelegateCover {

    function asset() external view returns(address asset_);

    function poolManager() external view returns(address poolManager_);

    function moveFunds(uint256 amount_, address recipient_) external;

}
