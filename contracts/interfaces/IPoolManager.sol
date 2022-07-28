// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IPoolManagerStorage } from "./IPoolManagerStorage.sol";

interface IPoolManager is IPoolManagerStorage {

    /***************************/
    /*** Migration Functions ***/
    /***************************/

    function migrate(address migrator_, bytes calldata arguments_) external;

    function setImplementation(address implementation_) external;

    function upgrade(uint256 version_, bytes calldata arguments_) external;

    /************************************/
    /*** Ownership Transfer Functions ***/
    /************************************/

    function acceptPendingPoolDelegate() external;

    function setPendingPoolDelegate(address pendingPoolDelegate_) external;

    /********************************/
    /*** Administrative Functions ***/
    /********************************/

    function setActive(bool active_) external;

    function setAllowedLender(address lender_, bool isValid_) external;

    function setLiquidityCap(uint256 liquidityCap_) external;

    function setLoanManager(address loanManager_, bool isValid_) external;

    function setManagementFee(uint256 fee_) external;

    function setOpenToPublic() external;

    function setWithdrawalManager(address withdrawalManager_) external;

    /**********************/
    /*** Loan Functions ***/
    /**********************/

    function claim(address loan_) external;

    function fund(uint256 principal_, address loan_, address loanManager_) external;

    /*****************************/
    /*** Liquidation Functions ***/
    /*****************************/

    function decreaseUnrealizedLosses(uint256 decrement_) external;

    function finishCollateralLiquidation(address loan_) external;

    function triggerCollateralLiquidation(address loan_, address auctioneer_) external;

    /**********************/
    /*** Exit Functions ***/
    /**********************/

    function redeem(uint256 shares_, address receiver_, address owner_) external returns (uint256 assets_);

    /***********************/
    /*** Cover Functions ***/
    /***********************/

    function depositCover(uint256 amount_) external;

    function withdrawCover(uint256 amount_, address recipient_) external;

    /**********************/
    /*** View Functions ***/
    /**********************/

    function canCall(bytes32 functionId_, address caller_, bytes memory data_) external view returns (bool canCall_, string memory errorMessage_);

    function factory() external view returns (address factory_);

    function implementation() external view returns (address implementation_);

    function totalAssets() external view returns (uint256 totalAssets_);

}
