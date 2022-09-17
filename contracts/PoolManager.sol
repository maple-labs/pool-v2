// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { ERC20Helper }           from "../modules/erc20-helper/src/ERC20Helper.sol";
import { IMapleProxyFactory }    from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import {
    IERC20Like,
    ILoanManagerLike,
    IMapleGlobalsLike,
    IMapleLoanLike,
    IMapleProxyFactoryLike,
    IPoolDelegateCoverLike,
    IPoolLike,
    IWithdrawalManagerLike
} from "./interfaces/Interfaces.sol";

import { IPoolManager } from "./interfaces/IPoolManager.sol";

import { PoolManagerStorage } from "./proxy/PoolManagerStorage.sol";

contract PoolManager is IPoolManager, MapleProxiedInternals, PoolManagerStorage {

    uint256 public constant HUNDRED_PERCENT = 100_0000;  // Four decimal precision.

    /*****************/
    /*** Modifiers ***/
    /*****************/

    modifier nonReentrant() {
        require(_locked == 1, "P:LOCKED");

        _locked = 2;

        _;

        _locked = 1;
    }

    modifier whenProtocolNotPaused {
        require(!IMapleGlobalsLike(globals()).protocolPaused(), "PM:PROTOCOL_PAUSED");
        _;
    }

    /***************************/
    /*** Migration Functions ***/
    /***************************/

    // NOTE: Can't add whenProtocolNotPaused modifier here, as globals won't be set until
    //       initializer.initialize() is called, and this function is what triggers that initialization.
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

        IMapleGlobalsLike mapleGlobals_ = IMapleGlobalsLike(globals());

        if (msg.sender == poolDelegate_) {
            require(mapleGlobals_.isValidScheduledCall(msg.sender, address(this), "PM:UPGRADE", msg.data), "PM:U:INVALID_SCHED_CALL");

            mapleGlobals_.unscheduleCall(msg.sender, "PM:UPGRADE", msg.data);
        }

        IMapleProxyFactory(_factory()).upgradeInstance(version_, arguments_);
    }

    /************************************/
    /*** Ownership Transfer Functions ***/
    /************************************/

    function acceptPendingPoolDelegate() external override whenProtocolNotPaused {
        require(msg.sender == pendingPoolDelegate, "PM:APPD:NOT_PENDING_PD");

        IMapleGlobalsLike(globals()).transferOwnedPoolManager(poolDelegate, msg.sender);

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

    function addLoanManager(address loanManager_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate,   "PM:ALM:NOT_PD");
        require(!isLoanManager[loanManager_], "PM:ALM:DUP_LM");

        isLoanManager[loanManager_] = true;

        loanManagerList.push(loanManager_);

        emit LoanManagerAdded(loanManager_);
    }

    function configure(address loanManager_, address withdrawalManager_, uint256 liquidityCap_, uint256 delegateManagementFeeRate_) external override {
        require(!configured,                                             "PM:CO:ALREADY_CONFIGURED");
        require(IMapleGlobalsLike(globals()).isPoolDeployer(msg.sender), "PM:CO:NOT_DEPLOYER");
        require(delegateManagementFeeRate_ <= HUNDRED_PERCENT,           "PM:CO:OOB");

        configured                  = true;
        isLoanManager[loanManager_] = true;
        withdrawalManager           = withdrawalManager_;  // NOTE: Can be zero in order to temporarily pause withdrawals.
        liquidityCap                = liquidityCap_;
        delegateManagementFeeRate   = delegateManagementFeeRate_;

        loanManagerList.push(loanManager_);

        emit PoolConfigured(loanManager_, withdrawalManager_, liquidityCap_, delegateManagementFeeRate_);
    }

    function removeLoanManager(address loanManager_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:RLM:NOT_PD");

        isLoanManager[loanManager_] = false;

        // Find loan manager index
        uint256 i_ = 0;
        while (loanManagerList[i_] != loanManager_) i_++;

        // Move last element to index of removed loan manager and pop last element.
        loanManagerList[i_] = loanManagerList[loanManagerList.length - 1];
        loanManagerList.pop();

        emit LoanManagerRemoved(loanManager_);
    }

    function setActive(bool active_) external override whenProtocolNotPaused {
        require(msg.sender == globals(), "PM:SA:NOT_GLOBALS");
        emit SetAsActive(active = active_);
    }

    function setAllowedLender(address lender_, bool isValid_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SAL:NOT_PD");
        emit AllowedLenderSet(lender_, isValidLender[lender_] = isValid_);
    }

    function setAllowedSlippage(address loanManager_, address collateralAsset_, uint256 allowedSlippage_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate || msg.sender == governor(), "PM:SAS:NOT_AUTHORIZED");
        require(isLoanManager[loanManager_],                            "PM:SAS:NOT_LM");

        ILoanManagerLike(loanManager_).setAllowedSlippage(collateralAsset_, allowedSlippage_);
    }

    function setDelegateManagementFeeRate(uint256 delegateManagementFeeRate_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate,                    "PM:SDMFR:NOT_PD");
        require(delegateManagementFeeRate_ <= HUNDRED_PERCENT, "PM:SDMFR:OOB");

        emit DelegateManagementFeeRateSet(delegateManagementFeeRate = delegateManagementFeeRate_);
    }

    function setLiquidityCap(uint256 liquidityCap_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SLC:NOT_PD");
        // TODO: Add range check call to globals
        emit LiquidityCapSet(liquidityCap = liquidityCap_);
    }

    function setMinRatio(address loanManager_, address collateralAsset_, uint256 minRatio_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate || msg.sender == governor(), "PM:SMR:NOT_AUTHORIZED");
        require(isLoanManager[loanManager_],                            "PM:SMR:NOT_LM");

        ILoanManagerLike(loanManager_).setMinRatio(collateralAsset_, minRatio_);
    }

    function setOpenToPublic() external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SOTP:NOT_PD");
        openToPublic = true;
        emit OpenToPublic();
    }

    function setWithdrawalManager(address withdrawalManager_) external override whenProtocolNotPaused {
        require(msg.sender == poolDelegate, "PM:SWM:NOT_PD");
        emit WithdrawalManagerSet(withdrawalManager = withdrawalManager_);  // NOTE: Can be zero in order to temporarily pause withdrawals.
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
        external override whenProtocolNotPaused nonReentrant
    {
        address asset_       = asset;
        address globals_     = globals();
        address pool_        = pool;
        address loanManager_ = loanManagers[loan_];

        uint256 lockedLiquidity_ = IWithdrawalManagerLike(withdrawalManager).lockedLiquidity();

        require(msg.sender == poolDelegate,                                               "PM:ANT:NOT_PD");
        require(isLoanManager[loanManager_],                                              "PM:ANT:INVALID_LOAN_MANAGER");
        require(IMapleGlobalsLike(globals_).isBorrower(IMapleLoanLike(loan_).borrower()), "PM:ANT:INVALID_BORROWER");
        require(IERC20Like(pool_).totalSupply() != 0,                                     "PM:ANT:ZERO_SUPPLY");
        require(_hasSufficientCover(globals_, asset_),                                    "PM:ANT:INSUFFICIENT_COVER");
        require(ERC20Helper.transferFrom(asset_, pool_, loan_, principalIncrease_),       "PM:ANT:TRANSFER_FAIL");

        uint256 remainingLiquidity_ = IERC20Like(asset_).balanceOf(address(pool_));

        require(remainingLiquidity_ >= lockedLiquidity_, "PM:ANT:LOCKED_LIQUIDITY");

        ILoanManagerLike(loanManager_).acceptNewTerms(loan_, refinancer_, deadline_, calls_);

        emit LoanRefinanced(loan_, refinancer_, deadline_, calls_, principalIncrease_);
    }

    // TODO: Investigate why gas costs are so high for funding.
    function fund(uint256 principal_, address loan_, address loanManager_) external override whenProtocolNotPaused nonReentrant {
        address asset_   = asset;
        address globals_ = globals();
        address pool_    = pool;

        require(msg.sender == poolDelegate,                                               "PM:F:NOT_PD");
        require(isLoanManager[loanManager_],                                              "PM:F:INVALID_LOAN_MANAGER");
        require(IMapleGlobalsLike(globals_).isBorrower(IMapleLoanLike(loan_).borrower()), "PM:F:INVALID_BORROWER");
        require(IERC20Like(pool_).totalSupply() != 0,                                     "PM:F:ZERO_SUPPLY");
        require(_hasSufficientCover(globals_, asset_),                                    "PM:F:INSUFFICIENT_COVER");

        loanManagers[loan_] = loanManager_;

        uint256 unaccountedFunds_ = IMapleLoanLike(loan_).getUnaccountedAmount(asset_);

        // If loan already has more unaccounted for funds that required, then skim the funds to the pool as cash.
        // NOTE: Since we cannot skim a specific amount, we must take all of it and then funds back what is required.
        if (unaccountedFunds_ > principal_) {
            unaccountedFunds_ -= IMapleLoanLike(loan_).skim(asset_, pool_);
        }

        // Fetching locked liquidity needs to be done prior to transferring the tokens, because the withdrawal manager checks the pool balance to determine total assets.
        uint256 lockedLiquidity =  IWithdrawalManagerLike(withdrawalManager).lockedLiquidity();

        // If loan already has unaccounted for funds, but less that required, fewer funds are required to be transferred from the pool.
        if (principal_ > unaccountedFunds_) {
            require(ERC20Helper.transferFrom(asset_, pool_, loan_, principal_ - unaccountedFunds_), "PM:F:TRANSFER_FAIL");
        }

        // The remaining liquidity (i.e. the balance of the funds asset in the pool) msu be greater than the amount required ot be locked.
        require(IERC20Like(asset_).balanceOf(pool_) >= lockedLiquidity, "PM:F:LOCKED_LIQUIDITY");

        ILoanManagerLike(loanManager_).fund(loan_);

        emit LoanFunded(loan_, loanManager_, principal_);
    }

    /*****************************/
    /*** Liquidation Functions ***/
    /*****************************/

    function finishCollateralLiquidation(address loan_) external override whenProtocolNotPaused nonReentrant {
        require(msg.sender == poolDelegate || msg.sender == governor(), "PM:FCL:NOT_AUTHORIZED");

        ( uint256 losses_, uint256 platformFees_ ) = ILoanManagerLike(loanManagers[loan_]).finishCollateralLiquidation(loan_);

        _handleCover(losses_, platformFees_);

        emit CollateralLiquidationFinished(loan_, losses_);
    }

    function removeLoanImpairment(address loan_) external override whenProtocolNotPaused nonReentrant {
        bool isGovernor_ = msg.sender == governor();

        require(msg.sender == poolDelegate || isGovernor_, "PM:RDW:NOT_AUTHORIZED");

        ILoanManagerLike(loanManagers[loan_]).removeLoanImpairment(loan_, isGovernor_);

        emit LoanImpairmentRemoved(loan_);
    }

    function triggerDefault(address loan_, address liquidatorFactory_) external override whenProtocolNotPaused nonReentrant {
        bool isFactory_ = IMapleGlobalsLike(globals()).isFactory("LIQUIDATOR", liquidatorFactory_);

        require(msg.sender == poolDelegate || msg.sender == governor(), "PM:TD:NOT_AUTHORIZED");
        require(isFactory_,                                             "PM:TD:NOT_FACTORY");

        (
            bool    liquidationComplete_,
            uint256 losses_,
            uint256 platformFees_
        ) = ILoanManagerLike(loanManagers[loan_]).triggerDefault(loan_, liquidatorFactory_);

        if (!liquidationComplete_) {
            emit CollateralLiquidationTriggered(loan_);
            return;
        }

        _handleCover(losses_, platformFees_);

        emit CollateralLiquidationFinished(loan_, losses_);
    }

    function impairLoan(address loan_) external override {
        bool isGovernor_ = msg.sender == governor();

        require(msg.sender == poolDelegate || isGovernor_, "PM:IL:NOT_AUTHORIZED");

        ILoanManagerLike(loanManagers[loan_]).impairLoan(loan_, isGovernor_);

        emit LoanImpaired(loan_, block.timestamp);
    }

    /**********************/
    /*** Exit Functions ***/
    /**********************/

    // TODO: Should be called `processRedemption` and `RedemptionProcessed` for grammatical correctness. See `processWithdraw`.
    function processRedeem(uint256 shares_, address owner_) external override whenProtocolNotPaused nonReentrant returns (uint256 redeemableShares_, uint256 resultingAssets_) {
        require(msg.sender == pool, "PM:PR:NOT_POOL");
        ( redeemableShares_, resultingAssets_ ) = IWithdrawalManagerLike(withdrawalManager).processExit(owner_, shares_);
        emit RedeemProcessed(owner_, redeemableShares_, resultingAssets_);
    }

    function removeShares(uint256 shares_, address owner_) external override whenProtocolNotPaused nonReentrant returns (uint256 sharesReturned_) {
        require(msg.sender == pool, "PM:RS:NOT_POOL");

        emit SharesRemoved(
            owner_,
            sharesReturned_ = IWithdrawalManagerLike(withdrawalManager).removeShares(shares_, owner_)
        );
    }

    // TODO: Should be called `requestRedemption` and `RedemptionRequested` for grammatical correctness.
    function requestRedeem(uint256 shares_, address owner_) external override whenProtocolNotPaused nonReentrant {
        address pool_ = pool;

        require(msg.sender == pool_,                                    "PM:RR:NOT_POOL");
        require(ERC20Helper.approve(pool_, withdrawalManager, shares_), "PM:RR:APPROVE_FAIL");

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
            amount_ <= (IERC20Like(asset).balanceOf(poolDelegateCover) - IMapleGlobalsLike(globals()).minCoverAmount(address(this))),
            "PM:WC:BELOW_MIN"
        );

        recipient_ = recipient_ == address(0) ? msg.sender : recipient_;

        IPoolDelegateCoverLike(poolDelegateCover).moveFunds(amount_, recipient_);

        emit CoverWithdrawn(amount_);
    }

    /*********************************/
    /*** Internal Helper Functions ***/
    /*********************************/

    function _handleCover(uint256 losses_, uint256 platformFees_) internal {
        address globals_ = globals();

        uint256 availableCover_ = IERC20Like(asset).balanceOf(poolDelegateCover) * IMapleGlobalsLike(globals_).maxCoverLiquidationPercent(address(this)) / HUNDRED_PERCENT;
        uint256 toTreasury_     = _min(availableCover_,               platformFees_);
        uint256 toPool_         = _min(availableCover_ - toTreasury_, losses_);

        if (toTreasury_ != 0) {
            IPoolDelegateCoverLike(poolDelegateCover).moveFunds(toTreasury_, IMapleGlobalsLike(globals_).mapleTreasury());
        }

        if (toPool_ != 0) {
            IPoolDelegateCoverLike(poolDelegateCover).moveFunds(toPool_, pool);
        }
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function canCall(bytes32 functionId_, address caller_, bytes memory data_) external view override returns (bool canCall_, string memory errorMessage_) {
        if (IMapleGlobalsLike(globals()).protocolPaused()) {
            return (false, "PM:CC:PROTOCOL_PAUSED");
        }

        if (
            functionId_ == "P:redeem"          ||
            functionId_ == "P:withdraw"        ||
            functionId_ == "P:removeShares"    ||
            functionId_ == "P:requestRedeem"   ||
            functionId_ == "P:requestWithdraw"
        ) {
            return (true, "");
        }

        if (functionId_ == "P:deposit") {
            ( uint256 assets_, address receiver_ ) = abi.decode(data_, (uint256, address));
            return _canDeposit(assets_, receiver_, "P:D:");
        }

        if (functionId_ == "P:depositWithPermit") {
            ( uint256 assets_, address receiver_, , , , ) = abi.decode(data_, (uint256, address, uint256, uint8, bytes32, bytes32));
            return _canDeposit(assets_, receiver_, "P:DWP:");
        }

        if (functionId_ == "P:mint") {
            ( uint256 shares_, address receiver_ ) = abi.decode(data_, (uint256, address));
            return _canDeposit(IPoolLike(pool).previewMint(shares_), receiver_, "P:M:");
        }

        if (functionId_ == "P:mintWithPermit") {
            ( uint256 shares_, address receiver_, , , , , ) = abi.decode(data_, (uint256, address, uint256, uint256, uint8, bytes32, bytes32));
            return _canDeposit(IPoolLike(pool).previewMint(shares_), receiver_, "P:MWP:");
        }

        if (functionId_ == "P:transfer") {
            ( address recipient_, ) = abi.decode(data_, (address, uint256));
            return _canTransfer(recipient_, "P:T:");
        }

        if (functionId_ == "P:transferFrom") {
            ( , address recipient_, ) = abi.decode(data_, (address, address, uint256));
            return _canTransfer(recipient_, "P:TF:");
        }

        return (false, "PM:CC:INVALID_FUNCTION_ID");
    }

    function factory() external view override returns (address factory_) {
        factory_ = _factory();
    }

    function globals() public view override returns (address globals_) {
        globals_ = IMapleProxyFactoryLike(_factory()).mapleGlobals();
    }

    function governor() public view override returns (address governor_) {
        governor_ = IMapleGlobalsLike(globals()).governor();
    }

    function hasSufficientCover() public view override returns (bool hasSufficientCover_) {
        hasSufficientCover_ = _hasSufficientCover(globals(), asset);
    }

    function implementation() external view override returns (address implementation_) {
        implementation_ = _implementation();
    }

    function totalAssets() public view override returns (uint256 totalAssets_) {
        totalAssets_ = IERC20Like(asset).balanceOf(pool);

        uint256 length_ = loanManagerList.length;

        for (uint256 i_ = 0; i_ < length_;) {
            totalAssets_ += ILoanManagerLike(loanManagerList[i_]).assetsUnderManagement();
            unchecked { ++i_; }
        }
    }

    /*******************************/
    /*** LP Token View Functions ***/
    /*******************************/

    function convertToExitShares(uint256 assets_) public view override returns (uint256 shares_) {
        shares_ = IPoolLike(pool).convertToExitShares(assets_);
    }

    function getEscrowParams(address owner_, uint256 shares_) external view override returns (uint256 escrowShares_, address destination_) {
        ( escrowShares_, destination_) = (shares_, address(this));
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
        maxShares_            = IWithdrawalManagerLike(withdrawalManager).isInExitWindow(owner_) ? lockedShares_ : 0;
    }

    function maxWithdraw(address owner_) external view virtual override returns (uint256 maxAssets_) {
        uint256 lockedShares_ = IWithdrawalManagerLike(withdrawalManager).lockedShares(owner_);
        uint256 maxShares_    = IWithdrawalManagerLike(withdrawalManager).isInExitWindow(owner_) ? lockedShares_ : 0;
        maxAssets_            = maxShares_ * (totalAssets() - unrealizedLosses()) / IPoolLike(pool).totalSupply();
    }

    function previewRedeem(address owner_, uint256 shares_) external view virtual override returns (uint256 assets_) {
        ( , assets_ ) = IWithdrawalManagerLike(withdrawalManager).previewRedeem(owner_, shares_);
    }

    function previewWithdraw(address owner_, uint256 assets_) external view virtual override returns (uint256 shares_) {
        ( shares_, ) = IWithdrawalManagerLike(withdrawalManager).previewRedeem(owner_, convertToExitShares(assets_));
    }

    function unrealizedLosses() public view override returns (uint256 unrealizedLosses_) {
        uint256 length_ = loanManagerList.length;

        for (uint256 i_ = 0; i_ < length_;) {
            unrealizedLosses_ += ILoanManagerLike(loanManagerList[i_]).unrealizedLosses();
            unchecked { ++i_; }
        }

        // NOTE: Use minimum to prevent underflows in the case that `unrealizedLosses` includes late interest and `totalAssets` does not.
        unrealizedLosses_ = _min(unrealizedLosses_, totalAssets());
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _canDeposit(uint256 assets_, address receiver_, string memory errorPrefix_) internal view returns (bool canDeposit_, string memory errorMessage_) {
        if (!active)                                    return (false, _formatErrorMessage(errorPrefix_, "NOT_ACTIVE"));
        if (!openToPublic && !isValidLender[receiver_]) return (false, _formatErrorMessage(errorPrefix_, "LENDER_NOT_ALLOWED"));
        if (assets_ + totalAssets() > liquidityCap)     return (false, _formatErrorMessage(errorPrefix_, "DEPOSIT_GT_LIQ_CAP"));

        return (true, "");
    }

    function _canTransfer(address recipient_, string memory errorPrefix_) internal view returns (bool canTransfer_, string memory errorMessage_) {
        if (!openToPublic && !isValidLender[recipient_]) return (false, _formatErrorMessage(errorPrefix_, "RECIPIENT_NOT_ALLOWED"));

        return (true, "");
    }

    function _formatErrorMessage(string memory errorPrefix_, string memory partialError_) internal pure returns (string memory errorMessage_) {
        errorMessage_ = string(abi.encodePacked(errorPrefix_, partialError_));
    }

    function _getMaxAssets(address receiver_, uint256 totalAssets_) internal view returns (uint256 maxAssets_) {
        bool    depositAllowed_ = openToPublic || isValidLender[receiver_];
        uint256 liquidityCap_   = liquidityCap;
        maxAssets_              = liquidityCap_ > totalAssets_ && depositAllowed_ ? liquidityCap_ - totalAssets_ : 0;
    }

    function _hasSufficientCover(address globals_, address asset_) internal view returns (bool hasSufficientCover_) {
        hasSufficientCover_ = IERC20Like(asset_).balanceOf(poolDelegateCover) >= IMapleGlobalsLike(globals_).minCoverAmount(address(this));
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256 minimum_) {
        minimum_ = a_ < b_ ? a_ : b_;
    }

}
