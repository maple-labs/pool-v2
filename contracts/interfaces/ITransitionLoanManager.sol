// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IMapleProxied } from "../../modules/maple-proxy-factory/contracts/interfaces/IMapleProxied.sol";

import { ILoanManagerStorage } from "./ILoanManagerStorage.sol";

interface ITransitionLoanManager is IMapleProxied, ILoanManagerStorage {

    /**************/
    /*** Events ***/
    /**************/

    event IssuanceParamsUpdated(uint256 principalOut_, uint256 domainStart_, uint256 domainEnd_, uint256 issuanceRate_, uint256 accountedInterest_);

    event UnrealizedLossesUpdated(uint256 unrealizedLosses_);

    /**************************/
    /*** External Functions ***/
    /**************************/

    function add(address loanAddress_) external;

    function takeOwnership(address[] calldata loanAddress_) external;

    /**********************/
    /*** View Functions ***/
    /**********************/

    function PRECISION() external view returns (uint256 precision_);

    function SCALED_ONE() external view returns (uint256 scaledOne_);

    function assetsUnderManagement() external view returns (uint256 assetsUnderManagement_);

    function getAccruedInterest() external view returns (uint256 accruedInterest_);

    function globals() external view returns (address globals_);

    function poolDelegate() external view returns (address poolDelegate_);

}
