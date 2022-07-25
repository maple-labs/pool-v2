// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { ERC20 }       from "../modules/erc20/contracts/ERC20.sol";
import { ERC20Helper } from "../modules/erc20-helper/src/ERC20Helper.sol";

import { IPoolManagerLike } from "./interfaces/Interfaces.sol";
import { IERC20, IPool }    from "./interfaces/IPool.sol";

// TODO: Revisit function order

contract Pool is IPool, ERC20 {

    address public override asset;    // Underlying ERC-20 asset handled by the ERC-4626 contract.
    address public override manager;  // Address of the contract that manages administrative functionality.

    uint256 private locked = 1;  // Used when checking for reentrancy.

    constructor(address manager_, address asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_, ERC20(asset_).decimals()) {
        require((manager = manager_) != address(0), "P:C:ZERO_ADDRESS");

        asset = asset_;
        ERC20(asset_).approve(manager_, type(uint256).max);
    }

    /*****************/
    /*** Modifiers ***/
    /*****************/

    modifier checkCall(bytes32 functionId_) {
        ( bool success_, string memory errorMessage_ ) = IPoolManagerLike(manager).canCall(functionId_, msg.sender, msg.data[4:]);

        require(success_, errorMessage_);

        _;
    }

    modifier nonReentrant() {
        require(locked == 1, "P:LOCKED");

        locked = 2;

        _;

        locked = 1;
    }

    /********************/
    /*** LP Functions ***/
    /********************/

    function deposit(uint256 assets_, address receiver_) external virtual override nonReentrant checkCall("P:deposit") returns (uint256 shares_) {
        _mint(shares_ = previewDeposit(assets_), assets_, receiver_, msg.sender);
    }

    function depositWithPermit(
        uint256 assets_,
        address receiver_,
        uint256 deadline_,
        uint8   v_,
        bytes32 r_,
        bytes32 s_
    )
        external virtual override nonReentrant checkCall("P:depositWithPermit") returns (uint256 shares_)
    {
        ERC20(asset).permit(msg.sender, address(this), assets_, deadline_, v_, r_, s_);
        _mint(shares_ = previewDeposit(assets_), assets_, receiver_, msg.sender);
    }

    function mint(uint256 shares_, address receiver_) external virtual override nonReentrant checkCall("P:mint") returns (uint256 assets_) {
        _mint(shares_, assets_ = previewMint(shares_), receiver_, msg.sender);
    }

    function mintWithPermit(
        uint256 shares_,
        address receiver_,
        uint256 maxAssets_,
        uint256 deadline_,
        uint8   v_,
        bytes32 r_,
        bytes32 s_
    )
        external virtual override nonReentrant checkCall("P:mintWithPermit") returns (uint256 assets_)
    {
        require((assets_ = previewMint(shares_)) <= maxAssets_, "P:MWP:INSUFFICIENT_PERMIT");

        ERC20(asset).permit(msg.sender, address(this), maxAssets_, deadline_, v_, r_, s_);
        _mint(shares_, assets_, receiver_, msg.sender);
    }

    function redeem(uint256 shares_, address receiver_, address owner_) external virtual override nonReentrant returns (uint256 assets_) {
        require(msg.sender == manager, "P:R:NOT_MANAGER");
        _burn(shares_, assets_ = previewRedeem(shares_), receiver_, owner_, msg.sender);
    }

    function withdraw(uint256 assets_, address receiver_, address owner_) external virtual override nonReentrant returns (uint256 shares_) {
        require(msg.sender == manager, "P:W:NOT_MANAGER");

        _burn(shares_ = previewWithdraw(assets_), assets_, receiver_, owner_, msg.sender);
    }

    function transfer(
        address recipient_,
        uint256 amount_
    )
        public override(IERC20, ERC20) checkCall("P:transfer") returns (bool success_)
    {
        return super.transfer(recipient_, amount_);
    }

    function transferFrom(
        address owner_,
        address recipient_,
        uint256 amount_
    )
        public override(IERC20, ERC20) checkCall("P:transferFrom") returns (bool success_)
    {
        return super.transferFrom(owner_, recipient_, amount_);
    }

    /**************************/
    /*** Internal Functions ***/
    /**************************/

    function _burn(uint256 shares_, uint256 assets_, address receiver_, address owner_, address caller_) internal {
        require(receiver_ != address(0), "P:B:ZERO_RECEIVER");
        require(shares_   != uint256(0), "P:B:ZERO_SHARES");
        require(assets_   != uint256(0), "P:B:ZERO_ASSETS");

        if (caller_ != owner_) {
            _decreaseAllowance(owner_, caller_, shares_);
        }

        _burn(owner_, shares_);

        emit Withdraw(caller_, receiver_, owner_, assets_, shares_);

        require(ERC20Helper.transfer(asset, receiver_, assets_), "P:B:TRANSFER");
    }

    function _mint(uint256 shares_, uint256 assets_, address receiver_, address caller_) internal {
        require(receiver_ != address(0), "P:M:ZERO_RECEIVER");
        require(shares_   != uint256(0), "P:M:ZERO_SHARES");
        require(assets_   != uint256(0), "P:M:ZERO_ASSETS");

        _mint(receiver_, shares_);

        emit Deposit(caller_, receiver_, assets_, shares_);

        require(ERC20Helper.transferFrom(asset, caller_, address(this), assets_), "P:M:TRANSFER_FROM");
    }

    function _divRoundUp(uint256 numerator_, uint256 divisor_) internal pure returns (uint256 result_) {
       return (numerator_ / divisor_) + (numerator_ % divisor_ > 0 ? 1 : 0);
    }

    /*******************************/
    /*** External View Functions ***/
    /*******************************/

    function maxDeposit(address receiver_) external pure virtual override returns (uint256 maxAssets_) {
        receiver_;  // Silence warning
        maxAssets_ = type(uint256).max;
    }

    function maxMint(address receiver_) external pure virtual override returns (uint256 maxShares_) {
        receiver_;  // Silence warning
        maxShares_ = type(uint256).max;
    }

    function maxRedeem(address owner_) external view virtual override returns (uint256 maxShares_) {
        maxShares_ = balanceOf[owner_];
    }

    function maxWithdraw(address owner_) external view virtual override returns (uint256 maxAssets_) {
        maxAssets_ = balanceOfAssets(owner_);
    }

    /*****************************/
    /*** Public View Functions ***/
    /*****************************/

    function balanceOfAssets(address account_) public view virtual override returns (uint256 balanceOfAssets_) {
        return convertToAssets(balanceOf[account_]);
    }

    function convertToAssets(uint256 shares_) public view virtual override returns (uint256 assets_) {
        uint256 totalSupply_ = totalSupply;

        assets_ = totalSupply_ == 0 ? shares_ : (shares_ * totalAssets()) / totalSupply_;
    }

    function convertToShares(uint256 assets_) public view virtual override returns (uint256 shares_) {
        uint256 totalSupply_ = totalSupply;

        shares_ = totalSupply_ == 0 ? assets_ : (assets_ * totalSupply_) / totalAssets();
    }

    // TODO consider unrealized losses

    function previewDeposit(uint256 assets_) public view virtual override returns (uint256 shares_) {
        // As per https://eips.ethereum.org/EIPS/eip-4626#security-considerations,
        // it should round DOWN if it’s calculating the amount of shares to issue to a user, given an amount of assets provided.
        shares_ = convertToShares(assets_);
    }

    function previewMint(uint256 shares_) public view virtual override returns (uint256 assets_) {
        uint256 totalSupply_ = totalSupply;

        // As per https://eips.ethereum.org/EIPS/eip-4626#security-considerations,
        // it should round UP if it’s calculating the amount of assets a user must provide, to be issued a given amount of shares.
        assets_ = totalSupply_ == 0 ? shares_ : _divRoundUp(shares_ * totalAssets(), totalSupply_);
    }

    function previewRedeem(uint256 shares_) public view virtual override returns (uint256 assets_) {
        uint256 totalSupply_ = totalSupply;
        // As per https://eips.ethereum.org/EIPS/eip-4626#security-considerations,
        // it should round DOWN if it’s calculating the amount of assets to send to a user, given amount of shares returned.

        assets_ = totalSupply_ == 0 ? shares_ : (shares_ * totalAssetsWithUnrealizedLosses()) / totalSupply_;
    }

    // TODO: Add back unrealized losses
    function previewWithdraw(uint256 assets_) public view virtual override returns (uint256 shares_) {
        uint256 totalSupply_ = totalSupply;

        // As per https://eips.ethereum.org/EIPS/eip-4626#security-considerations,
        // it should round UP if it’s calculating the amount of shares a user must return, to be sent a given amount of assets.
        shares_ = totalSupply_ == 0 ? assets_ : _divRoundUp(assets_ * totalSupply_, totalAssetsWithUnrealizedLosses());
    }

    function totalAssets() public view virtual override returns (uint256 totalManagedAssets_) {
        return IPoolManagerLike(manager).totalAssets();
    }

    function totalAssetsWithUnrealizedLosses() public view virtual /*override*/ returns (uint256 totalManagedAssets_) {
        return IPoolManagerLike(manager).totalAssets() - IPoolManagerLike(manager).unrealizedLosses();
    }

}
