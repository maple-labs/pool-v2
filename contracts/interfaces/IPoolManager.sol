// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IMapleProxied } from "../../modules/maple-proxy-factory/contracts/interfaces/IMapleProxied.sol";

import { IPoolManagerStorage } from "./IPoolManagerStorage.sol";

interface IPoolManager is IMapleProxied, IPoolManagerStorage {

    /**************/
    /*** Events ***/
    /**************/

    event AllowedLenderSet(address indexed lender_, bool isValid_);

    event CollateralLiquidationTriggered(address indexed loan);

    event CollateralLiquidationFinished(address indexed loan_, uint256 unrealizedLosses_);

    event CoverDeposited(uint256 amount_);

    event CoverWithdrawn(uint256 amount_);

    event DefaultWarningRemoved(address indexed loan_);

    event DefaultWarningTriggered(address indexed loan_, uint256 newPaymentDueDate_);

    event DelegateManagementFeeRateSet(uint256 managementFeeRate_);

    event LoanManagerAdded(address indexed loanManager_);

    event LiquidityCapSet(uint256 liquidityCap_);

    event LoanFunded(address indexed loan_, address indexed loanManager_, uint256 amount_);

    event LoanManagerRemoved(address indexed loanManager_);

    event LoanRefinanced(address indexed loan_, address refinancer_, uint256 deadline_, bytes[] calls_, uint256 principalIncrease_);

    event OpenToPublic();

    event PendingDelegateAccepted(address indexed previousDelegate_, address indexed newDelegate_);

    event PendingDelegateSet(address indexed previousDelegate_, address indexed newDelegate_);

    event PoolConfigured(address loanManager_, address withdrawalManager_, uint256 liquidityCap_, uint256 delegateManagementFeeRate_);

    event RedeemProcessed(address indexed owner_, uint256 redeemableShares_, uint256 resultingAssets_);

    event RedeemRequested(address indexed owner_, uint256 shares_);

    event SetAsActive(bool active_);

    event SharesRemoved(address indexed owner_, uint256 shares_);

    event WithdrawalManagerSet(address indexed withdrawalManager_);

    event WithdrawalProcessed(address indexed owner_, uint256 redeemableShares_, uint256 resultingAssets_);

    /************************************/
    /*** Ownership Transfer Functions ***/
    /************************************/

    function acceptPendingPoolDelegate() external;

    function setPendingPoolDelegate(address pendingPoolDelegate_) external;

    /********************************/
    /*** Administrative Functions ***/
    /********************************/

    function configure(address loanManager_, address withdrawalManager_, uint256 liquidityCap_, uint256 managementFee_) external;

    function addLoanManager(address loanManager_) external;

    function removeLoanManager(address loanManager_) external;

    function setActive(bool active_) external;

    function setAllowedLender(address lender_, bool isValid_) external;

    function setLiquidityCap(uint256 liquidityCap_) external;

    function setDelegateManagementFeeRate(uint256 delegateManagementFeeRate_) external;

    function setOpenToPublic() external;

    function setWithdrawalManager(address withdrawalManager_) external;

    /**********************/
    /*** Loan Functions ***/
    /**********************/

    function acceptNewTerms(
        address loan_,
        address refinancer_,
        uint256 deadline_,
        bytes[] calldata calls_,
        uint256 principalIncrease_
    ) external;

    function fund(uint256 principal_, address loan_, address loanManager_) external;

    /*****************************/
    /*** Liquidation Functions ***/
    /*****************************/

    function finishCollateralLiquidation(address loan_) external;

    function triggerCollateralLiquidation(address loan_) external;

    function triggerDefaultWarning(address loan_, uint256 newPaymentDueDate_) external;

    function removeDefaultWarning(address loan_) external;

    /**********************/
    /*** Exit Functions ***/
    /**********************/

    function processRedeem(uint256 shares_, address owner_) external returns (uint256 redeemableShares_, uint256 resultingAssets_);

    function processWithdraw(uint256 assets_, address owner_) external returns (uint256 redeemableShares_, uint256 resultingAssets_);

    function removeShares(uint256 shares_, address owner_) external returns (uint256 sharesReturned_);

    function requestRedeem(uint256 shares_, address owner_) external;

    /***********************/
    /*** Cover Functions ***/
    /***********************/

    function depositCover(uint256 amount_) external;

    function withdrawCover(uint256 amount_, address recipient_) external;

    /*******************************/
    /*** LP Token View Functions ***/
    /*******************************/

    function getEscrowParams(address owner_, uint256 shares_) external view returns (uint256 escorwShares_, address destination);

    function convertToExitShares(uint256 amount_) external view returns (uint256 shares_);

    function maxDeposit(address receiver_) external view returns (uint256 maxAssets_);

    function maxMint(address receiver_) external view returns (uint256 maxShares_);

    function maxRedeem(address owner_) external view returns (uint256 maxShares_);

    function maxWithdraw(address owner_) external view returns (uint256 maxAssets_);

    function previewRedeem(address owner_, uint256 shares_) external view returns (uint256 assets_);

    function previewWithdraw(address owner_, uint256 assets_) external view returns (uint256 shares_);

    /**********************/
    /*** View Functions ***/
    /**********************/

    function canCall(bytes32 functionId_, address caller_, bytes memory data_) external view returns (bool canCall_, string memory errorMessage_);

    function globals() external view returns (address globals_);

    function governor() external view returns (address governor_);

    function hasSufficientCover() external view returns (bool hasSufficientCover_);

    function totalAssets() external view returns (uint256 totalAssets_);

    function unrealizedLosses() external view returns (uint256 unrealizedLosses_);

}
