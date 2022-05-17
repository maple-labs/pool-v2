// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { ERC20 } from "../modules/revenue-distribution-token/modules/erc20/contracts/ERC20.sol";

import { IHybridPool } from "./interfaces/IHybridPool.sol";

contract HybridPool is IHybridPool, ERC20 {

    constructor(string memory name_, string memory symbol_, address asset_, address owner_) ERC20(name_, symbol_, ERC20(asset_).decimals()) { }

    // Pool ownership
    function poolDelegate() external view override returns (address poolDelegate_) { }
    function nominatePoolDelegate(address account_) external override { }
    function acceptNomination() external override { }

    // Investment management administration
    function enableInvestmentManager(address contract_) external override { }
    function disableInvestmentManager(address contract_) external override { }
    function investmentManager(address investment_) external view override returns (address investmentManager_) { }
    function investmentManagers() external view override returns (address[] memory investmentManagers_) { }

    // Investment interaction
    function fund(address investment_, uint256 principal_, address investmentManager_) external override { }
    function claim(address investment_) external override { }

    // ERC-4626
    function asset() external view override returns (address asset_) { }

    function totalAssets() external view override returns (uint256 totalAssets_) { }
    function totalAssets(address account_) external view override returns (uint256 totalAssets_) { }

    function convertToAssets(uint256 shares_) external view override returns (uint256 assets_) { }
    function convertToShares(uint256 assets_) external view override returns (uint256 shares_) { }

    function deposit(uint256 assets_, address receiver_) external override returns (uint256 shares_) { }
    function mint(uint256 shares_, address receiver_) external override returns (uint256 assets_) { }
    function redeem(uint256 shares_, address receiver_, address owner_) external override returns (uint256 assets_) { }
    function withdraw(uint256 assets_, address receiver_, address owner_) external override returns (uint256 shares_) { }

    function depositWithPermit(uint256 assets_, address receiver_, uint256 deadline_, uint8 v_, bytes32 r_, bytes32 s_) external override returns (uint256 shares_) { }
    function mintWithPermit(uint256 shares_, address receiver_, uint256 maxAssets_, uint256 deadline_, uint8 v_, bytes32 r_, bytes32 s_) external override returns (uint256 assets_) { }

    function maxDeposit(address receiver_) external view override returns (uint256 assets_) { }
    function maxMint(address receiver_) external view override returns (uint256 shares_) { }
    function maxRedeem(address owner_) external view override returns (uint256 shares_) { }
    function maxWithdraw(address owner_) external view override returns (uint256 assets_) { }

    function previewDeposit(uint256 assets_) external view override returns (uint256 shares_) { }
    function previewMint(uint256 shares_) external view override returns (uint256 assets_) { }
    function previewRedeem(uint256 shares_) external view override returns (uint256 assets_) { }
    function previewWithdraw(uint256 assets_) external view override returns (uint256 shares_) { }

}
