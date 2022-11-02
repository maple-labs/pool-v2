// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IMapleProxied } from "../../modules/maple-proxy-factory/contracts/interfaces/IMapleProxied.sol";

import { ILoanManagerStorage } from "./ILoanManagerStorage.sol";

interface ITransitionLoanManager is IMapleProxied, ILoanManagerStorage {

    /******************************************************************************************************************************/
    /*** Events                                                                                                                 ***/
    /******************************************************************************************************************************/

    /**
     *  @dev   Emitted when the issuance parameters are changed.
     *  @param domainEnd_         The timestamp of the domain end.
     *  @param issuanceRate_      New value for the issuance rate.
     *  @param accountedInterest_ The amount of accounted interest.
     */
    event IssuanceParamsUpdated(uint48 domainEnd_, uint256 issuanceRate_, uint112 accountedInterest_);

    /**
     *  @dev   Emitted when a payment is removed from the LoanManager payments array.
     *  @param loan_      The address of the loan.
     *  @param paymentId_ The payment ID of the payment that was removed.
     */
    event PaymentAdded(
        address indexed loan_,
        uint256 indexed paymentId_,
        uint256 platformManagementFeeRate_,
        uint256 delegateManagementFeeRate_,
        uint256 startDate_,
        uint256 nextPaymentDueDate_,
        uint256 netRefinanceInterest_,
        uint256 newRate_
    );

    /**
     *  @dev   Emitted when a payment is removed from the LoanManager payments array.
     *  @param loan_      The address of the loan.
     *  @param paymentId_ The payment ID of the payment that was removed.
     */
    event PaymentRemoved(address indexed loan_, uint256 indexed paymentId_);

    /**
     *  @dev   Emitted when principal out is updated
     *  @param principalOut_ The new value for principal out.
     */
    event PrincipalOutUpdated(uint128 principalOut_);

    /**
     *  @dev   Emitted when unrealized losses is updated.
     *  @param unrealizedLosses_ The new value for unrealized losses.
     */
    event UnrealizedLossesUpdated(uint256 unrealizedLosses_);

    /******************************************************************************************************************************/
    /*** External Functions                                                                                                     ***/
    /******************************************************************************************************************************/

    /**
     *  @dev   Adds a new loan to this loan manager.
     *  @param loan_ The address of the loan.
     */
    function add(address loan_) external;

    /**
     *  @dev   Sets the ownership of loans to an address.
     *  @param loans_      An array of loan addresses.
     *  @param newLenders_ An array of lenders to set pending ownership to.
     */
    function setOwnershipTo(address[] calldata loans_, address[] calldata newLenders_) external;

    /**
     *  @dev   Takes the ownership of the loans.
     *  @param loans_ An array with multiple loan addresses.
     */
    function takeOwnership(address[] calldata loans_) external;

    /******************************************************************************************************************************/
    /*** View Functions                                                                                                         ***/
    /******************************************************************************************************************************/

    /**
     *  @dev    Returns the precision used for the contract.
     *  @return precision_ The precision used for the contract.
     */
    function PRECISION() external view returns (uint256 precision_);

    /**
     *  @dev    Returns the value considered as the hundred percent.
     *  @return hundredPercent_ The value considered as the hundred percent.
     */
    function HUNDRED_PERCENT() external view returns (uint256 hundredPercent_);

    /**
     *  @dev    Gets the amount of assets under the management of the contract.
     *  @return assetsUnderManagement_ The amount of assets under the management of the contract.
     */
    function assetsUnderManagement() external view returns (uint256 assetsUnderManagement_);

    /**
     *  @dev    Gets the amount of accrued interest up until this point in time.
     *  @return accruedInterest_ The amount of accrued interest up until this point in time.
     */
    function getAccruedInterest() external view returns (uint256 accruedInterest_);

    /**
     *  @dev    Gets the address of the Maple globals contract.
     *  @return globals_ The address of the Maple globals contract.
     */
    function globals() external view returns (address globals_);

    /**
     *  @dev    Gets the address of the migration admin.
     *  @return migrationAdmin_ The address of the migration admin.
     */
    function migrationAdmin() external view returns (address migrationAdmin_);

}
