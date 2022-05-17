// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface IInvestmentManager {

    function updateAccounting(address investment_, uint256 claimedAssets_) external;

    function totalAssets() external view returns (uint256 totalAssets_);

}
