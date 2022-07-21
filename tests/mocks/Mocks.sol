// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../../modules/contract-test-utils/contracts/test.sol";

import { MockERC20 } from "../../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { IAuctioneerLike, ILiquidatorLike, IPoolLike } from "../../contracts/interfaces/Interfaces.sol";

import { Pool }        from "../../contracts/Pool.sol";
import { PoolManager } from "../../contracts/PoolManager.sol";

import { PoolManagerStorage } from "../../contracts/proxy/PoolManagerStorage.sol";

contract ConstructablePoolManager is PoolManager {

    constructor(address globals_, address admin_, address asset_) {
        require((globals = globals_) != address(0), "PMI:I:ZERO_GLOBALS");
        require((admin = admin_)     != address(0), "PMI:I:ZERO_ADMIN");
        require((asset = asset_)     != address(0), "PMI:I:ZERO_ASSET");

        pool = address(new Pool(address(this), asset_, "PoolName", "PoolSymbol"));
    }

}

contract MockAuctioneer {

    uint256 internal immutable MULTIPLIER;
    uint256 internal immutable DIVISOR;

    constructor(uint256 multiplier_, uint256 divisor_) {
        MULTIPLIER = multiplier_;
        DIVISOR    = divisor_;
    }

    function getExpectedAmount(uint256 swapAmount_) external view returns (uint256 expectedAmount_) {
        expectedAmount_ = swapAmount_ * MULTIPLIER / DIVISOR;
    }

}

contract MockERC20Pool is Pool {

    constructor(address manager_, address asset_, string memory name_, string memory symbol_)
        Pool(manager_, asset_, name_, symbol_) { }

    function mint(address recipient_, uint256 amount_) external {
        _mint(recipient_, amount_);
    }

    function burn(address owner_, uint256 amount_) external {
        _burn(owner_, amount_);
    }

}

contract MockGlobals {

    address public governor;
    address public mapleTreasury;

    bool public protocolPaused;

    mapping (address => uint256) public managementFeeSplit;

    mapping(address => address) public ownedPool;

    mapping(address => bool) public isPoolDelegate;

    constructor (address governor_) {
        governor = governor_;
    }

    function setGovernor(address governor_) external {
        governor = governor_;
    }

    function setManagementFeeSplit(address pool_, uint256 split_) external {
        managementFeeSplit[pool_] = split_;
    }

    function setOwnedPool(address owner_, address pool_) external {
        ownedPool[owner_] = pool_;
    }

    function setProtocolPause(bool paused_) external {
        protocolPaused = paused_;
    }

    function setTreasury(address treasury_) external {
        mapleTreasury = treasury_;
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

    function flashBorrowLiquidation(address lender_, uint256 swapAmount_, address collateralAsset_, address fundsAsset_) external {
        uint256 repaymentAmount = IAuctioneerLike(auctioneer).getExpectedAmount(swapAmount_);

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

    address public collateralAsset;
    address public fundsAsset;

    uint256 public collateral;
    uint256 public collateralRequired;
    uint256 public claimableFunds;
    uint256 public nextPaymentInterest;
    uint256 public nextPaymentDueDate;
    uint256 public nextPaymentPrincipal;
    uint256 public paymentInterval;
    uint256 public principal;
    uint256 public principalRequested;

    constructor(address collateralAsset_, address fundsAsset_) {
        collateralAsset = collateralAsset_;
        fundsAsset      = fundsAsset_;
    }

    function claimFunds(uint256 amount_, address destination_) external {
        claimableFunds -= amount_;
        MockERC20(fundsAsset).transfer(destination_, amount_);
    }

    function drawdownFunds(uint256 amount_, address destination_) external {
        MockERC20(fundsAsset).transfer(destination_, amount_);
    }

    function fundLoan(address , uint256 ) external returns (uint256 fundsLent_){
        // Do nothing
    }

    function getNextPaymentBreakdown() external view returns (uint256 principal_, uint256 interest_) {
        principal_ = nextPaymentPrincipal;
        interest_  = nextPaymentInterest;
    }

    function repossess(address destination_) external returns (uint256 collateralRepossessed_, uint256 fundsRepossessed_) {
        collateralRepossessed_ = collateral;
        MockERC20(collateralAsset).transfer(destination_, collateral);
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

    function __setClaimableFunds(uint256 claimable_) external {
        claimableFunds = claimable_;
    }

}

contract MockLoanManager {

    uint256 public coverPortion;
    uint256 public managementPortion;

    function fund(address loan_) external { }

    function claim(address loan_) external returns (uint256 coverPortion_, uint256 managementPortion_) {
        coverPortion_      = coverPortion;
        managementPortion_ = managementPortion;
    }

    function __setCoverPortion(uint256 coverPortion_) external {
        coverPortion = coverPortion_;
    }

    function __setManagementPortion(uint256 managementPortion_) external {
        managementPortion = managementPortion_;
    }

}

contract MockPool {

    address public asset;

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function redeem(uint256, address, address) external pure returns (uint256) { }

}

contract MockPoolCoverManager {

    function allocateLiquidity() external { }

    function triggerCoverLiquidation(uint256 remainingLosses_) external { }

}

/**
 *  @dev Needs to inherit PoolManagerStorage to match real PoolManager storage layout, since this contract is used to etch over the real PoolManager implmentation in tests,
 *       and is therefore used as the implementation contract for the PoolManager proxy. By matching the storage layout, we avoid unexpected modifications of storage variables in this contract.
 */
contract MockPoolManager is PoolManagerStorage {

    bool internal _canCall;

    uint256 public totalAssets;

    string public errorMessage;

    function canCall(bytes32 functionId_, address caller_, bytes memory data_) external view returns (bool canCall_, string memory errorMessage_) {
        canCall_      = _canCall;
        errorMessage_ = errorMessage;
    }

    function getFees() external view returns (uint256 coverFee_, uint256 managementFee_) {
        coverFee_      = coverFee;
        managementFee_ = managementFee;
    }

    function setCoverFee(uint256 coverFee_) external {
        coverFee = coverFee_;
    }

    function setManagementFee(uint256 managementFee_) external {
        managementFee = managementFee_;
    }

    function __setCanCall(bool canCall_, string memory errorMessage_) external {
        _canCall     = canCall_;
        errorMessage = errorMessage_;
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

contract MockMigrator {

    address admin;

    fallback() external {
        admin = abi.decode(msg.data, (address));
    }

}
