// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IERC4626 } from "../../modules/revenue-distribution-token/contracts/interfaces/IERC4626.sol";

interface IHybridPool is IERC4626 {

    function enableInvestmentManager(address contract_) external;
    function disableInvestmentManager(address contract_) external;
    function investmentManager(address investment_) external view returns (address investmentManager_);
    function investmentManagers() external view returns (address[] memory investmentManagers_);

    function poolDelegate() external view returns (address poolDelegate_);
    function nominatePoolDelegate(address account_) external;
    function acceptNomination() external;

    function fund(address investment_, uint256 principal_, address investmentManager_) external;
    function claim(address investment_) external;

    function depositWithPermit(uint256 assets_, address receiver_, uint256 deadline_, uint8 v_, bytes32 r_, bytes32 s_) external returns (uint256 shares_);
    function mintWithPermit(uint256 shares_, address receiver_, uint256 maxAssets_, uint256 deadline_, uint8 v_, bytes32 r_, bytes32 s_) external returns (uint256 assets_);

    function totalAssets(address account_) external view returns (uint256 totalAssets_);

}
