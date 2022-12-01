// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import { ERC20Helper }           from "../modules/erc20-helper/src/ERC20Helper.sol";
import { IMapleProxyFactory }    from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";
import { IMapleProxied }         from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxied.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import { PoolManagerStorage } from "./proxy/PoolManagerStorage.sol";

import {
    IERC20Like,
    ILoanFactoryLike,
    ILoanManagerLike,
    IMapleGlobalsLike,
    IMapleLoanLike,
    IPoolDelegateCoverLike,
    IPoolLike,
    IWithdrawalManagerLike
} from "./interfaces/Interfaces.sol";

import { IPoolManager } from "./interfaces/IPoolManager.sol";

/*

    ██████╗  ██████╗  ██████╗ ██╗         ███╗   ███╗ █████╗ ███╗   ██╗ █████╗  ██████╗ ███████╗██████╗
    ██╔══██╗██╔═══██╗██╔═══██╗██║         ████╗ ████║██╔══██╗████╗  ██║██╔══██╗██╔════╝ ██╔════╝██╔══██╗
    ██████╔╝██║   ██║██║   ██║██║         ██╔████╔██║███████║██╔██╗ ██║███████║██║  ███╗█████╗  ██████╔╝
    ██╔═══╝ ██║   ██║██║   ██║██║         ██║╚██╔╝██║██╔══██║██║╚██╗██║██╔══██║██║   ██║██╔══╝  ██╔══██╗
    ██║     ╚██████╔╝╚██████╔╝███████╗    ██║ ╚═╝ ██║██║  ██║██║ ╚████║██║  ██║╚██████╔╝███████╗██║  ██║
    ╚═╝      ╚═════╝  ╚═════╝ ╚══════╝    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝

*/

contract PoolManager is IPoolManager, MapleProxiedInternals, PoolManagerStorage {

    uint256 public constant HUNDRED_PERCENT = 100_0000;  // Four decimal precision.

    /******************************************************************************************************************************/
    /*** Modifiers                                                                                                              ***/
    /******************************************************************************************************************************/

    modifier nonReentrant() {
        require(_locked == 1, "PM:LOCKED");

        _locked = 2;

        _;

        _locked = 1;
    }

    /******************************************************************************************************************************/
    /*** Migration Functions                                                                                                    ***/
    /******************************************************************************************************************************/

    // NOTE: Can't add whenProtocolNotPaused modifier here, as globals won't be set until
    //       initializer.initialize() is called, and this function is what triggers that initialization.
    function migrate(address migrator_, bytes calldata arguments_) external override {
        require(msg.sender == _factory(),        "PM:M:NOT_FACTORY");
        require(_migrate(migrator_, arguments_), "PM:M:FAILED");
        require(poolDelegateCover != address(0), "PM:M:DELEGATE_NOT_SET");
    }

    function setImplementation(address implementation_) external override {
        require(msg.sender == _factory(), "PM:SI:NOT_FACTORY");
        _setImplementation(implementation_);
    }

    function upgrade(uint256 version_, bytes calldata arguments_) external override {
        address poolDelegate_ = poolDelegate;

        require(msg.sender == poolDelegate_ || msg.sender == governor(), "PM:U:NOT_AUTHORIZED");

        IMapleGlobalsLike mapleGlobals_ = IMapleGlobalsLike(globals());

        if (msg.sender == poolDelegate_) {
            require(mapleGlobals_.isValidScheduledCall(msg.sender, address(this), "PM:UPGRADE", msg.data), "PM:U:INVALID_SCHED_CALL");

            mapleGlobals_.unscheduleCall(msg.sender, "PM:UPGRADE", msg.data);
        }

        IMapleProxyFactory(_factory()).upgradeInstance(version_, arguments_);
    }

    /******************************************************************************************************************************/
    /*** Initial Configuration Function                                                                                         ***/
    /******************************************************************************************************************************/

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

    /******************************************************************************************************************************/
    /*** Ownership Transfer Functions                                                                                           ***/
    /******************************************************************************************************************************/

    function acceptPendingPoolDelegate() external override {
        _whenProtocolNotPaused();

        require(msg.sender == pendingPoolDelegate, "PM:APPD:NOT_PENDING_PD");

        IMapleGlobalsLike(globals()).transferOwnedPoolManager(poolDelegate, msg.sender);

        emit PendingDelegateAccepted(poolDelegate, pendingPoolDelegate);

        poolDelegate        = pendingPoolDelegate;
        pendingPoolDelegate = address(0);
    }

    function setPendingPoolDelegate(address pendingPoolDelegate_) external override {
        _whenProtocolNotPaused();

        address poolDelegate_ = poolDelegate;

        require(msg.sender == poolDelegate_, "PM:SPA:NOT_PD");

        pendingPoolDelegate = pendingPoolDelegate_;

        emit PendingDelegateSet(poolDelegate_, pendingPoolDelegate_);
    }

    /******************************************************************************************************************************/
    /*** Globals Admin Functions                                                                                                ***/
    /******************************************************************************************************************************/

    function setActive(bool active_) external override {
        _whenProtocolNotPaused();

        require(msg.sender == globals(), "PM:SA:NOT_GLOBALS");
        emit SetAsActive(active = active_);
    }

    /******************************************************************************************************************************/
    /*** Pool Delegate OR Governor Admin Functions                                                                              ***/
    /******************************************************************************************************************************/

    function setAllowedSlippage(address loanManager_, address collateralAsset_, uint256 allowedSlippage_) external override {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate || msg.sender == governor(), "PM:SAS:NOT_AUTHORIZED");
        require(isLoanManager[loanManager_],                            "PM:SAS:NOT_LM");

        ILoanManagerLike(loanManager_).setAllowedSlippage(collateralAsset_, allowedSlippage_);
    }

    function setMinRatio(address loanManager_, address collateralAsset_, uint256 minRatio_) external override {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate || msg.sender == governor(), "PM:SMR:NOT_AUTHORIZED");
        require(isLoanManager[loanManager_],                            "PM:SMR:NOT_LM");

        ILoanManagerLike(loanManager_).setMinRatio(collateralAsset_, minRatio_);
    }

    /******************************************************************************************************************************/
    /*** Pool Delegate Admin Functions                                                                                          ***/
    /******************************************************************************************************************************/

    function addLoanManager(address loanManager_) external override {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate,   "PM:ALM:NOT_PD");
        require(!isLoanManager[loanManager_], "PM:ALM:DUP_LM");

        isLoanManager[loanManager_] = true;

        loanManagerList.push(loanManager_);

        emit LoanManagerAdded(loanManager_);
    }

    function removeLoanManager(address loanManager_) external override {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate,  "PM:RLM:NOT_PD");
        require(isLoanManager[loanManager_], "PM:RLM:INVALID_LM");

        isLoanManager[loanManager_] = false;

        // Find loan manager index
        uint256 i_;
        while (loanManagerList[i_] != loanManager_) i_++;

        // Move last element to index of removed loan manager and pop last element.
        loanManagerList[i_] = loanManagerList[loanManagerList.length - 1];
        loanManagerList.pop();

        emit LoanManagerRemoved(loanManager_);
    }

    function setAllowedLender(address lender_, bool isValid_) external override {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate, "PM:SAL:NOT_PD");
        emit AllowedLenderSet(lender_, isValidLender[lender_] = isValid_);
    }

    function setDelegateManagementFeeRate(uint256 delegateManagementFeeRate_) external override {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate,                    "PM:SDMFR:NOT_PD");
        require(delegateManagementFeeRate_ <= HUNDRED_PERCENT, "PM:SDMFR:OOB");

        emit DelegateManagementFeeRateSet(delegateManagementFeeRate = delegateManagementFeeRate_);
    }

    function setLiquidityCap(uint256 liquidityCap_) external override {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate, "PM:SLC:NOT_PD");
        emit LiquidityCapSet(liquidityCap = liquidityCap_);
    }

    function setOpenToPublic() external override {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate, "PM:SOTP:NOT_PD");
        openToPublic = true;
        emit OpenToPublic();
    }

    function setWithdrawalManager(address withdrawalManager_) external override {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate, "PM:SWM:NOT_PD");
        emit WithdrawalManagerSet(withdrawalManager = withdrawalManager_);  // NOTE: Can be zero in order to temporarily pause withdrawals.
    }

    /******************************************************************************************************************************/
    /*** Loan Funding and Refinancing Functions                                                                                 ***/
    /******************************************************************************************************************************/

    function acceptNewTerms(
        address loan_,
        address refinancer_,
        uint256 deadline_,
        bytes[] calldata calls_,
        uint256 principalIncrease_
    )
        external override nonReentrant
    {
        _whenProtocolNotPaused();

        address loanManager_ = _getLoanManager(loan_);

        _validateAndFundLoan(loan_, loanManager_, principalIncrease_);

        emit LoanRefinanced(loan_, refinancer_, deadline_, calls_, principalIncrease_);

        ILoanManagerLike(loanManager_).acceptNewTerms(loan_, refinancer_, deadline_, calls_);
    }

    function fund(uint256 principal_, address loan_, address loanManager_) external override nonReentrant {
        _whenProtocolNotPaused();

        _validateAndFundLoan(loan_, loanManager_, principal_);

        emit LoanFunded(loan_, loanManager_, principal_);

        ILoanManagerLike(loanManager_).fund(loan_);
    }

    /******************************************************************************************************************************/
    /*** Loan Impairment Functions                                                                                              ***/
    /******************************************************************************************************************************/

    function impairLoan(address loan_) external override {
        _whenProtocolNotPaused();

        bool isGovernor_ = msg.sender == governor();

        require(msg.sender == poolDelegate || isGovernor_, "PM:IL:NOT_AUTHORIZED");

        ILoanManagerLike(_getLoanManager(loan_)).impairLoan(loan_, isGovernor_);

        emit LoanImpaired(loan_, IMapleLoanLike(loan_).nextPaymentDueDate());  // The change of due date already happened in the loan contract, so we just need to fetch.
    }

    function removeLoanImpairment(address loan_) external override nonReentrant {
        _whenProtocolNotPaused();

        bool isGovernor_ = msg.sender == governor();

        require(msg.sender == poolDelegate || isGovernor_, "PM:RLI:NOT_AUTHORIZED");

        ILoanManagerLike(_getLoanManager(loan_)).removeLoanImpairment(loan_, isGovernor_);

        emit LoanImpairmentRemoved(loan_);
    }

    /******************************************************************************************************************************/
    /*** Loan Default Functions                                                                                                 ***/
    /******************************************************************************************************************************/

    function finishCollateralLiquidation(address loan_) external override nonReentrant {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate || msg.sender == governor(), "PM:FCL:NOT_AUTHORIZED");

        ( uint256 losses_, uint256 platformFees_ ) = ILoanManagerLike(_getLoanManager(loan_)).finishCollateralLiquidation(loan_);

        _handleCover(losses_, platformFees_);

        emit CollateralLiquidationFinished(loan_, losses_);
    }

    function triggerDefault(address loan_, address liquidatorFactory_) external override nonReentrant {
        _whenProtocolNotPaused();

        bool isFactory_ = IMapleGlobalsLike(globals()).isFactory("LIQUIDATOR", liquidatorFactory_);

        require(msg.sender == poolDelegate || msg.sender == governor(), "PM:TD:NOT_AUTHORIZED");
        require(isFactory_,                                             "PM:TD:NOT_FACTORY");

        (
            bool    liquidationComplete_,
            uint256 losses_,
            uint256 platformFees_
        ) = ILoanManagerLike(_getLoanManager(loan_)).triggerDefault(loan_, liquidatorFactory_);

        if (!liquidationComplete_) {
            emit CollateralLiquidationTriggered(loan_);
            return;
        }

        _handleCover(losses_, platformFees_);

        emit CollateralLiquidationFinished(loan_, losses_);
    }

    /******************************************************************************************************************************/
    /*** Pool Exit Functions                                                                                                    ***/
    /******************************************************************************************************************************/

    function processRedeem(uint256 shares_, address owner_, address sender_) external override nonReentrant returns (uint256 redeemableShares_, uint256 resultingAssets_) {
        _whenProtocolNotPaused();

        require(msg.sender == pool, "PM:PR:NOT_POOL");

        require(owner_ == sender_ || IPoolLike(pool).allowance(owner_, sender_) > 0, "PM:PR:NO_ALLOWANCE");

        ( redeemableShares_, resultingAssets_ ) = IWithdrawalManagerLike(withdrawalManager).processExit(shares_, owner_);
        emit RedeemProcessed(owner_, redeemableShares_, resultingAssets_);
    }

    function processWithdraw(uint256 assets_, address owner_, address sender_) external override nonReentrant returns (uint256 redeemableShares_, uint256 resultingAssets_) {
        _whenProtocolNotPaused();

        assets_; owner_; sender_; redeemableShares_; resultingAssets_;  // Silence compiler warnings
        require(false, "PM:PW:NOT_ENABLED");
    }

    function removeShares(uint256 shares_, address owner_) external override nonReentrant returns (uint256 sharesReturned_) {
        _whenProtocolNotPaused();

        require(msg.sender == pool, "PM:RS:NOT_POOL");

        emit SharesRemoved(
            owner_,
            sharesReturned_ = IWithdrawalManagerLike(withdrawalManager).removeShares(shares_, owner_)
        );
    }

    function requestRedeem(uint256 shares_, address owner_, address sender_) external override nonReentrant {
        _whenProtocolNotPaused();

        address pool_ = pool;

        require(msg.sender == pool_,                                    "PM:RR:NOT_POOL");
        require(ERC20Helper.approve(pool_, withdrawalManager, shares_), "PM:RR:APPROVE_FAIL");

        if (sender_ != owner_ && shares_ == 0) {
            require(IPoolLike(pool_).allowance(owner_, sender_) > 0, "PM:RR:NO_ALLOWANCE");
        }

        IWithdrawalManagerLike(withdrawalManager).addShares(shares_, owner_);

        emit RedeemRequested(owner_, shares_);
    }

    function requestWithdraw(uint256 shares_, uint256 assets_, address owner_, address sender_) external override nonReentrant {
        _whenProtocolNotPaused();

        shares_; assets_; owner_; sender_;  // Silence compiler warnings
        require(false, "PM:RW:NOT_ENABLED");
    }

    /******************************************************************************************************************************/
    /*** Pool Delegate Cover Functions                                                                                          ***/
    /******************************************************************************************************************************/

    function depositCover(uint256 amount_) external override {
        _whenProtocolNotPaused();

        require(ERC20Helper.transferFrom(asset, msg.sender, poolDelegateCover, amount_), "PM:DC:TRANSFER_FAIL");
        emit CoverDeposited(amount_);
    }

    function withdrawCover(uint256 amount_, address recipient_) external override {
        _whenProtocolNotPaused();

        require(msg.sender == poolDelegate, "PM:WC:NOT_PD");

        recipient_ = recipient_ == address(0) ? msg.sender : recipient_;

        IPoolDelegateCoverLike(poolDelegateCover).moveFunds(amount_, recipient_);

        require(
            IERC20Like(asset).balanceOf(poolDelegateCover) >= IMapleGlobalsLike(globals()).minCoverAmount(address(this)),
            "PM:WC:BELOW_MIN"
        );

        emit CoverWithdrawn(amount_);
    }

    /******************************************************************************************************************************/
    /*** Internal Helper Functions                                                                                              ***/
    /******************************************************************************************************************************/

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

    function _validateAndFundLoan(address loan_, address loanManager_, uint256 principal_) internal {
        address asset_   = asset;
        address globals_ = globals();
        address pool_    = pool;

        require(msg.sender == poolDelegate,                                               "PM:VAFL:NOT_PD");
        require(isLoanManager[loanManager_],                                              "PM:VAFL:INVALID_LOAN_MANAGER");
        require(IMapleGlobalsLike(globals_).isBorrower(IMapleLoanLike(loan_).borrower()), "PM:VAFL:INVALID_BORROWER");
        require(IERC20Like(pool_).totalSupply() != 0,                                     "PM:VAFL:ZERO_SUPPLY");
        require(_hasSufficientCover(globals_, asset_),                                    "PM:VAFL:INSUFFICIENT_COVER");
        require(IMapleLoanLike(loan_).paymentsRemaining() != 0,                           "PM:VAFL:LOAN_NOT_ACTIVE");

        address loanFactory_ = IMapleProxied(loan_).factory();

        require(IMapleGlobalsLike(globals_).isFactory("LOAN", loanFactory_), "PM:VAFL:INVALID_LOAN_FACTORY");
        require(ILoanFactoryLike(loanFactory_).isLoan(loan_),                "PM:VAFL:INVALID_LOAN_INSTANCE");

        // If loan has unaccounted funds then skim the funds to the pool as cash.
        if (IMapleLoanLike(loan_).getUnaccountedAmount(asset_) > 0) {
            IMapleLoanLike(loan_).skim(asset_, pool_);
        }

        // Fetching locked liquidity needs to be done prior to transferring the tokens.
        uint256 lockedLiquidity_ = IWithdrawalManagerLike(withdrawalManager).lockedLiquidity();

        // Transfer the required principal.
        require(ERC20Helper.transferFrom(asset_, pool_, loan_, principal_), "PM:VAFL:TRANSFER_FAIL");

        // The remaining liquidity in the pool must be greater or equal to the locked liquidity.
        require(IERC20Like(asset_).balanceOf(pool_) >= lockedLiquidity_, "PM:VAFL:LOCKED_LIQUIDITY");
    }

    function _getLoanManager(address loan_) internal view returns (address loanManager_) {
        address loanFactory_ = IMapleProxied(loan_).factory();

        require(IMapleGlobalsLike(globals()).isFactory("LOAN", loanFactory_), "PM:GVLL:INVALID_LOAN_FACTORY");
        require(ILoanFactoryLike(loanFactory_).isLoan(loan_),                 "PM:GVLL:INVALID_LOAN_INSTANCE");

        loanManager_ = IMapleLoanLike(loan_).lender();

        require(isLoanManager[loanManager_], "PM:GVLL:INVALID_LOAN_MANAGER");
    }

    /******************************************************************************************************************************/
    /*** View Functions                                                                                                         ***/
    /******************************************************************************************************************************/

    function canCall(bytes32 functionId_, address, bytes memory data_) external view override returns (bool canCall_, string memory errorMessage_) {
        // NOTE: `caller_` param not named to avoid compiler warning.

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
        globals_ = IMapleProxyFactory(_factory()).mapleGlobals();
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

    /******************************************************************************************************************************/
    /*** LP Token View Functions                                                                                                ***/
    /******************************************************************************************************************************/

    function convertToExitShares(uint256 assets_) public view override returns (uint256 shares_) {
        shares_ = IPoolLike(pool).convertToExitShares(assets_);
    }

    function getEscrowParams(address, uint256 shares_) external view override returns (uint256 escrowShares_, address destination_) {
        // NOTE: `owner_` param not named to avoid compiler warning.
        ( escrowShares_, destination_) = (shares_, address(this));
    }

    function maxDeposit(address receiver_) external view virtual override returns (uint256 maxAssets_) {
        maxAssets_ = _getMaxAssets(receiver_, totalAssets());
    }

    function maxMint(address receiver_) external view virtual override returns (uint256 maxShares_) {
        uint256 totalAssets_ = totalAssets();
        uint256 maxAssets_   = _getMaxAssets(receiver_, totalAssets_);

        maxShares_ = IPoolLike(pool).previewDeposit(maxAssets_);
    }

    function maxRedeem(address owner_) external view virtual override returns (uint256 maxShares_) {
        uint256 lockedShares_ = IWithdrawalManagerLike(withdrawalManager).lockedShares(owner_);
        maxShares_            = IWithdrawalManagerLike(withdrawalManager).isInExitWindow(owner_) ? lockedShares_ : 0;
    }

    function maxWithdraw(address owner_) external view virtual override returns (uint256 maxAssets_) {
        owner_; maxAssets_;  // Silence compiler warning
        return 0;  // NOTE: always returns 0 as withdraw is not implemented
    }

    function previewRedeem(address owner_, uint256 shares_) external view virtual override returns (uint256 assets_) {
        ( , assets_ ) = IWithdrawalManagerLike(withdrawalManager).previewRedeem(owner_, shares_);
    }

    function previewWithdraw(address owner_, uint256 assets_) external view virtual override returns (uint256 shares_) {
        ( , shares_ ) = IWithdrawalManagerLike(withdrawalManager).previewWithdraw(owner_, assets_);
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

    /******************************************************************************************************************************/
    /*** Internal Functions                                                                                                     ***/
    /******************************************************************************************************************************/

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

    // Necessary to reduce bytecode size.
    function _whenProtocolNotPaused() internal view {
        require(!IMapleGlobalsLike(globals()).protocolPaused(), "PM:PROTOCOL_PAUSED");
    }

}
