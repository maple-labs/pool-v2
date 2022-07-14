// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { MockERC20 } from "../../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { IAuctioneerLike, ILiquidatorLike, IPoolLike } from "../../contracts/interfaces/Interfaces.sol";

import { Pool }        from "../../contracts/Pool.sol";
import { PoolManager } from "../../contracts/PoolManager.sol";

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

    address public fundsAsset;
    address public collateralAsset;

    uint256 public collateral;
    uint256 public principal;
    uint256 public claimableFunds;

    constructor(address fundsAsset_, address collateralAsset_, uint256 principalRequested_, uint256 collateralRequired_) {
        fundsAsset      = fundsAsset_;
        collateralAsset = collateralAsset_;
        principal       = principalRequested_;
        collateral      = collateralRequired_;
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

    function getNextPaymentBreakdown() external returns (uint256 principal_, uint256 interest_) { }

    function nextPaymentDueDate() external view returns (uint256 nextPaymentDueDate_) {
        return block.timestamp + 30 days;
    }

    function paymentInterval() external view returns (uint256 paymentInterval_) {
        return 30 days;
    }

    function repossess(address destination_) external returns (uint256 collateralRepossessed_, uint256 fundsRepossessed_) {
        collateralRepossessed_ = collateral;
        MockERC20(collateralAsset).transfer(destination_, collateral);
    }

    function __setPrincipal(uint256 principal_) external {
        principal = principal_;
    }

    function __setClaimableFunds(uint256 claimable_) external {
        claimableFunds = claimable_;
    }

}

contract MockPoolCoverManager {

    function allocateLiquidity() external { }

    function triggerCoverLiquidation(uint256 remainingLosses_) external { }

}

contract MockReenteringERC20 is MockERC20 {

    address pool;

    constructor() MockERC20("Asset", "AST", 18) { }

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
