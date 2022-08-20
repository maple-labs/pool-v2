// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface ILoanManager {

    // TODO: Add full interface.

    /**************/
    /*** Events ***/
    /**************/

    event IssuanceParamsUpdated(uint256 principalOut_, uint256 domainStart_, uint256 domainEnd_, uint256 issuanceRate_, uint256 accountedInterest_);

    event UnrealizedLossesUpdated(uint256 unrealizedLosses_);

}
