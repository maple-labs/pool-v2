// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils } from "../modules/contract-test-utils/contracts/test.sol";

import { ERC20Helper }           from "../modules/erc20-helper/src/ERC20Helper.sol";
import { IMapleProxyFactory }    from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import {
    IERC20Like,
    IGlobalsLike,
    ILoanLike,
    ILoanManagerLike,
    IPoolDelegateCoverLike,
    IPoolLike
} from "./interfaces/Interfaces.sol";

import { IPoolManager } from "./interfaces/IPoolManager.sol";

import { PoolManagerStorage } from "./proxy/PoolManagerStorage.sol";

contract PoolManager is IPoolManager, MapleProxiedInternals, PoolManagerStorage {

    uint256 public constant HUNDRED_PERCENT = 1e18;

    /*****************/
    /*** Modifiers ***/
    /*****************/

    modifier whenProtocolNotPaused {
        require(!IGlobalsLike(globals).protocolPaused(), "PM:PROTOCOL_PAUSED");
        _;
    }

    /***************************/
    /*** Migration Functions ***/
    /***************************/

    /**
     *  @dev NOTE: Can't add whenProtocolNotPaused modifier here, as globals won't be set until
     *             initializer.initialize() is called, and this function is what triggers that initialization.
     */
    function migrate(address migrator_, bytes calldata arguments_) external override {
        require(msg.sender == _factory(),        "PM:M:NOT_FACTORY");
        require(_migrate(migrator_, arguments_), "PM:M:FAILED");
    }

    function setImplementation(address implementation_) external override whenProtocolNotPaused {
        require(msg.sender == _factory(), "PM:SI:NOT_FACTORY");

        _setImplementation(implementation_);
    }

    function upgrade(uint256 version_, bytes calldata arguments_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:U:NOT_PD");

        IMapleProxyFactory(_factory()).upgradeInstance(version_, arguments_);
    }

    /************************************/
    /*** Ownership Transfer Functions ***/
    /************************************/

    // TODO: Add PD transfer check
    function acceptPendingPoolDelegate() external override whenProtocolNotPaused {
        require(msg.sender == pendingPoolDelegate, "PM:APA:NOT_PENDING_PD");

        poolDelegate        = pendingPoolDelegate;
        pendingPoolDelegate = address(0);
    }

    function setPendingPoolDelegate(address pendingPoolDelegate_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SPA:NOT_PD");

        pendingPoolDelegate = pendingPoolDelegate_;
    }

    /********************************/
    /*** Administrative Functions ***/
    /********************************/

    function configure(address loanManager_, address withdrawalManager_, uint256 liquidityCap_, uint256 delegateManagementFeeRate_) external override {
        require(!configured,                                      "PM:CO:ALREADY_CONFIGURED");
        require(IGlobalsLike(globals).isPoolDeployer(msg.sender), "PM:CO:NOT_DEPLOYER");

        configured                  = true;
        isLoanManager[loanManager_] = true;
        withdrawalManager           = withdrawalManager_;
        liquidityCap                = liquidityCap_;
        delegateManagementFeeRate   = delegateManagementFeeRate_;

        loanManagerList.push(loanManager_);
    }

    function addLoanManager(address loanManager_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate,   "PM:ALM:NOT_PD");
        require(!isLoanManager[loanManager_], "PM:ALM:DUP_LM");

        isLoanManager[loanManager_] = true;

        loanManagerList.push(loanManager_);
    }

    function removeLoanManager(address loanManager_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:RLM:NOT_PD");

        isLoanManager[loanManager_] = false;

        // Find loan manager index
        uint256 i = 0;
        while (loanManagerList[i] != loanManager_) i++;

        // Move last element to index of removed loan manager and pop last element.
        loanManagerList[i] = loanManagerList[loanManagerList.length - 1];
        loanManagerList.pop();
    }

    function setActive(bool active_) external override whenProtocolNotPaused {
        require(msg.sender == globals, "PM:SA:NOT_GLOBALS");

        active = active_;
    }

    function setAllowedLender(address lender_, bool isValid_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SAL:NOT_PD");

        isValidLender[lender_] = isValid_;
    }

    function setLiquidityCap(uint256 liquidityCap_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SLC:NOT_PD");

        liquidityCap = liquidityCap_;  // TODO: Add range check call to globals
    }

    function setDelegateManagementFeeRate(uint256 delegateManagementFeeRate_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SDMFR:NOT_PD");

        require(delegateManagementFeeRate_ + IGlobalsLike(globals).platformManagementFeeRate(address(this)) <= HUNDRED_PERCENT, "PM:SDMFR:OOB");

        // TODO check globals for boundaries
        delegateManagementFeeRate = delegateManagementFeeRate_;
    }

    function setOpenToPublic() external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SOTP:NOT_PD");

        openToPublic = true;
    }

    function setWithdrawalManager(address withdrawalManager_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SWM:NOT_PD");

        withdrawalManager = withdrawalManager_;
    }

    /**********************/
    /*** Loan Functions ***/
    /**********************/

    function acceptNewTerms(
        address loan_,
        address refinancer_,
        uint256 deadline_,
        bytes[] calldata calls_,
        uint256 principalIncrease_
    )
        external override whenProtocolNotPaused
    {
        address asset_   = asset;
        address globals_ = globals;
        address pool_    = pool;

        address loanManager_ = loanManagers[loan_];

        require(msg.sender == poolDelegate,                                     "PM:ANT:NOT_PD");
        require(isLoanManager[loanManager_],                                    "PM:ANT:INVALID_LOAN_MANAGER");
        require(IGlobalsLike(globals_).isBorrower(ILoanLike(loan_).borrower()), "PM:ANT:INVALID_BORROWER");
        require(IERC20Like(pool_).totalSupply() != 0,                           "PM:ANT:ZERO_SUPPLY");
        require(_hasSufficientCover(globals_, asset_),                          "PM:ANT:INSUFFICIENT_COVER");

        require(ERC20Helper.transferFrom(asset_, pool_, loan_, principalIncrease_), "P:F:TRANSFER_FAIL");

        ILoanManagerLike(loanManager_).acceptNewTerms(loan_, refinancer_, deadline_, calls_, principalIncrease_);
    }

    // TODO: Investigate why gas costs are so high for funding
    function fund(uint256 principal_, address loan_, address loanManager_) external override whenProtocolNotPaused {
        address asset_   = asset;
        address globals_ = globals;
        address pool_    = pool;

        require(msg.sender == poolDelegate,                                     "PM:F:NOT_PD");
        require(isLoanManager[loanManager_],                                    "PM:F:INVALID_LOAN_MANAGER");
        require(IGlobalsLike(globals_).isBorrower(ILoanLike(loan_).borrower()), "PM:F:INVALID_BORROWER");
        require(IERC20Like(pool_).totalSupply() != 0,                           "PM:F:ZERO_SUPPLY");
        require(_hasSufficientCover(globals_, asset_),                          "PM:F:INSUFFICIENT_COVER");

        loanManagers[loan_] = loanManager_;

        require(ERC20Helper.transferFrom(asset_, pool_, loan_, principal_), "P:F:TRANSFER_FAIL");

        ILoanManagerLike(loanManager_).fund(loan_);
    }

    /*****************************/
    /*** Liquidation Functions ***/
    /*****************************/

    function triggerCollateralLiquidation(address loan_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:TCL:NOT_PD");
        unrealizedLosses += ILoanManagerLike(loanManagers[loan_]).triggerCollateralLiquidation(loan_);
    }

    // TODO: I think this liquidation flow needs business validation.
    function finishCollateralLiquidation(address loan_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:FCL:NOT_PD");
        ( uint256 principalToCover_, uint256 remainingLosses_ ) = ILoanManagerLike(loanManagers[loan_]).finishCollateralLiquidation(loan_);

        unrealizedLosses -= principalToCover_;

        uint256 coverBalance_ = IERC20Like(asset).balanceOf(poolDelegateCover);

        if (coverBalance_ != 0 && remainingLosses_ != 0) {
            uint256 maxLiquidationAmount_ = coverBalance_ * IGlobalsLike(globals).maxCoverLiquidationPercent(pool) / HUNDRED_PERCENT;
            uint256 liquidationAmount_    = remainingLosses_ > maxLiquidationAmount_ ? maxLiquidationAmount_ : remainingLosses_ ;

            IPoolDelegateCoverLike(poolDelegateCover).moveFunds(liquidationAmount_, pool);
        }
    }

    /**********************/
    /*** Exit Functions ***/
    /**********************/

    function redeem(uint256 shares_, address receiver_, address owner_) external override whenProtocolNotPaused returns (uint256 assets_) {
        require(msg.sender == withdrawalManager, "PM:R:NOT_WM");

        return IPoolLike(pool).redeem(shares_, receiver_, owner_);
    }

    /***********************/
    /*** Cover Functions ***/
    /***********************/

    // TODO: implement deposit cover with permit
    function depositCover(uint256 amount_) external override whenProtocolNotPaused {
        require(ERC20Helper.transferFrom(asset, msg.sender, poolDelegateCover, amount_), "PM:DC:TRANSFER_FAIL");
    }

    function withdrawCover(uint256 amount_, address recipient_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:WC:NOT_PD");
        require(
            amount_ <= (IERC20Like(asset).balanceOf(poolDelegateCover) - IGlobalsLike(globals).minCoverAmount(address(this))),
            "PM:WC:BELOW_MIN"
        );

        recipient_ = recipient_ == address(0) ? msg.sender : recipient_;

        IPoolDelegateCoverLike(poolDelegateCover).moveFunds(amount_, recipient_);
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function canCall(bytes32 functionId_, address caller_, bytes memory data_) external view override returns (bool canCall_, string memory errorMessage_) {
        bool willRevert_;

        if (IGlobalsLike(globals).protocolPaused()) return (false, "PROTOCOL_PAUSED");

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

        canCall_ = !willRevert_;
    }

    function factory() external view override returns (address factory_) {
        return _factory();
    }

    function hasSufficientCover() public view returns (bool hasSufficientCover_) {
        hasSufficientCover_ = _hasSufficientCover(globals, asset);
    }

    function implementation() external view override returns (address implementation_) {
        return _implementation();
    }

    function totalAssets() public view override returns (uint256 totalAssets_) {
        totalAssets_ = IERC20Like(asset).balanceOf(pool);

        uint256 length = loanManagerList.length;

        for (uint256 i = 0; i < length;) {
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

    function _hasSufficientCover(address globals_, address asset_) internal view returns (bool hasSufficientCover_) {
        hasSufficientCover_ = IERC20Like(asset_).balanceOf(poolDelegateCover) >= IGlobalsLike(globals_).minCoverAmount(address(this));
    }

}

// TODO: Add emission of events.
