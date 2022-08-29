// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IMapleProxied } from "../../modules/maple-proxy-factory/contracts/interfaces/IMapleProxied.sol";

import { ILoanManagerStorage } from "./ILoanManagerStorage.sol";

interface ITransitionLoanManager is IMapleProxied, ILoanManagerStorage {

    /**************/
    /*** Events ***/
    /**************/

    /**
     *  @dev   Emitted when the issuance parameters are changed.
     *  @param domainEnd_         The timestamp of the domain end.
     *  @param issuanceRate_      New value for the issuance rate.
     *  @param accountedInterest_ The amount of accounted interest.
     */
    event IssuanceParamsUpdated(uint256 principalOut_, uint256 domainStart_, uint256 domainEnd_, uint256 issuanceRate_, uint256 accountedInterest_);

    /**
     *  @dev   Emitted when unrealized losses is updated.
     *  @param unrealizedLosses_ The new value for unrealized losses.
     */
    event UnrealizedLossesUpdated(uint256 unrealizedLosses_);

    /**************************/
    /*** External Functions ***/
    /**************************/

    /**
     *  @dev   Adds a new loan to this loan manager.
     *  @param loanAddress_ The address of the loan.
     */
    function add(address loanAddress_) external;

    /**
     *  @dev   Sets the ownership of loans to an address.
     *  @param loanAddress_ An array with multiple loan addresses.
     *  @param newLender_   The address of the new lender.
     */
    function setOwnershipTo(address[] calldata loanAddress_, address newLender_) external;

    /**
     *  @dev   Takes the ownership of the loans.
     *  @param loanAddress_ An array with multiple loan addresses.
     */
    function takeOwnership(address[] calldata loanAddress_) external;

    /**********************/
    /*** View Functions ***/
    /**********************/

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
