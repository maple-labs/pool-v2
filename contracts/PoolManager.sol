// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { ERC20Helper }           from "../modules/erc20-helper/src/ERC20Helper.sol";
import { IMapleProxyFactory }    from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import {
    IERC20Like,
    ILoanLike,
    ILoanManagerLike,
    IMapleGlobalsLike,
    IPoolDelegateCoverLike,
    IPoolLike,
    IWithdrawalManagerLike
} from "./interfaces/Interfaces.sol";

import { IPoolManager } from "./interfaces/IPoolManager.sol";

import { PoolManagerStorage } from "./proxy/PoolManagerStorage.sol";

contract PoolManager is IPoolManager, MapleProxiedInternals, PoolManagerStorage {

    uint256 public constant HUNDRED_PERCENT = 1e18;

    /*****************/
    /*** Modifiers ***/
    /*****************/

    modifier whenProtocolNotPaused {
        require(!IMapleGlobalsLike(globals).protocolPaused(), "PM:PROTOCOL_PAUSED");
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
        address poolDelegate_ = poolDelegate;

        require(msg.sender == poolDelegate_ || msg.sender == governor(), "PM:U:NOT_AUTHORIZED");

        IMapleGlobalsLike mapleGlobals = IMapleGlobalsLike(globals);

        if (msg.sender == poolDelegate_) {
            require(mapleGlobals.isValidScheduledCall(msg.sender, address(this), "PM:UPGRADE", msg.data), "PM:U:NOT_SCHEDULED");

            mapleGlobals.unscheduleCall(msg.sender, "PM:UPGRADE", msg.data);
        }

        IMapleProxyFactory(_factory()).upgradeInstance(version_, arguments_);
    }

    /************************************/
    /*** Ownership Transfer Functions ***/
    /************************************/

    function acceptPendingPoolDelegate() external override whenProtocolNotPaused {
        require(msg.sender == pendingPoolDelegate, "PM:APPD:NOT_PENDING_PD");

        IMapleGlobalsLike(globals).transferOwnedPoolManager(poolDelegate, msg.sender);

        emit PendingDelegateAccepted(poolDelegate, pendingPoolDelegate);

        poolDelegate        = pendingPoolDelegate;
        pendingPoolDelegate = address(0);
    }

    function setPendingPoolDelegate(address pendingPoolDelegate_) external override whenProtocolNotPaused {
        address poolDelegate_ = poolDelegate;

        require(msg.sender == poolDelegate_, "PM:SPA:NOT_PD");

        pendingPoolDelegate = pendingPoolDelegate_;

        emit PendingDelegateSet(poolDelegate_, pendingPoolDelegate_);
    }

    /********************************/
    /*** Administrative Functions ***/
    /********************************/

    function configure(address loanManager_, address withdrawalManager_, uint256 liquidityCap_, uint256 delegateManagementFeeRate_) external override {
        require(!configured,                                           "PM:CO:ALREADY_CONFIGURED");
        require(IMapleGlobalsLike(globals).isPoolDeployer(msg.sender), "PM:CO:NOT_DEPLOYER");

        configured                  = true;
        isLoanManager[loanManager_] = true;
        withdrawalManager           = withdrawalManager_;
        liquidityCap                = liquidityCap_;
        delegateManagementFeeRate   = delegateManagementFeeRate_;

        loanManagerList.push(loanManager_);

        emit PoolConfigured(loanManager_, withdrawalManager_, liquidityCap_, delegateManagementFeeRate_);
    }

    function addLoanManager(address loanManager_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate,   "PM:ALM:NOT_PD");
        require(!isLoanManager[loanManager_], "PM:ALM:DUP_LM");

        isLoanManager[loanManager_] = true;

        loanManagerList.push(loanManager_);

        emit LoanManagerAdded(loanManager_);
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

        emit LoanManagerRemoved(loanManager_);
    }

    function setActive(bool active_) external override whenProtocolNotPaused {
        require(msg.sender == globals, "PM:SA:NOT_GLOBALS");

        active = active_;

        emit SetAsActive(active_);
    }

    function setAllowedLender(address lender_, bool isValid_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SAL:NOT_PD");

        isValidLender[lender_] = isValid_;

        emit AllowedLenderSet(lender_, isValid_);
    }

    function setLiquidityCap(uint256 liquidityCap_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SLC:NOT_PD");

        liquidityCap = liquidityCap_;  // TODO: Add range check call to globals

        emit LiquidityCapSet(liquidityCap_);
    }

    function setDelegateManagementFeeRate(uint256 delegateManagementFeeRate_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate,                    "PM:SDMFR:NOT_PD");
        require(delegateManagementFeeRate_ <= HUNDRED_PERCENT, "PM:SDMFR:OOB");

        delegateManagementFeeRate = delegateManagementFeeRate_;

        emit DelegateManagementFeeRateSet(delegateManagementFeeRate_);
    }

    function setOpenToPublic() external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SOTP:NOT_PD");

        openToPublic = true;

        emit OpenToPublic();
    }

    function setWithdrawalManager(address withdrawalManager_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SWM:NOT_PD");

        withdrawalManager = withdrawalManager_;

        emit WithdrawalManagerSet(withdrawalManager_);
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

        require(msg.sender == poolDelegate,                                          "PM:ANT:NOT_PD");
        require(isLoanManager[loanManager_],                                         "PM:ANT:INVALID_LOAN_MANAGER");
        require(IMapleGlobalsLike(globals_).isBorrower(ILoanLike(loan_).borrower()), "PM:ANT:INVALID_BORROWER");
        require(IERC20Like(pool_).totalSupply() != 0,                                "PM:ANT:ZERO_SUPPLY");
        require(_hasSufficientCover(globals_, asset_),                               "PM:ANT:INSUFFICIENT_COVER");

        require(ERC20Helper.transferFrom(asset_, pool_, loan_, principalIncrease_), "P:F:TRANSFER_FAIL");

        ILoanManagerLike(loanManager_).acceptNewTerms(loan_, refinancer_, deadline_, calls_, principalIncrease_);

        emit LoanRefinanced(loan_, refinancer_, deadline_, calls_, principalIncrease_);
    }

    // TODO: Investigate why gas costs are so high for funding
    function fund(uint256 principal_, address loan_, address loanManager_) external override whenProtocolNotPaused {
        address asset_   = asset;
        address globals_ = globals;
        address pool_    = pool;

        require(msg.sender == poolDelegate,                                          "PM:F:NOT_PD");
        require(isLoanManager[loanManager_],                                         "PM:F:INVALID_LOAN_MANAGER");
        require(IMapleGlobalsLike(globals_).isBorrower(ILoanLike(loan_).borrower()), "PM:F:INVALID_BORROWER");
        require(IERC20Like(pool_).totalSupply() != 0,                                "PM:F:ZERO_SUPPLY");
        require(_hasSufficientCover(globals_, asset_),                               "PM:F:INSUFFICIENT_COVER");

        loanManagers[loan_] = loanManager_;

        require(ERC20Helper.transferFrom(asset_, pool_, loan_, principal_), "PM:F:TRANSFER_FAIL");

        uint256 remainingLiquidity_ = IERC20Like(asset_).balanceOf(address(pool_));
        uint256 lockedLiquidity_    = IWithdrawalManagerLike(withdrawalManager).lockedLiquidity();

        require(remainingLiquidity_ >= lockedLiquidity_, "PM:F:LOCKED_LIQUIDITY");

        ILoanManagerLike(loanManager_).fund(loan_);

        emit LoanFunded(loan_, loanManager_, principal_);
    }

    /*****************************/
    /*** Liquidation Functions ***/
    /*****************************/

    function triggerCollateralLiquidation(address loan_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:TCL:NOT_PD");
        ILoanManagerLike(loanManagers[loan_]).triggerCollateralLiquidation(loan_);

        emit CollateralLiquidationTriggered(loan_);
    }

    function triggerDefaultWarning(address loan_, uint256 newPaymentDueDate_) external override {
        bool isGovernor_ = msg.sender == governor();

        require(msg.sender == poolDelegate || isGovernor_, "PM:TDW:NOT_AUTHORIZED");

        ILoanManagerLike(loanManagers[loan_]).triggerDefaultWarning(loan_, newPaymentDueDate_, isGovernor_);

        emit DefaultWarningTriggered(loan_, newPaymentDueDate_);
    }

    function finishCollateralLiquidation(address loan_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:FCL:NOT_PD");

        address globals_ = globals;

        ( uint256 losses_, uint256 platformFees_ ) = ILoanManagerLike(loanManagers[loan_]).finishCollateralLiquidation(loan_);

        uint256 availableCover_ = IERC20Like(asset).balanceOf(poolDelegateCover) * IMapleGlobalsLike(globals_).maxCoverLiquidationPercent(address(this)) / HUNDRED_PERCENT;

        uint256 toTreasury_ = _min(availableCover_,               platformFees_);
        uint256 toPool_     = _min(availableCover_ - toTreasury_, losses_);

        if (toTreasury_ != 0) {
            IPoolDelegateCoverLike(poolDelegateCover).moveFunds(toTreasury_, IMapleGlobalsLike(globals_).mapleTreasury());
        }

        if (toPool_ != 0) {
            IPoolDelegateCoverLike(poolDelegateCover).moveFunds(toPool_, pool);
        }

        emit CollateralLiquidationFinished(loan_, losses_);
    }

    function removeDefaultWarning(address loan_) external override whenProtocolNotPaused {
        bool isGovernor_ = msg.sender == governor();

        require(msg.sender == poolDelegate || isGovernor_, "PM:RDW:NOT_AUTHORIZED");

        ILoanManagerLike(loanManagers[loan_]).removeDefaultWarning(loan_, isGovernor_);

        emit DefaultWarningRemoved(loan_);
    }

    /**********************/
    /*** Exit Functions ***/
    /**********************/

    function processRedeem(uint256 shares_, address owner_) external override whenProtocolNotPaused returns (uint256 redeemableShares_, uint256 resultingAssets_) {
        require(msg.sender == pool, "PM:PR:NOT_POOL");
        ( redeemableShares_, resultingAssets_ ) = IWithdrawalManagerLike(withdrawalManager).processExit(owner_, shares_);

        emit RedeemProcessed(owner_, redeemableShares_, resultingAssets_);
    }

    function processWithdraw(uint256 assets_, address owner_) external override whenProtocolNotPaused returns (uint256 redeemableShares_, uint256 resultingAssets_) {
        require(msg.sender == pool, "PM:PW:NOT_POOL");
        ( redeemableShares_, resultingAssets_ ) = IWithdrawalManagerLike(withdrawalManager).processExit(owner_, convertToExitShares(assets_));

        emit WithdrawalProcessed(owner_, redeemableShares_, resultingAssets_);
    }

    function removeShares(uint256 shares_, address owner_) external override whenProtocolNotPaused returns (uint256 sharesReturned_) {
        require(msg.sender == pool, "PM:RS:NOT_POOL");

        sharesReturned_ = IWithdrawalManagerLike(withdrawalManager).removeShares(shares_, owner_);

        emit SharesRemoved(owner_, sharesReturned_);
    }

    function requestRedeem(uint256 shares_, address owner_) external override whenProtocolNotPaused {
        require(msg.sender == pool, "PM:RR:NOT_POOL");

        IPoolLike(pool).approve(withdrawalManager, shares_);

        IWithdrawalManagerLike(withdrawalManager).addShares(shares_, owner_);

        emit RedeemRequested(owner_, shares_);
    }

    /***********************/
    /*** Cover Functions ***/
    /***********************/

    // TODO: implement deposit cover with permit
    function depositCover(uint256 amount_) external override whenProtocolNotPaused {
        require(ERC20Helper.transferFrom(asset, msg.sender, poolDelegateCover, amount_), "PM:DC:TRANSFER_FAIL");

        emit CoverDeposited(amount_);
    }

    function withdrawCover(uint256 amount_, address recipient_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:WC:NOT_PD");
        require(
            amount_ <= (IERC20Like(asset).balanceOf(poolDelegateCover) - IMapleGlobalsLike(globals).minCoverAmount(address(this))),
            "PM:WC:BELOW_MIN"
        );

        recipient_ = recipient_ == address(0) ? msg.sender : recipient_;

        IPoolDelegateCoverLike(poolDelegateCover).moveFunds(amount_, recipient_);

        emit CoverWithdrawn(amount_);
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function canCall(bytes32 functionId_, address caller_, bytes memory data_) external view override returns (bool canCall_, string memory errorMessage_) {
        bool willRevert_;

        if (IMapleGlobalsLike(globals).protocolPaused()) return (false, "PROTOCOL_PAUSED");

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
        factory_ = _factory();
    }

    function governor() public view override returns (address governor_) {
        governor_ = IMapleGlobalsLike(globals).governor();
    }

    function hasSufficientCover() public view override returns (bool hasSufficientCover_) {
        hasSufficientCover_ = _hasSufficientCover(globals, asset);
    }

    function implementation() external view override returns (address implementation_) {
        implementation_ = _implementation();
    }

    function totalAssets() public view override returns (uint256 totalAssets_) {
        totalAssets_ = IERC20Like(asset).balanceOf(pool);

        uint256 length = loanManagerList.length;

        for (uint256 i = 0; i < length;) {
            totalAssets_ += ILoanManagerLike(loanManagerList[i]).assetsUnderManagement();
            unchecked { i++; }
        }
    }

    /*******************************/
    /*** LP Token View Functions ***/
    /*******************************/

    function getEscrowParams(address owner_, uint256 shares_) external view override returns (uint256 escorwShares_, address destination) {
        return (shares_, address(this));
    }

    function convertToExitShares(uint256 assets_) public view override returns (uint256 shares_) {
        return IPoolLike(pool).convertToExitShares(assets_);
    }

    function maxDeposit(address receiver_) external view virtual override returns (uint256 maxAssets_) {
        maxAssets_ = _getMaxAssets(receiver_, totalAssets());
    }

    function maxMint(address receiver_) external view virtual override returns (uint256 maxShares_) {
        uint256 totalAssets_ = totalAssets();
        uint256 totalSupply_ = IPoolLike(pool).totalSupply();
        uint256 maxAssets_   = _getMaxAssets(receiver_, totalAssets_);

        maxShares_ = totalSupply_ == 0 ? maxAssets_ : maxAssets_ * totalSupply_ / totalAssets_;
    }

    function maxRedeem(address owner_) external view virtual override returns (uint256 maxShares_) {
        uint256 lockedShares_ = IWithdrawalManagerLike(withdrawalManager).lockedShares(owner_);

        maxShares_ = IWithdrawalManagerLike(withdrawalManager).isInExitWindow(owner_) ? lockedShares_ : 0;
    }

    function maxWithdraw(address owner_) external view virtual override returns (uint256 maxAssets_) {
        uint256 lockedShares_ = IWithdrawalManagerLike(withdrawalManager).lockedShares(owner_);
        uint256 maxShares_    = IWithdrawalManagerLike(withdrawalManager).isInExitWindow(owner_) ? lockedShares_ : 0;

        maxAssets_ = maxShares_ * (totalAssets() - unrealizedLosses()) / IPoolLike(pool).totalSupply();
    }

    function previewRedeem(address owner_, uint256 shares_) external view virtual override returns (uint256 assets_) {
        ( , assets_ ) = IWithdrawalManagerLike(withdrawalManager).previewRedeem(owner_, shares_);
    }

    function previewWithdraw(address owner_, uint256 assets_) external view virtual override returns (uint256 shares_) {
        ( shares_, ) = IWithdrawalManagerLike(withdrawalManager).previewRedeem(owner_, convertToExitShares(assets_));
    }

    function unrealizedLosses() public view override returns (uint256 unrealizedLosses_) {
        uint256 length = loanManagerList.length;

        for (uint256 i = 0; i < length;) {
            unrealizedLosses_ += ILoanManagerLike(loanManagerList[i]).unrealizedLosses();
            unchecked { i++; }
        }
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _canDeposit(uint256 assets_, address receiver_, string memory errorPrefix_) internal view returns (bool willRevert_, string memory errorMessage_) {
        if (!active)                                    return (true, _formatErrorMessage(errorPrefix_, "NOT_ACTIVE"));
        if (!openToPublic && !isValidLender[receiver_]) return (true, _formatErrorMessage(errorPrefix_, "LENDER_NOT_ALLOWED"));
        if (assets_ + totalAssets() > liquidityCap)     return (true, _formatErrorMessage(errorPrefix_, "DEPOSIT_GT_LIQ_CAP"));
    }

    function _canTransfer(address recipient_, string memory errorPrefix_) internal view returns (bool willRevert_, string memory errorMessage_) {
        if (!openToPublic && !isValidLender[recipient_]) return (true, _formatErrorMessage(errorPrefix_, "RECIPIENT_NOT_ALLOWED"));
    }

    function _formatErrorMessage(string memory errorPrefix_, string memory partialError_) internal pure returns (string memory errorMessage_) {
        errorMessage_ = string(abi.encodePacked(errorPrefix_, partialError_));
    }

    function _getMaxAssets(address receiver_, uint256 totalAssets_) internal view returns (uint256 maxAssets_) {
        bool depositAllowed = openToPublic || isValidLender[receiver_];

        uint256 liquidityCap_ = liquidityCap;

        maxAssets_ = liquidityCap_ > totalAssets_ && depositAllowed ? liquidityCap_ - totalAssets_ : 0;
    }

    function _hasSufficientCover(address globals_, address asset_) internal view returns (bool hasSufficientCover_) {
        hasSufficientCover_ = IERC20Like(asset_).balanceOf(poolDelegateCover) >= IMapleGlobalsLike(globals_).minCoverAmount(address(this));
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256 minimum_) {
        return a_ < b_ ? a_ : b_;
    }

}
