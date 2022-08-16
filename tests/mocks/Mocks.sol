// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../../modules/contract-test-utils/contracts/test.sol";
import { MapleProxiedInternals }       from "../../modules/maple-proxy-factory/contracts/MapleProxiedInternals.sol";
import { MockERC20 }                   from "../../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { ILoanLike, IPoolLike } from "../../contracts/interfaces/Interfaces.sol";

import { Pool }        from "../../contracts/Pool.sol";
import { PoolManager } from "../../contracts/PoolManager.sol";

import { PoolManagerStorage } from "../../contracts/proxy/PoolManagerStorage.sol";

interface ILiquidatorLike {

    function getExpectedAmount(uint256 swapAmount_) external view returns (uint256 expectedAmount_);

    function liquidatePortion(uint256 swapAmount_, uint256 maxReturnAmount_, bytes calldata data_) external;

}

contract ConstructablePoolManager is PoolManager {

    constructor(address globals_, address poolDelegate_, address asset_) {
        require((globals = globals_)           != address(0), "PMI:I:ZERO_GLOBALS");
        require((poolDelegate = poolDelegate_) != address(0), "PMI:I:ZERO_PD");
        require((asset = asset_)               != address(0), "PMI:I:ZERO_ASSET");

        pool = address(new Pool(address(this), asset_, "PoolName", "PoolSymbol"));
    }

}

contract MockProxied is MapleProxiedInternals {

    function factory() external view returns (address factory_) {
        return _factory();
    }

    function implementation() external view returns (address implementation_) {
        return _implementation();
    }

    function migrate(address migrator_, bytes calldata arguments_) external {}
}

contract MockERC20Pool is Pool {

    constructor(address manager_, address asset_, string memory name_, string memory symbol_)
        Pool(manager_, asset_, name_, symbol_) {
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

    uint256 constant HUNDRED_PERCENT = 1e18;

    address public governor;
    address public mapleTreasury;

    bool public protocolPaused;

    mapping(address => bool) public isBorrower;
    mapping(address => bool) public isPoolAsset;
    mapping(address => bool) public isPoolDelegate;
    mapping(address => bool) public isPoolDeployer;

    mapping(address => uint256) public getLatestPrice;
    mapping(address => uint256) public platformManagementFeeRate;
    mapping(address => uint256) public maxCoverLiquidationPercent;
    mapping(address => uint256) public minCoverAmount;

    mapping(address => address) public ownedPoolManager;

    constructor(address governor_) {
        governor = governor_;
    }

    function setGovernor(address governor_) external {
        governor = governor_;
    }

    function setPlatformManagementFeeRate(address poolManager_, uint256 platformManagementFeeRate_) external {
        platformManagementFeeRate[poolManager_] = platformManagementFeeRate_;
    }

    function setLatestPrice(address asset_, uint256 latestPrice_) external {
        getLatestPrice[asset_] = latestPrice_;
    }

    function setMaxCoverLiquidationPercent(address poolManager_, uint256 maxCoverLiquidationPercent_) external {
        require(maxCoverLiquidationPercent_ <= HUNDRED_PERCENT, "MG:SMCLP:GT_100");

        maxCoverLiquidationPercent[poolManager_] = maxCoverLiquidationPercent_;
    }

    function setMinCoverAmount(address poolManager_, uint256 minCoverAmount_) external {
        minCoverAmount[poolManager_] = minCoverAmount_;
    }

    function setOwnedPool(address owner_, address poolManager_) external {
        ownedPoolManager[owner_] = poolManager_;
    }

    function setProtocolPause(bool paused_) external {
        protocolPaused = paused_;
    }

    function setTreasury(address treasury_) external {
        mapleTreasury = treasury_;
    }

    function setValidBorrower(address borrower_, bool isValid_) external {
        isBorrower[borrower_] = isValid_;
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

}

contract MockLiquidationStrategy {

    address auctioneer;

    constructor(address auctioneer_) {
        auctioneer = auctioneer_;
    }

    function flashBorrowLiquidation(address lender_, uint256 swapAmount_, address collateralAsset_, address fundsAsset_, address source_) external {
        uint256 repaymentAmount = ILiquidatorLike(lender_).getExpectedAmount(swapAmount_);

        MockERC20(fundsAsset_).approve(lender_, repaymentAmount);

        ILiquidatorLike(lender_).liquidatePortion(
            swapAmount_,
            type(uint256).max,
            abi.encodeWithSelector(this.swap.selector, collateralAsset_, fundsAsset_, swapAmount_, repaymentAmount)
        );
    }

    function swap(address collateralAsset_, address fundsAsset_, uint256 swapAmount_, uint256 repaymentAmount_) external {
        MockERC20(fundsAsset_).mint(address(this), repaymentAmount_);
        MockERC20(collateralAsset_).burn(address(this), swapAmount_);
    }

}

contract MockLoan {

    address public borrower;
    address public collateralAsset;
    address public fundsAsset;

    uint256 public collateral;
    uint256 public collateralRequired;
    uint256 public nextPaymentInterest;
    uint256 public nextPaymentDueDate;
    uint256 public nextPaymentPrincipal;
    uint256 public paymentInterval;
    uint256 public principal;
    uint256 public principalRequested;

    uint256 public refinanceInterest;

    // Refinance Variables
    uint256 public refinanceNextPaymentInterest;
    uint256 public refinanceNextPaymentDueDate;
    uint256 public refinanceNextPaymentPrincipal;
    uint256 public refinancePaymentInterval;
    uint256 public refinancePrincipal;
    uint256 public refinancePrincipalRequested;

    constructor(address collateralAsset_, address fundsAsset_) {
        collateralAsset = collateralAsset_;
        fundsAsset      = fundsAsset_;
    }

    function acceptNewTerms(address refinancer_, uint256 deadline_, bytes[] calldata calls_) external returns (bytes32 refinanceCommitment_) {
        nextPaymentInterest  = refinanceNextPaymentInterest;
        nextPaymentDueDate   = refinanceNextPaymentDueDate;
        nextPaymentPrincipal = refinanceNextPaymentPrincipal;
        paymentInterval      = refinancePaymentInterval;
        principal            = refinancePrincipal;
        principalRequested   = refinancePrincipalRequested;

        refinanceNextPaymentInterest  = 0;
        refinanceNextPaymentDueDate   = 0;
        refinanceNextPaymentPrincipal = 0;
        refinancePaymentInterval      = 0;
        refinancePrincipal            = 0;
        refinancePrincipalRequested   = 0;
    }

    function drawdownFunds(uint256 amount_, address destination_) external {
        MockERC20(fundsAsset).transfer(destination_, amount_);
    }

    function fundLoan(address) external returns (uint256 fundsLent_) {
        // Do nothing
    }

    function getNextPaymentBreakdown() external view returns (uint256 principal_, uint256 interest_) {
        principal_ = nextPaymentPrincipal;
        interest_  = nextPaymentInterest + refinanceInterest;
    }

    function repossess(address destination_) external returns (uint256 collateralRepossessed_, uint256 fundsRepossessed_) {
        collateralRepossessed_ = collateral;
        MockERC20(collateralAsset).transfer(destination_, collateral);
    }

    function __setBorrower(address borrower_) external {
        borrower = borrower_;
    }

    function __setCollateral(uint256 collateral_) external {
        collateral = collateral_;
    }

    function __setCollateralRequired(uint256 collateralRequired_) external {
        collateralRequired = collateralRequired_;
    }

    function __setNextPaymentDueDate(uint256 nextPaymentDueDate_) external {
        nextPaymentDueDate = nextPaymentDueDate_;
    }

    function __setNextPaymentInterest(uint256 nextPaymentInterest_) external {
        nextPaymentInterest = nextPaymentInterest_;
    }

    function __setNextPaymentPrincipal(uint256 nextPaymentPrincipal_) external {
        nextPaymentPrincipal = nextPaymentPrincipal_;
    }

    function __setPaymentInterval(uint256 paymentInterval_) external {
        paymentInterval = paymentInterval_;
    }

    function __setPrincipal(uint256 principal_) external {
        principal = principal_;
    }

    function __setPrincipalRequested(uint256 principalRequested_) external {
        principalRequested = principalRequested_;
    }

    function __setRefinanceInterest(uint256 refinanceInterest_) external {
        refinanceInterest = refinanceInterest_;
    }

    function __setRefinancePrincipal(uint256 principal_) external {
        refinancePrincipal = principal_;
    }

    function __setRefinancePrincipalRequested(uint256 principalRequested_) external {
        refinancePrincipalRequested = principalRequested_;
    }

    function __setRefinanceNextPaymentInterest(uint256 nextPaymentInterest_) external {
        refinanceNextPaymentInterest = nextPaymentInterest_;
    }

    function __setRefinanceNextPaymentDueDate(uint256 nextPaymentDueDate_) external {
        refinanceNextPaymentDueDate = nextPaymentDueDate_;
    }

    function __setRefinanceNextPaymentPrincipal(uint256 nextPaymentPrincipal_) external {
        refinanceNextPaymentPrincipal = nextPaymentPrincipal_;
    }

    function __setRefinancePaymentInterval(uint256 paymentInterval_) external {
        refinancePaymentInterval = paymentInterval_;
    }

}

contract MockLoanManager {

    address pool;
    address poolDelegate;
    address treasury;

    uint256 delegateManagementFee;
    uint256 platformManagementFee;
    uint256 poolAmount;

    uint256 principalToCover;  // Note that this is the return value for increasedUnrealizedLosses_ in triggerCollateralLiquidation and also principalToCover_ in finishCollateralLiquidation. They will always be equal.
    uint256 remainingLosses;

    constructor(address pool_, address treasury_, address poolDelegate_) {
        pool         = pool_;
        treasury     = treasury_;
        poolDelegate = poolDelegate_;
    }

    function fund(address) external { }

    function claim(address loan_, bool hasSufficientCover_) external {
        address[] memory destinations_ = new address[](3);
        uint256[] memory amounts_      = new uint256[](3);

        destinations_[0] = treasury;
        destinations_[1] = poolDelegate;
        destinations_[2] = pool;

        amounts_[0] = platformManagementFee;
        amounts_[1] = hasSufficientCover_ ? delegateManagementFee : 0;
        amounts_[2] = hasSufficientCover_ ? poolAmount  : (poolAmount + delegateManagementFee);

        ILoanLike(loan_).batchClaimFunds(amounts_, destinations_);
    }

    function triggerCollateralLiquidation(address) external returns (uint256 increasedUnrealizedLosses_) {
        increasedUnrealizedLosses_ = principalToCover;
    }

    function finishCollateralLiquidation(address loan_) external returns (uint256 principalToCover_, uint256 remainingLosses_) {
        principalToCover_ = principalToCover;
        remainingLosses_  = remainingLosses;
    }

    function __setPlatformManagementFee(uint256 platformManagementFee_) external {
        platformManagementFee = platformManagementFee_;
    }

    function __setDelegateManagementFee(uint256 delegateManagementFee_) external {
        delegateManagementFee = delegateManagementFee_;
    }

    function __setPoolAmount(uint256 poolAmount_) external {
        poolAmount = poolAmount_;
    }

    function __setFinishCollateralLiquidationReturn(uint256 remainingLosses_) external {
        // principal to cover is set by __setTriggerCollateralLiquidationReturn
        remainingLosses = remainingLosses_;
    }

    function __setTriggerCollateralLiquidationReturn(uint256 increasedUnrealizedLosses_) external {
        principalToCover = increasedUnrealizedLosses_;
    }

}

contract MockLoanManagerMigrator {

    address fundsAsset;

    fallback() external {
        fundsAsset = abi.decode(msg.data, (address));
    }

}

contract MockPool {

    address public asset;
    address public manager;

    function __setAsset(address asset_) external {
        asset = asset_;
    }

    function __setManager(address manager_) external {
        manager = manager_;
    }

    function redeem(uint256, address, address) external pure returns (uint256) { }

}

/**
 *  @dev Needs to inherit PoolManagerStorage to match real PoolManager storage layout, since this contract is used to etch over the real PoolManager implementation in tests,
 *       and is therefore used as the implementation contract for the PoolManager proxy. By matching the storage layout, we avoid unexpected modifications of storage variables in this contract.
 */
contract MockPoolManager is PoolManagerStorage, MockProxied {

    bool internal _canCall;
    bool internal _hasSufficientCover;

    uint256 internal _previewRedeemAmount;
    uint256 internal _previewWithdrawAmount;
    uint256 internal _redeemableAssets;
    uint256 internal _redeemableShares;

    uint256 public totalAssets;

    string public errorMessage;

    mapping(address => uint256) public maxDeposit;
    mapping(address => uint256) public maxMint;
    mapping(address => uint256) public maxRedeem;
    mapping(address => uint256) public maxWithdraw;

    function canCall(bytes32 functionId_, address caller_, bytes memory data_) external view returns (bool canCall_, string memory errorMessage_) {
        canCall_      = _canCall;
        errorMessage_ = errorMessage;
    }

    function configure(address loanManager_, address withdrawalManager_, uint256 liquidityCap_, uint256 managementFee_) external {
        // Do nothing.
    }

    function hasSufficientCover() external pure returns (bool hasSufficientCover_) {
        hasSufficientCover_ = true;
    }

    function previewRedeem(address account_, uint256 shares_) external view returns (uint256 assets_) {
        assets_ = _previewRedeemAmount;
    }

    function previewWithdraw(address account_, uint256 shares_) external view returns (uint256 assets_) {
        assets_ = _previewWithdrawAmount;
    }

    function processRedeem(uint256 shares_, address owner_) external view returns (uint256 redeemableShares_, uint256 assets_) {
        redeemableShares_ = shares_;
        assets_           = _redeemableAssets;
    }

    function processWithdraw(uint256 shares_, address owner_) external view returns (uint256 redeemableShares_, uint256 assets_) {
        redeemableShares_ = _redeemableShares;
        assets_           = _redeemableAssets;
    }

    function setDelegateManagementFeeRate(uint256 delegateManagementFeeRate_) external {
        delegateManagementFeeRate = delegateManagementFeeRate_;
    }

    function setWithdrawalManager(address withdrawalManager_) external {
        withdrawalManager = withdrawalManager_;
    }

    function __setGlobals(address globals_) external {
        globals = globals_;
    }

    function __setHasSufficientCover(bool hasSufficientCover_) external {
        _hasSufficientCover = hasSufficientCover_;
    }

    function __setCanCall(bool canCall_, string memory errorMessage_) external {
        _canCall     = canCall_;
        errorMessage = errorMessage_;
    }

    function __setMaxDeposit(address account_, uint256 maxDeposit_) external {
        maxDeposit[account_] = maxDeposit_;
    }

    function __setMaxMint(address account_, uint256 maxMint_) external {
        maxMint[account_] = maxMint_;
    }

    function __setMaxRedeem(address account_, uint256 maxRedeem_) external {
        maxRedeem[account_] = maxRedeem_;
    }

    function __setMaxWithdraw(address account_, uint256 maxWithdraw_) external {
        maxWithdraw[account_] = maxWithdraw_;
    }

    function __setPoolDelegate(address poolDelegate_) external {
        poolDelegate = poolDelegate_;
    }

    function __setPreviewRedeem(uint256 amount_) external {
        _previewRedeemAmount = amount_;
    }

    function __setPreviewWithdraw(uint256 amount_) external {
        _previewWithdrawAmount = amount_;
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

    constructor() MockERC20("Asset", "AST", 18) { }

    function transfer(address recipient_, uint256 amount_) public virtual override returns (bool success_) {
        if (pool != address(0)) {
            IPoolLike(pool).deposit(0, address(0));
        } else {
            success_ = super.transfer(recipient_, amount_);
        }
    }

    function transferFrom(address owner_, address recipient_, uint256 amount_) public virtual override returns (bool success_) {
        if (pool != address(0)) {
            IPoolLike(pool).deposit(0, address(0));
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

    function approve(address spender_, uint256 amount_) external returns (bool success_) {
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

contract MockPoolManagerMigrator {

    address poolDelegate;

    fallback() external {
        poolDelegate = abi.decode(msg.data, (address));
    }

}

abstract contract MockMigrator {

    fallback() external {
        // Do nothing.
    }

}

contract MockPoolManagerInitializer is MockMigrator {

    function encodeArguments(address globals_, address owner_, address asset_, string memory name_, string memory symbol_) external pure
        returns (bytes memory encodedArguments_) {

        encodedArguments_ = new bytes(0);
    }

    function decodeArguments(bytes calldata encodedArguments_) external pure
        returns (address globals_, address owner_, address asset_, string memory name_, string memory symbol_) {
        // Do nothing.
    }
}

contract MockLoanManagerInitializer is MockMigrator {
    function encodeArguments(address pool_) external pure returns (bytes memory calldata_) {
        calldata_ = new bytes(0);
    }

    function decodeArguments(bytes calldata calldata_) public pure returns (address pool_) {
        // Do nothing.
    }
}

contract MockWithdrawalManager {

    function addShares(uint256 shares_, address owner_) external { }

    function processExit(address owner, uint256 shares_) external returns (uint256 redeemableShares_, uint256 resultingAssets_) { }

    function removeShares(uint256 shares_, address owner_) external { }
}

contract MockWithdrawalManagerInitializer is MockMigrator {

    function encodeArguments(
        address pool_,
        uint256 cycleDuration_,
        uint256 windowDuration_
    ) external pure returns (bytes memory encodedArguments_) {
        encodedArguments_ = new bytes(0);
    }

    function decodeArguments(bytes calldata encodedArguments_)
        external pure returns (
            address pool_,
            uint256 cycleDuration_,
            uint256 windowDuration_
        )
    {
        // Do nothing.
    }
}
