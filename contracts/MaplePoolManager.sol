// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import { ERC20Helper }           from "../modules/erc20-helper/src/ERC20Helper.sol";
import { IMapleProxyFactory }    from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxyFactory.sol";
import { IMapleProxied }         from "../modules/maple-proxy-factory/contracts/interfaces/IMapleProxied.sol";
import { MapleProxiedInternals } from "../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";

import { MaplePoolManagerStorage } from "./proxy/MaplePoolManagerStorage.sol";

import {
    IERC20Like,
    IGlobalsLike,
    IPoolLike,
    IPoolPermissionManagerLike,
    IStrategyLike,
    IStrategyManagerLike,
    IWithdrawalManagerLike
} from "./interfaces/Interfaces.sol";

import { IMaplePoolManager } from "./interfaces/IMaplePoolManager.sol";

/*

   ███╗   ███╗ █████╗ ██████╗ ██╗     ███████╗
   ████╗ ████║██╔══██╗██╔══██╗██║     ██╔════╝
   ██╔████╔██║███████║██████╔╝██║     █████╗
   ██║╚██╔╝██║██╔══██║██╔═══╝ ██║     ██╔══╝
   ██║ ╚═╝ ██║██║  ██║██║     ███████╗███████╗
   ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝     ╚══════╝╚══════╝


   ██████╗  ██████╗  ██████╗ ██╗         ███╗   ███╗ █████╗ ███╗   ██╗ █████╗  ██████╗ ███████╗██████╗
   ██╔══██╗██╔═══██╗██╔═══██╗██║         ████╗ ████║██╔══██╗████╗  ██║██╔══██╗██╔════╝ ██╔════╝██╔══██╗
   ██████╔╝██║   ██║██║   ██║██║         ██╔████╔██║███████║██╔██╗ ██║███████║██║  ███╗█████╗  ██████╔╝
   ██╔═══╝ ██║   ██║██║   ██║██║         ██║╚██╔╝██║██╔══██║██║╚██╗██║██╔══██║██║   ██║██╔══╝  ██╔══██╗
   ██║     ╚██████╔╝╚██████╔╝███████╗    ██║ ╚═╝ ██║██║  ██║██║ ╚████║██║  ██║╚██████╔╝███████╗██║  ██║
   ╚═╝      ╚═════╝  ╚═════╝ ╚══════╝    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝

*/

contract MaplePoolManager is IMaplePoolManager, MapleProxiedInternals, MaplePoolManagerStorage {

    uint256 public constant HUNDRED_PERCENT = 100_0000;  // Four decimal precision.

    /**************************************************************************************************************************************/
    /*** Modifiers                                                                                                                      ***/
    /**************************************************************************************************************************************/

    modifier nonReentrant() {
        require(_locked == 1, "PM:LOCKED");

        _locked = 2;

        _;

        _locked = 1;
    }

    modifier onlyGovernorOrNotConfigured() {
        _revertIfConfiguredAndNotGovernor();
        _;
    }

    modifier onlyIfNotConfigured() {
        _revertIfConfigured();
        _;
    }

    modifier onlyProtocolAdminsOrNotConfigured() {
        _revertIfConfiguredAndNotProtocolAdmins();
        _;
    }

    modifier onlyPool() {
        _revertIfNotPool();
        _;
    }

    modifier onlyPoolDelegateOrProtocolAdmins() {
        _revertIfNeitherPoolDelegateNorProtocolAdmins();
        _;
    }

    modifier whenNotPaused() {
        _revertIfPaused();
        _;
    }

    /**************************************************************************************************************************************/
    /*** Migration Functions                                                                                                            ***/
    /**************************************************************************************************************************************/

    // NOTE: Can't add whenProtocolNotPaused modifier here, as globals won't be set until
    //       initializer.initialize() is called, and this function is what triggers that initialization.
    function migrate(address migrator_, bytes calldata arguments_) external override whenNotPaused {
        require(msg.sender == _factory(),        "PM:M:NOT_FACTORY");
        require(_migrate(migrator_, arguments_), "PM:M:FAILED");
    }

    function setImplementation(address implementation_) external override whenNotPaused {
        require(msg.sender == _factory(), "PM:SI:NOT_FACTORY");
        _setImplementation(implementation_);
    }

    function upgrade(uint256 version_, bytes calldata arguments_) external override whenNotPaused {
        IGlobalsLike globals_ = IGlobalsLike(globals());

        if (msg.sender == poolDelegate) {
            require(globals_.isValidScheduledCall(msg.sender, address(this), "PM:UPGRADE", msg.data), "PM:U:INVALID_SCHED_CALL");

            globals_.unscheduleCall(msg.sender, "PM:UPGRADE", msg.data);
        } else {
            require(msg.sender == globals_.securityAdmin(), "PM:U:NO_AUTH");
        }

        emit Upgraded(version_, arguments_);

        IMapleProxyFactory(_factory()).upgradeInstance(version_, arguments_);
    }

    /**************************************************************************************************************************************/
    /*** Initial Configuration Function                                                                                                 ***/
    /**************************************************************************************************************************************/

    // NOTE: This function is always called atomically during the deployment process so a DoS attack is not possible.
    function completeConfiguration() external override whenNotPaused onlyIfNotConfigured {
        configured = true;

        emit PoolConfigurationComplete();
    }

    /**************************************************************************************************************************************/
    /*** Ownership Transfer Functions                                                                                                   ***/
    /**************************************************************************************************************************************/

    function acceptPoolDelegate() external override whenNotPaused {
        require(msg.sender == pendingPoolDelegate, "PM:APD:NOT_PENDING_PD");

        IGlobalsLike(globals()).transferOwnedPoolManager(poolDelegate, msg.sender);

        emit PendingDelegateAccepted(poolDelegate, pendingPoolDelegate);

        poolDelegate        = pendingPoolDelegate;
        pendingPoolDelegate = address(0);
    }

    function setPendingPoolDelegate(address pendingPoolDelegate_) external override whenNotPaused onlyPoolDelegateOrProtocolAdmins {
        pendingPoolDelegate = pendingPoolDelegate_;

        emit PendingDelegateSet(poolDelegate, pendingPoolDelegate_);
    }

    /**************************************************************************************************************************************/
    /*** Globals Admin Functions                                                                                                        ***/
    /**************************************************************************************************************************************/

    function setActive(bool active_) external override whenNotPaused {
        require(msg.sender == globals(), "PM:SA:NOT_GLOBALS");
        emit SetAsActive(active = active_);
    }

    /**************************************************************************************************************************************/
    /*** Pool Delegate Admin Functions                                                                                                  ***/
    /**************************************************************************************************************************************/

    function addStrategy(address strategyFactory_, bytes32 salt_, bytes calldata extraDeploymentData_)
        external override whenNotPaused onlyGovernorOrNotConfigured returns (address strategy_)
    {
        require(IGlobalsLike(globals()).isInstanceOf("STRATEGY_FACTORY", strategyFactory_), "PM:AS:INVALID_FACTORY");

        strategy_ = IMapleProxyFactory(strategyFactory_).createInstance(
            bytes.concat(abi.encode(address(this)), extraDeploymentData_),
            salt_
        );

        isStrategy[strategy_] = true;

        strategyList.push(strategy_);

        // Check the accounting of the newly added strategy isn't broken.
        // NOTE: This can occur if a newly added CoreStrategy creates an accounting loop between two or more Maple pools.
        ( bool success_, ) = strategy_.staticcall(abi.encodeWithSelector(IStrategyLike.assetsUnderManagement.selector));

        require(success_, "PM:AS:AUM_FAILURE");

        emit StrategyAdded(strategy_);
    }

    function addStrategyManager(address strategyManager_) external override whenNotPaused onlyGovernorOrNotConfigured {
        require(!isStrategy[strategyManager_],                                  "PM:ASM:ALREADY_STRATEGY");
        require(!isStrategyManager[strategyManager_],                           "PM:ASM:ALREADY_STRATEGY_MANAGER");
        require(_isValidStrategyManager(strategyManager_),                      "PM:ASM:INVALID_STRATEGY_MANAGER");
        require(IStrategyManagerLike(strategyManager_).isAssetSupported(asset), "PM:ASM:ASSET_NOT_SUPPORTED");

        isStrategyManager[strategyManager_] = true;
        strategyList.push(strategyManager_);

        ( bool success_, ) = strategyManager_.staticcall(abi.encodeWithSelector(IStrategyManagerLike.assetsOf.selector, address(this)));

        require(success_, "PM:ASM:ASSETS_OF_FAILURE");

        emit StrategyManagerAdded(strategyManager_);
    }

    function setDelegateManagementFeeRate(uint256 delegateManagementFeeRate_)
        external override whenNotPaused onlyProtocolAdminsOrNotConfigured
    {
        require(delegateManagementFeeRate_ <= HUNDRED_PERCENT, "PM:SDMFR:OOB");

        emit DelegateManagementFeeRateSet(delegateManagementFeeRate = delegateManagementFeeRate_);
    }

    function setLiquidityCap(uint256 liquidityCap_) external override whenNotPaused onlyProtocolAdminsOrNotConfigured {
        emit LiquidityCapSet(liquidityCap = liquidityCap_);
    }

    function setStrategyCap(address strategy_, uint256 cap_) external override whenNotPaused onlyProtocolAdminsOrNotConfigured {
        require(strategyCapOf[strategy_] != cap_,                  "PM:SSC:NO_CHANGE");
        require(cap_ == 0 || _isValidStrategyOrManager(strategy_), "PM:SSC:NOT_STRATEGY_OR_MANAGER");

        strategyCapOf[strategy_] = cap_;

        emit StrategyCapSet(strategy_, cap_);
    }

    function setWithdrawalManager(address withdrawalManager_) external override whenNotPaused onlyIfNotConfigured {
        address factory_ = IMapleProxied(withdrawalManager_).factory();

        require(IGlobalsLike(globals()).isInstanceOf("WITHDRAWAL_MANAGER_QUEUE_FACTORY", factory_), "PM:SWM:INVALID_FACTORY");
        require(IMapleProxyFactory(factory_).isInstance(withdrawalManager_),                        "PM:SWM:INVALID_INSTANCE");

        emit WithdrawalManagerSet(withdrawalManager = withdrawalManager_);
    }

    function setPoolPermissionManager(address poolPermissionManager_) external override whenNotPaused onlyProtocolAdminsOrNotConfigured {
        require(IGlobalsLike(globals()).isInstanceOf("POOL_PERMISSION_MANAGER", poolPermissionManager_), "PM:SPPM:INVALID_INSTANCE");

        emit PoolPermissionManagerSet(poolPermissionManager = poolPermissionManager_);
    }

    /**************************************************************************************************************************************/
    /*** Funding Functions                                                                                                              ***/
    /**************************************************************************************************************************************/

    // TODO: Confirm that old cyclical WM pools will be able to request funds.
    function requestFunds(address destination_, uint256 amount_) external override whenNotPaused nonReentrant {
        address pool_   = pool;
        address caller_ = msg.sender;

        require(destination_                    != address(0), "PM:RF:ZERO_DESTINATION");
        require(amount_                         != 0,          "PM:RF:ZERO_AMOUNT");
        require(IERC20Like(pool_).totalSupply() != 0,          "PM:RF:ZERO_SUPPLY");
        require(_isValidStrategyOrManager(caller_),            "PM:RF:INVALID_STRATEGY_OR_MANAGER");

        require(_assetsUnderManagement(caller_) + amount_ <= strategyCapOf[caller_], "PM:RF:STRATEGY_CAP");

        require(ERC20Helper.transferFrom(asset, pool_, destination_, amount_), "PM:RF:TRANSFER_FAIL");
    }

    /**************************************************************************************************************************************/
    /*** Pool Exit Functions                                                                                                            ***/
    /**************************************************************************************************************************************/

    function processRedeem(uint256 shares_, address owner_, address sender_)
        external override whenNotPaused nonReentrant onlyPool returns (uint256 redeemableShares_, uint256 resultingAssets_)
    {
        require(owner_ == sender_ || IPoolLike(pool).allowance(owner_, sender_) > 0, "PM:PR:NO_ALLOWANCE");

        ( redeemableShares_, resultingAssets_ ) = IWithdrawalManagerLike(withdrawalManager).processExit(shares_, owner_);
        emit RedeemProcessed(owner_, redeemableShares_, resultingAssets_);
    }

    function processWithdraw(uint256 assets_, address owner_, address sender_)
        external override whenNotPaused nonReentrant returns (uint256 redeemableShares_, uint256 resultingAssets_)
    {
        assets_; owner_; sender_; redeemableShares_; resultingAssets_;  // Silence compiler warnings
        require(false, "PM:PW:NOT_ENABLED");
    }

    function removeShares(uint256 shares_, address owner_)
        external override whenNotPaused nonReentrant onlyPool returns (uint256 sharesReturned_)
    {
        emit SharesRemoved(
            owner_,
            sharesReturned_ = IWithdrawalManagerLike(withdrawalManager).removeShares(shares_, owner_)
        );
    }

    function requestRedeem(uint256 shares_, address owner_, address sender_) external override whenNotPaused nonReentrant onlyPool {
        address pool_ = pool;

        require(ERC20Helper.approve(pool_, withdrawalManager, shares_), "PM:RR:APPROVE_FAIL");

        if (sender_ != owner_ && shares_ == 0) {
            require(IPoolLike(pool_).allowance(owner_, sender_) > 0, "PM:RR:NO_ALLOWANCE");
        }

        IWithdrawalManagerLike(withdrawalManager).addShares(shares_, owner_);

        emit RedeemRequested(owner_, shares_);
    }

    function requestWithdraw(uint256 shares_, uint256 assets_, address owner_, address sender_)
        external override whenNotPaused nonReentrant
    {
        shares_; assets_; owner_; sender_;  // Silence compiler warnings
        require(false, "PM:RW:NOT_ENABLED");
    }

    /**************************************************************************************************************************************/
    /*** View Functions                                                                                                                 ***/
    /**************************************************************************************************************************************/

    function canCall(bytes32 functionId_, address caller_, bytes calldata data_)
        external view override returns (bool canCall_, string memory errorMessage_)
    {
        if (IGlobalsLike(globals()).isFunctionPaused(msg.sig)) return (false, "PM:CC:PAUSED");

        uint256[3] memory params_ = _decodeParameters(data_);

        uint256 assets_ = params_[0];
        address lender_ = _address(params_[1]);

        // For mint functions there's a need to convert shares into assets.
        if (functionId_ == "P:mint" || functionId_ == "P:mintWithPermit") assets_ = IPoolLike(pool).previewMint(params_[0]);

        // Redeem and withdraw require getting the third word from the calldata.
        if ( functionId_ == "P:redeem" || functionId_ == "P:withdraw") lender_ = _address(params_[2]);

        // Transfers need to check both the sender and the recipient.
        if (functionId_ == "P:transfer" || functionId_ == "P:transferFrom") {
            address[] memory lenders_ = new address[](2);

            ( lenders_[0], lenders_[1] ) = functionId_ == "P:transfer" ?
                (caller_,              _address(params_[0])) :
                (_address(params_[0]), _address(params_[1]));

            // Check both lenders in a single call.
            if (!IPoolPermissionManagerLike(poolPermissionManager).hasPermission(address(this), lenders_, functionId_)) {
                return (false, "PM:CC:NOT_ALLOWED");
            }

        } else {
            if (!IPoolPermissionManagerLike(poolPermissionManager).hasPermission(address(this), lender_, functionId_)) {
                return (false, "PM:CC:NOT_ALLOWED");
            }
        }

        if (
            functionId_ == "P:redeem"          ||
            functionId_ == "P:withdraw"        ||
            functionId_ == "P:removeShares"    ||
            functionId_ == "P:requestRedeem"   ||
            functionId_ == "P:requestWithdraw" ||
            functionId_ == "P:transfer"        ||
            functionId_ == "P:transferFrom"
        ) return (true, "");

        if (
            functionId_ == "P:deposit"           ||
            functionId_ == "P:depositWithPermit" ||
            functionId_ == "P:mint"              ||
            functionId_ == "P:mintWithPermit"
        ) return _canDeposit(assets_);

        return (false, "PM:CC:INVALID_FUNCTION_ID");
    }

    function factory() external view override returns (address factory_) {
        factory_ = _factory();
    }

    function globals() public view override returns (address globals_) {
        globals_ = IMapleProxyFactory(_factory()).mapleGlobals();
    }

    function governor() public view override returns (address governor_) {
        governor_ = IGlobalsLike(globals()).governor();
    }

    // Pool delegate cover is deprecated; always reports as sufficient so downstream loan-manager fee logic keeps paying the delegate.
    function hasSufficientCover() public pure override returns (bool hasSufficientCover_) {
        hasSufficientCover_ = true;
    }

    function implementation() external view override returns (address implementation_) {
        implementation_ = _implementation();
    }

    function strategyListLength() external view override returns (uint256 strategyListLength_) {
        strategyListLength_ = strategyList.length;
    }

    function totalAssets() public view override returns (uint256 totalAssets_) {
        totalAssets_ = IERC20Like(asset).balanceOf(pool);

        uint256 length_ = strategyList.length;

        for (uint256 i_; i_ < length_; i_++) {
            totalAssets_ += _assetsUnderManagement(strategyList[i_]);
        }
    }

    /**************************************************************************************************************************************/
    /*** LP Token View Functions                                                                                                        ***/
    /**************************************************************************************************************************************/

    function convertToExitShares(uint256 assets_) public view override returns (uint256 shares_) {
        shares_ = IPoolLike(pool).convertToExitShares(assets_);
    }

    function getEscrowParams(address, uint256 shares_) external view override returns (uint256 escrowShares_, address destination_) {
        // NOTE: `owner_` param not named to avoid compiler warning.
        ( escrowShares_, destination_) = (shares_, address(this));
    }

    function maxDeposit(address receiver_) external view virtual override returns (uint256 maxAssets_) {
        maxAssets_ = _getMaxAssets(receiver_, totalAssets(), "P:deposit");
    }

    function maxMint(address receiver_) external view virtual override returns (uint256 maxShares_) {
        uint256 totalAssets_ = totalAssets();
        uint256 maxAssets_   = _getMaxAssets(receiver_, totalAssets_, "P:mint");

        maxShares_ = IPoolLike(pool).previewDeposit(maxAssets_);
    }

    function maxRedeem(address owner_) external view virtual override returns (uint256 maxShares_) {
        uint256 lockedShares_ = IWithdrawalManagerLike(withdrawalManager).lockedShares(owner_);
        maxShares_            = IWithdrawalManagerLike(withdrawalManager).isInExitWindow(owner_) ? lockedShares_ : 0;
    }

    function maxWithdraw(address owner_) external view virtual override returns (uint256 maxAssets_) {
        owner_;          // Silence compiler warning
        maxAssets_ = 0;  // NOTE: always returns 0 as withdraw is not implemented
    }

    function previewRedeem(address owner_, uint256 shares_) external view virtual override returns (uint256 assets_) {
        ( , assets_ ) = IWithdrawalManagerLike(withdrawalManager).previewRedeem(owner_, shares_);
    }

    function previewWithdraw(address owner_, uint256 assets_) external view virtual override returns (uint256 shares_) {
        ( , shares_ ) = IWithdrawalManagerLike(withdrawalManager).previewWithdraw(owner_, assets_);
    }

    function unrealizedLosses() public view override returns (uint256 unrealizedLosses_) {
        uint256 length_ = strategyList.length;

        for (uint256 i_; i_ < length_; i_++) {
            unrealizedLosses_ += _unrealizedLosses(strategyList[i_]);
        }

        unrealizedLosses_ = _min(unrealizedLosses_, totalAssets());
    }

    /**************************************************************************************************************************************/
    /*** Internal Functions                                                                                                             ***/
    /**************************************************************************************************************************************/

    function _address(uint256 word_) internal pure returns (address address_) {
        address_ = address(uint160(word_));
    }

    function _assetsUnderManagement(address strategy_) internal view returns (uint256 exposure_) {
        exposure_ = isStrategyManager[strategy_]
            ? IStrategyManagerLike(strategy_).assetsOf(address(this))
            : IStrategyLike(strategy_).assetsUnderManagement();
    }

    function _canDeposit(uint256 assets_) internal view returns (bool canDeposit_, string memory errorMessage_) {
        if (!active)                                return (false, "P:NOT_ACTIVE");
        if (assets_ + totalAssets() > liquidityCap) return (false, "P:DEPOSIT_GT_LIQ_CAP");

        return (true, "");
    }

    function _decodeParameters(bytes calldata data_) internal pure returns (uint256[3] memory words) {
        if (data_.length > 64)  {
            ( words[0], words[1], words[2] ) = abi.decode(data_, (uint256, uint256, uint256));
        } else {
            ( words[0], words[1] ) = abi.decode(data_, (uint256, uint256));
        }
    }

    function _getMaxAssets(address receiver_, uint256 totalAssets_, bytes32 functionId_) internal view returns (uint256 maxAssets_) {
        bool    depositAllowed_ = IPoolPermissionManagerLike(poolPermissionManager).hasPermission(address(this),  receiver_, functionId_);
        uint256 liquidityCap_   = liquidityCap;
        maxAssets_              = liquidityCap_ > totalAssets_ && depositAllowed_ ? liquidityCap_ - totalAssets_ : 0;
    }

    function _isValidStrategy(address strategy_) internal view returns (bool) {
        if (strategy_ == address(0)) return false;

        address factory_ = IMapleProxied(strategy_).factory();

        if (!IGlobalsLike(globals()).isInstanceOf("STRATEGY_FACTORY", factory_)) return false;
        if (!IMapleProxyFactory(factory_).isInstance(strategy_))                 return false;

        return true;
    }

    function _isValidStrategyManager(address strategyManager_) internal view returns (bool) {
        if (strategyManager_ == address(0)) return false;

        address factory_ = IMapleProxied(strategyManager_).factory();

        if (!IGlobalsLike(globals()).isInstanceOf("STRATEGY_MANAGER_FACTORY", factory_)) return false;
        if (!IMapleProxyFactory(factory_).isInstance(strategyManager_))                  return false;

        return true;
    }

    function _isValidStrategyOrManager(address caller_) internal view returns (bool) {
        if (isStrategyManager[caller_]) return _isValidStrategyManager(caller_);
        if (isStrategy[caller_])        return _isValidStrategy(caller_);

        return false;
    }

    function _unrealizedLosses(address strategy_) internal view returns (uint256 unrealizedLosses_) {
        unrealizedLosses_ = isStrategyManager[strategy_]
            ? IStrategyManagerLike(strategy_).unrealizedLossesOf(address(this))
            : IStrategyLike(strategy_).unrealizedLosses();
    }

    function _revertIfConfigured() internal view {
        require(!configured, "PM:ALREADY_CONFIGURED");
    }

    function _revertIfConfiguredAndNotGovernor() internal view {
        require(!configured || msg.sender == governor(), "PM:NOT_GOV_OR_NOT_CONFIGURED");
    }

    function _revertIfConfiguredAndNotProtocolAdmins() internal view {
        require(
            !configured ||
            msg.sender == poolDelegate ||
            msg.sender == governor()   ||
            msg.sender == IGlobalsLike(globals()).operationalAdmin(),
            "PM:NOT_PA_OR_NOT_CONFIGURED"
        );
    }

    function _revertIfNotPool() internal view {
        require(msg.sender == pool, "PM:NOT_POOL");
    }

    function _revertIfNeitherPoolDelegateNorProtocolAdmins() internal view {
        require(
            msg.sender == poolDelegate ||
            msg.sender == governor()   ||
            msg.sender == IGlobalsLike(globals()).operationalAdmin(),
            "PM:NOT_PD_OR_GOV_OR_OA"
        );
    }

    function _revertIfPaused() internal view {
        require(!IGlobalsLike(globals()).isFunctionPaused(msg.sig), "PM:PAUSED");
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256 min_) {
        min_ = a_ < b_ ? a_ : b_;
    }

}
