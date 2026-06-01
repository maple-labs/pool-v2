// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import { StdUtils }              from "../../modules/forge-std/src/StdUtils.sol";
import { VmSafe }                from "../../modules/forge-std/src/Vm.sol";
import { MapleProxiedInternals } from "../../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";
import { MockERC20 }             from "../../modules/erc20/contracts/test/mocks/MockERC20.sol";

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

    function assetsUnderManagement() external pure returns (uint256 aum) {}
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

contract MockStrategy {

    uint256 public assetsUnderManagement;

    address public factory;

    mapping(address => uint256) public assetsOf;

    constructor(address pool_, address treasury_, address poolDelegate_) {}

    function fund(address) external {}

    function __setAssetsOf(address poolManager_, uint256 assets_) external {
        assetsOf[poolManager_] = assets_;
    }

    function __setAssetsUnderManagement(uint256 assetsUnderManagement_) external {
        assetsUnderManagement = assetsUnderManagement_;
    }

    function __setFactory(address factory_) external {
        factory = factory_;
    }

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

    bool _reverts;

    fallback() external {
        // Do nothing.
    }

    function __setReverts(bool reverts_) external {
        _reverts = reverts_;
    }

    function assetsUnderManagement() external view returns (uint256) {
        if (_reverts) {
            revert();
        }

        return 0;
    }

}

contract MockFactory is StdUtils {

    bool _reverts;

    mapping(address => bool) public isInstance;

    function createInstance(bytes calldata, bytes32) external returns (address instance) {
        instance = address(new MockImplementation());

        MockImplementation(instance).__setReverts(_reverts);
    }

    function getNextStrategyAddress() external view returns (address) {
        VmSafe vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));
        return computeCreateAddress(address(this), vm.getNonce(address(this)));
    }

    function __setIsInstance(address instance, bool status) external {
        isInstance[instance] = status;
    }

    function __setReverts(bool reverts) external {
        _reverts = reverts;
    }

}

