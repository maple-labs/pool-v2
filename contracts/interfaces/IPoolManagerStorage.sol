// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

interface IPoolManagerStorage {

    function active() external view returns (bool active_);

    function asset() external view returns (address asset_);

    function configured() external view returns (bool configured_);

    function globals() external view returns (address globals_);

    function isLoanManager(address loan_) external view returns (bool isLoanManager_);

    function isValidLender(address lender) external view returns (bool isValidLender_);

    function loanManagerList(uint256 index_) external view returns (address loanManager_);

    function loanManagers(address loan_) external view returns (address loanManager_);

    function liquidityCap() external view returns (uint256 liquidityCap_);

    function delegateManagementFeeRate() external view returns (uint256 delegateManagementFeeRate_);

    function openToPublic() external view returns (bool openToPublic_);

    function pendingPoolDelegate() external view returns (address pendingPoolDelegate_);

    function pool() external view returns (address pool_);

    function poolDelegate() external view returns (address poolDelegate_);

    function poolDelegateCover() external view returns (address poolDelegateCover_);

    function unrealizedLosses() external view returns (uint256 unrealizedLosses_);

    function withdrawalManager() external view returns (address withdrawalManager_);

}
