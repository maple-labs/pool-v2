// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC20 } from "../../modules/erc20/contracts/interfaces/IERC20.sol";

import { IERC4626 } from "./IERC4626.sol";

interface IPool is IERC20, IERC4626 {

    /**************/
    /*** Events ***/
    /**************/

    /**
     *  @dev   `newOwner_` has accepted the transferral of RDT ownership from `previousOwner_`.
     *  @param previousOwner_ The previous RDT owner.
     *  @param newOwner_      The new RDT owner.
     */
    event OwnershipAccepted(address indexed previousOwner_, address indexed newOwner_);

    /**
     *  @dev   `owner_` has set the new pending owner of RDT to `pendingOwner_`.
     *  @param owner_        The current RDT owner.
     *  @param pendingOwner_ The new pending RDT owner.
     */
    event PendingOwnerSet(address indexed owner_, address indexed pendingOwner_);

    /**
     *  @dev   A new redemption request has been made.
     *  @param owner_          The owner of shares.
     *  @param shares_         The amount of shares requested to redeem.
     *  @param escrowedShares_ The amount of shares actually escrowed for this withdrawal request.
     */
    event RedemptionRequested(address indexed owner_, uint256 shares_, uint256 escrowedShares_);

    /**
     *  @dev   Shares have been removed.
     *  @param owner_  The owner of shares.
     *  @param shares_ The amount of shares requested to be removed.
     */
    event SharesRemoved(address indexed owner_, uint256 shares_);

    /**
     *  @dev   A new withdrawal request has been made.
     *  @param owner_          The owner of shares.
     *  @param assets_         The amount of assets requested to withdraw.
     *  @param escrowedShares_ The amount of shares actually escrowed for this withdrawal request.
     */
    event WithdrawRequested(address indexed owner_, uint256 assets_, uint256 escrowedShares_);

    /***********************/
    /*** State Variables ***/
    /***********************/

    /**
     *  @dev The address of the account that is allowed to update the vesting schedule.
     *  @return manager_ The address of the pool manager.
     */
    function manager() external view returns (address manager_);

    /********************/
    /*** LP Functions ***/
    /********************/

    /**
     *  @dev    Does a ERC4626 `deposit` with a ERC-2612 `permit`.
     *  @param  assets_   The amount of `asset` to deposit.
     *  @param  receiver_ The receiver of the shares.
     *  @param  deadline_ The timestamp after which the `permit` signature is no longer valid.
     *  @param  v_        ECDSA signature v component.
     *  @param  r_        ECDSA signature r component.
     *  @param  s_        ECDSA signature s component.
     *  @return shares_   The amount of shares minted.
     */
    function depositWithPermit(uint256 assets_, address receiver_, uint256 deadline_, uint8 v_, bytes32 r_, bytes32 s_) external returns (uint256 shares_);

    /**
     *  @dev    Does a ERC4626 `mint` with a ERC-2612 `permit`.
     *  @param  shares_    The amount of `shares` to mint.
     *  @param  receiver_  The receiver of the shares.
     *  @param  maxAssets_ The maximum amount of assets that can be taken, as per the permit.
     *  @param  deadline_  The timestamp after which the `permit` signature is no longer valid.
     *  @param  v_         ECDSA signature v component.
     *  @param  r_         ECDSA signature r component.
     *  @param  s_         ECDSA signature s component.
     *  @return assets_    The amount of shares deposited.
     */
    function mintWithPermit(uint256 shares_, address receiver_, uint256 maxAssets_, uint256 deadline_, uint8 v_, bytes32 r_, bytes32 s_) external returns (uint256 assets_);

    /************************************/
    /*** Withdrawal Request Functions ***/
    /************************************/

    /**
     *  @dev    Requests a redemption of shares from the pool.
     *  @param  shares_         The amount of shares to redeem.
     *  @param  owner_          The owner of the shares.        
     *  @return sharesReturned_ The amount of shares withdrawn.
     */
    function removeShares(uint256 shares_, address owner_) external returns (uint256 sharesReturned_);

    /**
     *  @dev    Requests a withdrawal of assets from the pool.
     *  @param  assets_       The amount of assets to withdraw.
     *  @param  owner_        The owner of the shares.
     *  @return escrowShares_ The amount of shares sent to escrow.
     */
    function requestWithdraw(uint256 assets_, address owner_) external returns (uint256 escrowShares_);

    /**
     *  @dev    Requests a redemption of shares from the pool.
     *  @param  shares_       The amount of shares to redeem.
     *  @param  owner_        The owner of the shares.
     *  @return escrowShares_ The amount of shares sent to escrow.
     */
    function requestRedeem(uint256 shares_, address owner_) external returns (uint256 escrowShares_);

    /**********************/
    /*** View Functions ***/
    /**********************/

    /**
     *  @dev    Returns the amount of underlying assets owned by the specified account.
     *  @param  account_ Address of the account.
     *  @return assets_  Amount of assets owned.
     */
    function balanceOfAssets(address account_) external view returns (uint256 assets_);

    /**
     *  @dev    Returns the amount of exit shares for the input amount.
     *  @param  amount_ Address of the account.
     *  @return shares_ Amount of shares able to be exited.
     */
    function convertToExitShares(uint256 amount_) external view returns (uint256 shares_);

    /**
     *  @dev    Returns the amount unrealized losses.
     *  @return unrealizedLosses_ Amount of unrealized losses.
     */
    function unrealizedLosses() external view returns (uint256 unrealizedLosses_);

}
