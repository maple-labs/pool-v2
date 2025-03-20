// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { MapleProxiedInternals } from "../../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";
import { MockERC20 }             from "../../modules/erc20/contracts/test/mocks/MockERC20.sol";
import { ERC20Helper }           from "../../modules/erc20-helper/src/ERC20Helper.sol";

import { MaplePool }        from "../../contracts/MaplePool.sol";         // TODO: This should not be used in mocks.
import { MaplePoolManager } from "../../contracts/MaplePoolManager.sol";  // TODO: This should not be used in mocks.

import { MaplePoolManagerStorage } from "../../contracts/proxy/MaplePoolManagerStorage.sol";  // TODO: This should not be used in mocks.

contract MockProxied is MapleProxiedInternals {

    function factory() external view returns (address factory_) {
        return _factory();
    }

    function implementation() external view returns (address implementation_) {
        return _implementation();
    }

    function migrate(address migrator_, bytes calldata arguments_) external {}
}

contract MockERC20Pool is MaplePool {

    constructor(address manager_, address asset_, string memory name_, string memory symbol_)
        MaplePool(manager_, asset_, address(0), 0, 0, name_, symbol_) {
            MockERC20(asset_).approve(manager_, type(uint256).max);
    }

    function mint(address recipient_, uint256 amount_) external {
        _mint(recipient_, amount_);
    }

    function burn(address owner_, uint256 amount_) external {
        _burn(owner_, amount_);
    }

}

contract MockGlobals {

    uint256 public constant HUNDRED_PERCENT = 1e6;

    bool internal _factorySet;
    bool internal _failTransferOwnedPoolManager;
    bool internal _instanceSet;
    bool internal _isFunctionPaused;
    bool internal _isValidScheduledCall;

    mapping(bytes32 => mapping(address => bool)) public _validFactory;
    mapping(bytes32 => mapping(address => bool)) public _validInstance;

    address public governor;
    address public mapleTreasury;
    address public migrationAdmin;
    address public operationalAdmin;
    address public securityAdmin;

    bool public protocolPaused;

    mapping(address => bool) public isBorrower;
    mapping(address => bool) public isPoolAsset;
    mapping(address => bool) public isPoolDelegate;
    mapping(address => bool) public isPoolDeployer;

    mapping(address => uint256) public maxCoverLiquidationPercent;
    mapping(address => uint256) public minCoverAmount;

    mapping(address => address) public ownedPoolManager;

    uint256 internal _bootstrapMint;

    constructor(address governor_) {
        governor = governor_;
    }

    function isFunctionPaused(bytes4) external view returns (bool isFunctionPaused_) {
        isFunctionPaused_ = _isFunctionPaused;
    }

    function isValidScheduledCall(address, address, bytes32, bytes calldata) external view returns (bool isValid_) {
        isValid_ = _isValidScheduledCall;
    }

    function bootstrapMint(address asset_) external view returns (uint256 bootstrapMint_) {
        asset_;
        bootstrapMint_ = _bootstrapMint;
    }

    function isInstanceOf(bytes32 instanceId_, address instance_) external view returns (bool isInstance_) {
        isInstance_ = true;
        if (_instanceSet) {
            isInstance_ = _validInstance[instanceId_][instance_];
        }
    }

    function setMigrationAdmin(address migrationAdmin_) external {
        migrationAdmin = migrationAdmin_;
    }

    function setMaxCoverLiquidationPercent(address poolManager_, uint256 maxCoverLiquidationPercent_) external {
        require(maxCoverLiquidationPercent_ <= HUNDRED_PERCENT, "MG:SMCLP:GT_100");

        maxCoverLiquidationPercent[poolManager_] = maxCoverLiquidationPercent_;
    }

    function setMinCoverAmount(address poolManager_, uint256 minCoverAmount_) external {
        minCoverAmount[poolManager_] = minCoverAmount_;
    }

    function setProtocolPause(bool paused_) external {
        protocolPaused = paused_;
    }

    function setMapleTreasury(address treasury_) external {
        mapleTreasury = treasury_;
    }

    function setValidBorrower(address borrower_, bool isValid_) external {
        isBorrower[borrower_] = isValid_;
    }

    function setValidFactory(bytes32 factoryId_, address factory_, bool isValid_) external {
        _factorySet = true;
        _validFactory[factoryId_][factory_] = isValid_;
    }

    function setValidInstance(bytes32 instanceId_, address instance_, bool isInstance_) external {
        _instanceSet = true;
        _validInstance[instanceId_][instance_] = isInstance_;
    }

    function setValidPoolDeployer(address poolDeployer_, bool isValid_) external {
        isPoolDeployer[poolDeployer_] = isValid_;
    }

    function setValidPoolAsset(address poolAsset_, bool isValid_) external {
        isPoolAsset[poolAsset_] = isValid_;
    }

    function setValidPoolDelegate(address poolDelegate_, bool isValid_) external {
        isPoolDelegate[poolDelegate_] = isValid_;
    }

    function transferOwnedPoolManager(address, address) external {
        require(!(_failTransferOwnedPoolManager = _failTransferOwnedPoolManager), "MG:TOPM:FAILED");
    }

    function unscheduleCall(address, bytes32, bytes calldata) external {}

    function __setBootstrapMint(uint256 bootstrapMint_) external {
        _bootstrapMint = bootstrapMint_;
    }

    function __setFailTransferOwnedPoolManager(bool fail_) external {
        _failTransferOwnedPoolManager = fail_;
    }

    function __setFunctionPaused(bool paused_) external {
        _isFunctionPaused = paused_;
    }

    function __setIsValidScheduledCall(bool isValid_) external {
        _isValidScheduledCall = isValid_;
    }
    
    function __setOperationalAdmin(address admin_) external {
        operationalAdmin = admin_;
    }

    function __setOwnedPoolManager(address owner_, address poolManager_) external {
        ownedPoolManager[owner_] = poolManager_;
    }

    function __setSecurityAdmin(address securityAdmin_) external {
        securityAdmin = securityAdmin_;
    }

}

contract MockLoan {

    address public borrower;

    address public factory;
    address public lender;

    uint256 public nextPaymentDueDate;
    uint256 public paymentsRemaining;

    mapping(address => uint256) public unaccountedAmounts;

    constructor(address collateralAsset_, address fundsAsset_) {}

    function getUnaccountedAmount(address asset_) external view returns (uint256 unaccountedAmount_) {
        return unaccountedAmounts[asset_];
    }

    function skim(address asset_, address destination_) external returns (uint256 skimmed_) {
        skimmed_ = unaccountedAmounts[asset_];
        ERC20Helper.transfer(asset_, destination_, skimmed_);
    }

    function __setBorrower(address borrower_) external {
        borrower = borrower_;
    }

    function __setFactory(address factory_) external {
        factory = factory_;
    }

    function __setLender(address lender_) external {
        lender = lender_;
    }

    function __setPaymentsRemaining(uint256 paymentsRemaining_) external {
        paymentsRemaining = paymentsRemaining_;
    }

    function __setUnaccountedAmount(address asset_, uint256 unaccountedAmount_) external {
        unaccountedAmounts[asset_] = unaccountedAmount_;
    }

}

contract MockLoanManager {

    uint128 public unrealizedLosses;  // uint128 - 16 bytes: max = 3.4e38

    address public factory;

    bool public wasRemoveLoanImpairmentCalledByGovernor;
    bool public wasImpairLoanCalledByGovernor;

    uint256 public delegateManagementFee;
    uint256 public platformManagementFee;
    uint256 public poolAmount;

    uint256 public remainingLosses;
    uint128 public increasedUnrealizedLosses;
    uint256 public serviceFee;  // Management + Platform

    constructor(address pool_, address treasury_, address poolDelegate_) {}

    function acceptNewTerms(address loan_, address refinancer_, uint256 deadline_, bytes[] calldata calls_) external {}

    // NOTE: Used to satisfy min condition in unrealizedLosses
    function assetsUnderManagement() external view returns (uint256 assetsUnderManagement_) {
        assetsUnderManagement_ = unrealizedLosses;
    }

    function fund(address) external {}

    function removeLoanImpairment(address, bool isCalledByGovernor_) external {
        wasRemoveLoanImpairmentCalledByGovernor = isCalledByGovernor_;
    }

    function triggerDefault(address, address)
        external
        returns (bool liquidationComplete_, uint256 remainingLosses_, uint256 platformFees_)
    {
        liquidationComplete_ = true;
        remainingLosses_     = 0;
        platformFees_        = 0;

        unrealizedLosses += increasedUnrealizedLosses;
    }

    function impairLoan(address , bool isGovernor_) external {
        wasImpairLoanCalledByGovernor = isGovernor_;
    }

    function finishCollateralLiquidation(address loan_) external returns (uint256 remainingLosses_, uint256 platformFees_) {
        loan_;

        unrealizedLosses -= increasedUnrealizedLosses;
        remainingLosses_  = remainingLosses;
        platformFees_     = serviceFee;
    }

    function __setFactory(address factory_) external {
        factory = factory_;
    }

    function __setFinishCollateralLiquidationReturn(uint256 remainingLosses_, uint256 serviceFee_) external {
        remainingLosses = remainingLosses_;
        serviceFee      = serviceFee_;
    }

    function __setTriggerDefaultReturn(uint256 increasedUnrealizedLosses_) external {
        increasedUnrealizedLosses = _uint128(increasedUnrealizedLosses_);
    }

    function __setUnrealizedLosses(uint256 unrealizedLosses_) external {
        unrealizedLosses = _uint128(unrealizedLosses_);
    }

    function _uint128(uint256 value_) internal pure returns (uint128 castedValue_) {
        require(value_ <= type(uint128).max, "LM:UINT128_CAST");
        castedValue_ = uint128(value_);
    }

}

contract MockOpenTermLoanManager is MockLoanManager {

    constructor(address pool_, address treasury_, address poolDelegate_) MockLoanManager(pool_, treasury_, poolDelegate_) {}

    function proposeNewTerms(address loan_, address refinancer_, uint256 deadline_, bytes[] calldata calls_) external {}

}

// TODO: There most definitely is a better way to mock MaplePoolManager.
/**
 *  @dev Needs to inherit MaplePoolManagerStorage to match real MaplePoolManager storage layout,
 *       since this contract is used to etch over the real MaplePoolManager implementation in tests,
 *       and is therefore used as the implementation contract for the MaplePoolManager proxy.
 *       By matching the storage layout, we avoid unexpected modifications of storage variables in this contract.
 */
contract MockPoolManager is MockProxied, MaplePoolManagerStorage {

    bool internal _canCall;

    uint256 internal _previewRedeemAmount;
    uint256 internal _previewWithdrawAmount;
    uint256 internal _redeemableAssets;
    uint256 internal _redeemableShares;

    uint256 public totalAssets;
    uint256 public unrealizedLosses;

    string public errorMessage;

    mapping(address => uint256) public maxDeposit;
    mapping(address => uint256) public maxMint;
    mapping(address => uint256) public maxRedeem;
    mapping(address => uint256) public maxWithdraw;

    function addStrategy(address strategyFactory_, bytes calldata deploymentData_) external view returns (address strategy_) {}

    function canCall(bytes32, address, bytes memory) external view returns (bool canCall_, string memory errorMessage_) {
        canCall_      = _canCall;
        errorMessage_ = errorMessage;
    }

    function completeConfiguration() external view {}

    function getEscrowParams(address, uint256 shares_) external view returns (uint256 escrowShares_, address destination_) {
        ( escrowShares_, destination_) = (shares_, address(this));
    }

    function previewRedeem(address, uint256) external view returns (uint256 assets_) {
        assets_ = _previewRedeemAmount;
    }

    function previewWithdraw(address, uint256) external view returns (uint256 assets_) {
        assets_ = _previewWithdrawAmount;
    }

    function processRedeem(uint256, address, address) external view returns (uint256 redeemableShares_, uint256 assets_) {
        redeemableShares_ = _redeemableShares;
        assets_           = _redeemableAssets;
    }

    function processWithdraw(uint256, address, address) external pure returns (uint256 redeemableShares_, uint256 assets_) {
        redeemableShares_; assets_;  // Silence compiler warnings.
        require(false, "PM:PW:NOT_ENABLED");
    }

    function requestRedeem(uint256 shares_, address owner_, address sender_) external view {
        if (sender_ != owner_ && shares_ == 0) {
            require(MaplePool(pool).allowance(owner_, sender_) > 0, "PM:RR:NO_ALLOWANCE");
        }
    }

    function requestWithdraw(uint256, uint256, address, address) external pure {
        require(false, "PM:RW:NOT_ENABLED");
    }

    function removeShares(uint256 shares_, address owner_) external returns (uint256 sharesReturned_) {}

    function setDelegateManagementFeeRate(uint256 delegateManagementFeeRate_) external {}

    function setLiquidityCap(uint256 liquidityCap_) external {}

    function setWithdrawalManager(address withdrawalManager_) external {
        withdrawalManager = withdrawalManager_;
    }

    function __setCanCall(bool canCall_, string memory errorMessage_) external {
        _canCall     = canCall_;
        errorMessage = errorMessage_;
    }

    function __setPool(address pool_) external {
        pool = pool_;
    }

    function __setRedeemableShares(uint256 redeemableShares_) external {
        _redeemableShares = redeemableShares_;
    }

    function __setRedeemableAssets(uint256 redeemableAssets_) external {
        _redeemableAssets = redeemableAssets_;
    }

    function __setTotalAssets(uint256 totalAssets_) external {
        totalAssets = totalAssets_;
    }

    function __setUnrealizedLosses(uint256 unrealizedLosses_) external {
        unrealizedLosses = unrealizedLosses_;
    }

}

contract MockReenteringERC20 is MockERC20 {

    address pool;

    constructor() MockERC20("Asset", "AST", 18) {}

    function transfer(address recipient_, uint256 amount_) public virtual override returns (bool success_) {
        if (pool != address(0)) {
            MaplePool(pool).deposit(0, address(0));
        } else {
            success_ = super.transfer(recipient_, amount_);
        }
    }

    function transferFrom(address owner_, address recipient_, uint256 amount_) public virtual override returns (bool success_) {
        if (pool != address(0)) {
            MaplePool(pool).deposit(0, address(0));
        } else {
            success_ = super.transferFrom(owner_, recipient_, amount_);
        }
    }

    function setReentrancy(address pool_) external {
        pool = pool_;
    }

}

contract MockRevertingERC20 {

    uint8 internal _decimals;

    bool public isRevertingApprove;
    bool public isRevertingDecimals;
    string public name;
    string public symbol;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name      = name_;
        symbol    = symbol_;
        _decimals = decimals_;
    }

    function approve(address, uint256) external view returns (bool success_) {
        require(!isRevertingApprove, "ERC20:A:REVERT");
        success_ = true;
    }

    function decimals() external view returns (uint8 decimals_) {
        require(!isRevertingDecimals, "ERC20:D:REVERT");
        decimals_ = _decimals;
    }

    function __setIsRevertingApprove(bool isReverting_) external {
        isRevertingApprove = isReverting_;
    }

    function __setIsRevertingDecimals(bool isReverting_) external {
        isRevertingDecimals = isReverting_;
    }

}

contract MockPoolManagerMigrator is MaplePoolManagerStorage {

    fallback() external {
        poolDelegate = abi.decode(msg.data, (address));
    }

}

contract MockPoolManagerMigratorInvalidPoolDelegateCover is MaplePoolManagerStorage {

    fallback() external {
        poolDelegateCover = address(0);
    }

}

contract MockPoolPermissionManager {

    bool _allowed;

    function hasPermission(address, address, bytes32) external view returns (bool allowed_) {
        allowed_ = _allowed;
    }

    function hasPermission(address, address[] calldata, bytes32) external view returns (bool allowed_) {
        allowed_ = _allowed;
    }
    
    function __setAllowed(bool allowed_) external {
        _allowed = allowed_;
    }

}

contract MockMigrator {

    fallback() external {
        // Do nothing.
    }

}

contract MockWithdrawalManager is MapleProxiedInternals {

    uint256 public lockedLiquidity;

    function addShares(uint256 shares_, address owner_) external {}

    function factory() external view returns (address factory_) {
        factory_ = _factory();
    }

    function processExit(uint256 shares_, address owner_) external returns (uint256 redeemableShares_, uint256 resultingAssets_) {}

    function removeShares(uint256 shares_, address owner_) external {}

    function __setFactory(address factory_) external {
        _setFactory(factory_);
    }

    function __setLockedLiquidity(uint256 lockedLiquidity_) external {
        lockedLiquidity = lockedLiquidity_;
    }
}

contract MockImplementation {

    fallback() external {
        // Do nothing.
    }

}

contract MockFactory {

    mapping(address => bool) public isInstance;

    function createInstance(bytes calldata, bytes32) external returns (address instance_) {
        instance_ = address(new MockImplementation());
    }

    function __setIsInstance(address instance, bool status) external {
        isInstance[instance] = status;
    }

}

contract MockLoanFactory {

    mapping(address => bool) public isLoan;

    function createInstance(bytes calldata, bytes32) external returns (address instance_) {
        instance_ = address(new MockImplementation());
    }

    function __setIsLoan(address instance, bool status) external {
        isLoan[instance] = status;
    }

}
