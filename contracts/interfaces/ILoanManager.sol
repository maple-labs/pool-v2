// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IMapleProxied } from "../../modules/maple-proxy-factory/contracts/interfaces/IMapleProxied.sol";

import { ILoanManagerStorage } from "./ILoanManagerStorage.sol";

interface ILoanManager is IMapleProxied, ILoanManagerStorage {

    /**************/
    /*** Events ***/
    /**************/

    /**
     * @dev   Emitted when `setAllowedSlippage` is called.
     * @param collateralAsset_ Address of a collateral asset.
     * @param newSlippage_     New value for `allowedSlippage`.
     */
    event AllowedSlippageSet(address collateralAsset_, uint256 newSlippage_);

    /**
     * @dev   Emitted when `setMinRatio` is called.
     * @param collateralAsset_ Address of a collateral asset.
     * @param newMinRatio_     New value for `minRatio`.
     */
    event MinRatioSet(address collateralAsset_, uint256 newMinRatio_);

    /**************************/
    /*** External Functions ***/
    /**************************/

    function acceptNewTerms(address loan_, address refinancer_, uint256 deadline_, bytes[] calldata calls_) external;

    function claim(uint256 principal_, uint256 interest_, uint256 previousPaymentDueDate_, uint256 nextPaymentDueDate_) external;

    function finishCollateralLiquidation(address loan_) external returns (uint256 remainingLosses_, uint256 platformFees_);

    function fund(address loanAddress_) external;

    function removeDefaultWarning(address loan_, bool isCalledByGovernor_) external;

    function setAllowedSlippage(address collateralAsset_, uint256 allowedSlippage_) external;

    function setMinRatio(address collateralAsset_, uint256 minRatio_) external;

    function triggerDefaultWarning(address loan_, bool isGovernor_) external;

    function triggerCollateralLiquidation(address loan_) external;

    /**********************/
    /*** View Functions ***/
    /**********************/

    function PRECISION() external returns (uint256 precision_);

    function HUNDRED_PERCENT() external returns (uint256 hundredPercent_);

    function assetsUnderManagement() external view returns (uint256 assetsUnderManagement_);

    function getAccruedInterest() external view returns (uint256 accruedInterest_);

    function getExpectedAmount(address collateralAsset_, uint256 swapAmount_) external view returns (uint256 returnAmount_);

    function globals() external view returns (address globals_);

    function governor() external view returns (address governor_);

    function isLiquidationActive(address loan_) external view returns (bool isActive_);

    function poolDelegate() external view returns (address poolDelegate_);

    function mapleTreasury() external view returns (address treasury_);

    /**************/
    /*** Events ***/
    /**************/

    event IssuanceParamsUpdated(uint256 principalOut_, uint256 domainStart_, uint256 domainEnd_, uint256 issuanceRate_, uint256 accountedInterest_);

    event UnrealizedLossesUpdated(uint256 unrealizedLosses_);

}
