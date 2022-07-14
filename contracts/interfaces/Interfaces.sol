// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface IAuctioneerLike {

    function getExpectedAmount(uint256 swapAmount_) external view returns (uint256 expectedAmount_);

}

interface IERC20Like {

    function approve(address spender_, uint256 amount_) external;

    function balanceOf(address account_) external view returns (uint256 balance_);

    function totalSupply() external view returns (uint256 totalSupply_);

    function transfer(address destination_, uint256 amount_) external;

}

interface IGlobalsLike {

    function governor() external view returns (address governor_);

    function isPoolDelegate(address account_) external view returns (bool isPoolDelegate_);

    function managementFeeSplit(address pool) external view returns (uint256 split_);

    function mapleTreasury() external view returns (address mapleTreasury_);

    function ownedPool(address poolDelegate_) external view returns (address pool_);

}

interface ILoanManagerLike {

    function claim(address loan_) external returns (uint256 coverPortion_, uint256 managementPortion_);

    function fund(address loan_) external;

    function triggerCollateralLiquidation(address loan_, address auctioneer_) external returns (uint256 increasedUnrealizedLosses_);

    function finishCollateralLiquidation(address loan_) external returns (uint256 decreasedUnrealizedLosses, uint256 remainingLosses);

    function assetsUnderManagement() external view returns (uint256 assetsUnderManagement_);

}

interface ILiquidatorLike {

    function liquidatePortion(uint256 swapAmount_, uint256 maxReturnAmount_, bytes calldata data_) external;

}

interface ILoanLike {

    function claimableFunds() external view returns (uint256 claimableFunds_);

    function claimFunds(uint256 amount_, address destination_) external;

    function collateralAsset() external view returns(address asset_);

    function fundsAsset() external view returns (address asset_);

    function fundLoan(address lender_, uint256 amount_) external returns (uint256 fundsLent_);

    function getClosingPaymentBreakdown() external view returns (uint256 principal_, uint256 interest_);

    function getNextPaymentBreakdown() external view returns (uint256 principal_, uint256 interest_);

    function gracePeriod() external view returns (uint256 gracePeriod_);

    function interestRate() external view returns (uint256 interestRate_);

    function lateFeeRate() external view returns (uint256 lateFeeRate_);

    function nextPaymentDueDate() external view returns (uint256 nextPaymentDueDate_);

    function paymentInterval() external view returns (uint256 paymentInterval_);

    function paymentsRemaining() external view returns (uint256 paymentsRemaining_);

    function principal() external view returns (uint256 principal_);

    function principalRequested() external view returns (uint256 principalRequested_);

    function repossess(address destination_) external returns (uint256 collateralRepossessed_, uint256 fundsRepossessed_);

}

interface IPoolCoverManagerLike {

    function allocateLiquidity() external;

    function triggerCoverLiquidation(uint256 totalLiquidationAmount_) external returns (uint256[] memory liquidationAmounts_);

}

interface IPoolLike {

    function asset() external view returns (address asset_);

    function deposit(uint256 assets_, address receiver_) external returns (uint256 shares_);

    function manager() external view returns (address manager_);

    function previewMint(uint256 shares_) external view returns (uint256 assets_);

    function redeem(uint256 shares_, address receiver_, address owner_) external returns (uint256 assets_);

}

interface IPoolManagerLike {

    function canCall(bytes32 functionId_, address caller_, bytes memory data_) external view returns (bool canCall_, string memory errorMessage_);

    function claim(address loan_) external;

    function fund(uint256 princiaplAmount_, address loan_, address loanManager_) external;

    function getFees() external view returns (uint256 coverFee_, uint256 managementFee_);

    function loanManager() external view returns (address loanManager_);

    function poolCoverManager() external view returns (address poolCoverManager_);

    function setLoanManager(address loanManager_, bool isValid_) external;

    function setPoolCoverManager(address poolCoverManager_) external;

    function setWithdrawalManager(address withdrawalManager_) external;

    function totalAssets() external view returns (uint256 totalAssets_);

    function unrealizedLosses() external view returns (uint256 unrealizedLosses_);

}
