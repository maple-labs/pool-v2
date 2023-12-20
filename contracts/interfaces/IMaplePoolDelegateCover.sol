// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

interface IMaplePoolDelegateCover {

    /**
     *  @dev    Gets the address of the funds asset.
     *  @return asset_ The address of the funds asset.
     */
    function asset() external view returns(address asset_);

    /**
     *  @dev   Move funds from this address to another.
     *  @param amount_    The amount to move.
     *  @param recipient_ The address of the recipient.
     */
    function moveFunds(uint256 amount_, address recipient_) external;

    /**
     *  @dev    Gets the address of the pool manager.
     *  @return poolManager_ The address of the pool manager.
     */
    function poolManager() external view returns(address poolManager_);

}
