// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";

import { ERC20Helper }           from "../modules/erc20-helper/src/ERC20Helper.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import {
    IERC20Like,
    IGlobalsLike,
    ILoanManagerLike,
    IPoolCoverManagerLike,
    IPoolLike
} from "./interfaces/Interfaces.sol";

import { PoolManagerStorage } from "./proxy/PoolManagerStorage.sol";

// TODO: Inherit interface
contract PoolManager is MapleProxiedInternals, PoolManagerStorage {

    uint256 constant HUNDRED_PERCENT = 1e18;

    /***************************/
    /*** Migration Functions ***/
    /***************************/

    // TODO: Add functions for upgrading: `setImplementation` and `upgrade`

    function migrate(address migrator_, bytes calldata arguments_) external {
        require(msg.sender == _factory(),        "PM:M:NOT_FACTORY");
        require(_migrate(migrator_, arguments_), "PM:M:FAILED");
    }

    /************************************/
    /*** Ownership Transfer Functions ***/
    /************************************/

    function acceptPendingAdmin() external {
        require(msg.sender == pendingAdmin, "PM:APA:NOT_PENDING_ADMIN");

        admin        = pendingAdmin;
        pendingAdmin = address(0);
    }

    function setPendingAdmin(address pendingAdmin_) external {
        require(msg.sender == admin, "PM:SPA:NOT_ADMIN");

        pendingAdmin = pendingAdmin_;
    }

    /********************************/
    /*** Administrative Functions ***/
    /********************************/

    function setActive(bool active_) external {
        require(msg.sender == globals, "PM:SA:NOT_GLOBALS");

        active = active_;
    }

    function setAllowedLender(address lender_, bool isValid_) external {
        require(msg.sender == admin, "PM:SAL:NOT_ADMIN");

        isValidLender[lender_] = isValid_;
    }

    function setCoverFee(uint256 fee_) external {
        require(msg.sender == admin, "PM:SCF:NOT_ADMIN");

        // TODO check globals for boundaries
        coverFee = fee_;
    }

    function setLoanManager(address loanManager_, bool isValid_) external {
        require(msg.sender == admin, "PM:SIM:NOT_ADMIN");

        isLoanManager[loanManager_] = isValid_;

        loanManagerList.push(loanManager_);  // TODO: Add removal functionality
    }

    function setLiquidityCap(uint256 liquidityCap_) external {
        require(msg.sender == admin, "PM:SLC:NOT_ADMIN");

        liquidityCap = liquidityCap_;  // TODO: Add range check call to globals
    }

    function setManagementFee(uint256 fee_) external {
        require(msg.sender == admin, "PM:SMF:NOT_ADMIN");

        // TODO check globals for boundaries
        managementFee = fee_;
    }

    function setOpenToPublic() external {
        require(msg.sender == admin, "PM:SOTP:NOT_ADMIN");

        openToPublic = true;
    }

    function setPoolCoverManager(address poolCoverManager_) external {
        require(msg.sender == admin, "PM:SPCM:NOT_ADMIN");

        poolCoverManager = poolCoverManager_;
    }

    function setWithdrawalManager(address withdrawalManager_) external {
        require(msg.sender == admin, "PM:SWM:NOT_ADMIN");

        withdrawalManager = withdrawalManager_;
    }

    /**********************/
    /*** Loan Functions ***/
    /**********************/

    function claim(address loan_) external {
        require(IERC20Like(pool).totalSupply() != 0, "P:C:ZERO_SUPPLY");

        ( uint256 coverPortion_, uint256 managementPortion_ ) = ILoanManagerLike(loanManagers[loan_]).claim(loan_);

        address coverManager_ = poolCoverManager;
        address asset_        = asset;
        address globals_      = globals;

        // Send portion to cover.
        require(ERC20Helper.transfer(asset_, coverManager_, coverPortion_), "PM:C:PAY_COVER_FAILED");
        IPoolCoverManagerLike(coverManager_).allocateLiquidity();

        // Split Management Fee.
        uint256 mapleShare_ = managementPortion_ * IGlobalsLike(globals_).managementFeeSplit(pool) / HUNDRED_PERCENT;

        // Pay treasury.
        require(ERC20Helper.transfer(asset_, IGlobalsLike(globals_).mapleTreasury(), mapleShare_), "PM:C:PAY_TREASURY_FAILED");

        // Pay Pool Delegate.
        require(ERC20Helper.transfer(asset_, admin, managementPortion_ - mapleShare_), "PM:C:PAY_ADMIN_FAILED");
    }

    function fund(uint256 principal_, address loan_, address loanManager_) external {
        require(msg.sender == admin,                 "PM:F:NOT_ADMIN");
        require(IERC20Like(pool).totalSupply() != 0, "PM:F:ZERO_SUPPLY");

        loanManagers[loan_] = loanManager_;

        // TODO: This contract needs infinite allowance of asset from pool.
        require(ERC20Helper.transferFrom(asset, pool, loan_, principal_), "P:F:TRANSFER_FAIL");

        ILoanManagerLike(loanManager_).fund(loan_);
    }

    /*****************************/
    /*** Liquidation Functions ***/
    /*****************************/

    // TODO: Investigate all return variables that are currently being used.
    function decreaseUnrealizedLosses(uint256 decrement_) external returns (uint256 remainingUnrealizedLosses_) {
        // TODO: ACL

        unrealizedLosses            -= decrement_;
        remainingUnrealizedLosses_   = unrealizedLosses;
    }

    // TODO: ACL here and IM
    function triggerCollateralLiquidation(address loan_, address auctioneer_) external {
        unrealizedLosses += ILoanManagerLike(loanManagers[loan_]).triggerCollateralLiquidation(loan_, auctioneer_);
    }

    function finishCollateralLiquidation(address loan_) external returns (uint256 remainingLosses_) {
        uint256 decreasedUnrealizedLosses;
        ( decreasedUnrealizedLosses, remainingLosses_ ) = ILoanManagerLike(loanManagers[loan_]).finishCollateralLiquidation(loan_);

        unrealizedLosses -= decreasedUnrealizedLosses;

        // TODO: Dust threshold?
        if (remainingLosses_ > 0) {
            IPoolCoverManagerLike(poolCoverManager).triggerCoverLiquidation(remainingLosses_);
        }
    }

    /**********************/
    /*** Exit Functions ***/
    /**********************/

    function redeem(uint256 shares_, address receiver_, address owner_) external returns (uint256 assets_) {
        require(msg.sender == withdrawalManager, "PM:R:NOT_WM");

        return IPoolLike(pool).redeem(shares_, receiver_, owner_);
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function canCall(bytes32 functionId_, address caller_, bytes memory data_) external view returns (bool canCall_, string memory errorMessage_) {
        bool willRevert_;

        if (functionId_ == "P:deposit") {
            ( uint256 assets_, address receiver_ ) = abi.decode(data_, (uint256, address));
            ( willRevert_, errorMessage_ ) = _canDeposit(assets_, receiver_, "P:D:");
        }

        else if (functionId_ == "P:depositWithPermit") {
            ( uint256 assets_, address receiver_, , , , ) = abi.decode(data_, (uint256, address, uint256, uint8, bytes32, bytes32));
            ( willRevert_, errorMessage_ ) = _canDeposit(assets_, receiver_, "P:DWP:");
        }

        if (functionId_ == "P:mint") {
            ( uint256 shares_, address receiver_ ) = abi.decode(data_, (uint256, address));
            ( willRevert_, errorMessage_ ) = _canDeposit(IPoolLike(pool).previewMint(shares_), receiver_, "P:M:");
        }

        else if (functionId_ == "P:mintWithPermit") {
            ( uint256 shares_, address receiver_, , , , , ) = abi.decode(data_, (uint256, address, uint256, uint256, uint8, bytes32, bytes32));
            ( willRevert_, errorMessage_ ) = _canDeposit(IPoolLike(pool).previewMint(shares_), receiver_, "P:MWP:");
        }

        else if (functionId_ == "P:transfer") {
            ( address recipient_, ) = abi.decode(data_, (address, uint256));
            ( willRevert_, errorMessage_ ) = _canTransfer(recipient_, "P:T:");
        }

        else if (functionId_ == "P:transferFrom") {
            ( , address recipient_, ) = abi.decode(data_, (address, address, uint256));
            ( willRevert_, errorMessage_ ) = _canTransfer(recipient_, "P:TF:");
        }

        canCall_ = !willRevert_;  // TODO: Don't love this, but returning `willRevert` seems counterintuitive here
    }

    function factory() external view returns (address factory_) {
        return _factory();
    }

    function getFees() external view returns (uint256 coverFee_, uint256 managementFee_) {
        coverFee_      = coverFee;
        managementFee_ = managementFee;
    }

    function implementation() external view returns (address implementation_) {
        return _implementation();
    }

    function totalAssets() public view returns (uint256 totalAssets_) {
        totalAssets_ = IERC20Like(asset).balanceOf(pool);

        uint256 length = loanManagerList.length;

        for (uint256 i = 0; i < length;) {
            // TODO: How to check if unrecognized losses should be included?
            totalAssets_ += ILoanManagerLike(loanManagerList[i]).assetsUnderManagement();
            unchecked { i++; }
        }
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _canDeposit(uint256 assets_, address receiver_, string memory errorPrefix_) internal view returns (bool willRevert_, string memory errorMessage_) {
        if (!openToPublic && !isValidLender[receiver_]) return (true, _formatErrorMessage(errorPrefix_, "LENDER_NOT_ALLOWED"));
        if (assets_ + totalAssets() > liquidityCap)     return (true, _formatErrorMessage(errorPrefix_, "DEPOSIT_GT_LIQ_CAP"));
    }

    function _canTransfer(address recipient_, string memory errorPrefix_) internal view returns (bool willRevert_, string memory errorMessage_) {
        if (!openToPublic && !isValidLender[recipient_]) return (true, _formatErrorMessage(errorPrefix_, "RECIPIENT_NOT_ALLOWED"));
    }

    function _formatErrorMessage(string memory errorPrefix_, string memory partialError_) internal pure returns (string memory errorMessage_) {
        errorMessage_ = string(abi.encodePacked(errorPrefix_, partialError_));
    }

}
