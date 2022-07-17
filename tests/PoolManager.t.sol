// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { Address, TestUtils, console } from "../modules/contract-test-utils/contracts/test.sol";
import { MockERC20 }                   from "../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { PoolManager }            from "../contracts/PoolManager.sol";
import { PoolManagerFactory }     from "../contracts/proxy/PoolManagerFactory.sol";
import { PoolManagerInitializer } from "../contracts/proxy/PoolManagerInitializer.sol";

import {
    MockERC20Pool,
    MockGlobals,
    MockLoan,
    MockLoanManager,
    MockPool,
    MockPoolCoverManager
} from "./mocks/Mocks.sol";

import { PoolManagerHarness } from "./harnesses/PoolManagerHarness.sol";

contract PoolManagerBase is TestUtils {

    address GOVERNOR      = address(new Address());
    address POOL_DELEGATE = address(new Address());

    MockERC20          asset;
    MockGlobals        globals;
    PoolManager        poolManager;
    PoolManagerFactory factory;

    address implementation;
    address initializer;

    function setUp() public virtual {
        globals = new MockGlobals(GOVERNOR);
        factory = new PoolManagerFactory(address(globals));
        asset   = new MockERC20("Asset", "AT", 18);

        implementation = address(new PoolManager());
        initializer    = address(new PoolManagerInitializer());

        globals.setValidPoolDelegate(POOL_DELEGATE, true);

        vm.startPrank(GOVERNOR);
        factory.registerImplementation(1, implementation, initializer);
        factory.setDefaultVersion(1);
        vm.stopPrank();

        string memory poolName_   = "Pool";
        string memory poolSymbol_ = "POOL1";

        bytes memory arguments = PoolManagerInitializer(initializer).encodeArguments(address(globals), POOL_DELEGATE, address(asset), poolName_, poolSymbol_);

        poolManager = PoolManager(PoolManagerFactory(factory).createInstance(arguments, keccak256(abi.encode(POOL_DELEGATE))));
    }

}

contract AcceptPendingAdmin_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());
    address SET_ADDRESS       = address(new Address());

    function setUp() public override {
        super.setUp();
        vm.prank(POOL_DELEGATE);
        poolManager.setPendingAdmin(SET_ADDRESS);
    }

    function test_acceptPendingAdmin_notPendingAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:APA:NOT_PENDING_ADMIN");
        poolManager.acceptPendingAdmin();
    }

    function test_acceptPendingAdmin_success() external {
        assertEq(poolManager.pendingAdmin(), SET_ADDRESS);
        assertEq(poolManager.admin(),        POOL_DELEGATE);

        vm.prank(SET_ADDRESS);
        poolManager.acceptPendingAdmin();

        assertEq(poolManager.pendingAdmin(), address(0));
        assertEq(poolManager.admin(),        SET_ADDRESS);
    }

}

contract SetPendingAdmin_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());
    address SET_ADDRESS       = address(new Address());

    function test_setPendingAdmin_notAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SPA:NOT_ADMIN");
        poolManager.setPendingAdmin(SET_ADDRESS);
    }

    function test_setPendingAdmin_success() external {
        assertEq(poolManager.pendingAdmin(), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setPendingAdmin(SET_ADDRESS);

        assertEq(poolManager.pendingAdmin(), SET_ADDRESS);
    }

}

contract SetActive_SetterTests is PoolManagerBase {

    function test_setActive_notGovernor() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SA:NOT_GLOBALS");
        poolManager.setActive(true);
    }

    function test_setActive_success() external {
        assertTrue(!poolManager.active());

        vm.prank(address(globals));
        poolManager.setActive(true);

        assertTrue(poolManager.active());

        vm.prank(address(globals));
        poolManager.setActive(false);

        assertTrue(!poolManager.active());
    }
}

contract SetAllowedLender_SetterTests is PoolManagerBase {

    function test_setAllowedLender_notAdmin() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SAL:NOT_ADMIN");
        poolManager.setAllowedLender(address(this), true);
    }

    function test_setAllowedLender_success() external {
        assertTrue(!poolManager.isValidLender(address(this)));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(address(this), true);

        assertTrue(poolManager.isValidLender(address(this)));

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(address(this), false);

        assertTrue(!poolManager.isValidLender(address(this)));
    }
}

contract SetCoverFee_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());

    uint256 newFee = uint256(0.1e18);

    function test_setCoverFee_notAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SCF:NOT_ADMIN");
        poolManager.setCoverFee(newFee);
    }

    function test_setCoverFee_success() external {
        assertEq(poolManager.coverFee(), uint256(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setCoverFee(newFee);

        assertEq(poolManager.coverFee(), newFee);
    }

}

contract SetLiquidityCap_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());

    function test_setLiquidityCap_notAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SLC:NOT_ADMIN");
        poolManager.setLiquidityCap(1000);
    }

    function test_setLiquidityCap_success() external {
        assertEq(poolManager.liquidityCap(), 0);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(1000);

        assertEq(poolManager.liquidityCap(), 1000);
    }

}

contract SetManagementFee_SetterTests is PoolManagerBase {

    address NOT_POOL_DELEGATE = address(new Address());

    uint256 newFee = uint256(0.1e18);

    function test_setManagementFee_notAdmin() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SMF:NOT_ADMIN");
        poolManager.setManagementFee(newFee);
    }

    function test_setManagementFee_success() external {
        assertEq(poolManager.managementFee(), uint256(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setManagementFee(newFee);

        assertEq(poolManager.managementFee(), newFee);
    }

}

contract SetOpenToPublic_SetterTests is PoolManagerBase {

    function test_setOpenToPublic_notAdmin() external {
        assertTrue(!poolManager.active());

        vm.expectRevert("PM:SOTP:NOT_ADMIN");
        poolManager.setOpenToPublic();
    }

    function test_setOpenToPublic_success() external {
        assertTrue(!poolManager.openToPublic());

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        assertTrue(poolManager.openToPublic());
    }
}

contract ClaimTests is PoolManagerBase {

    address LOAN     = address(new Address());
    address LP       = address(new Address());
    address TREASURY = address(new Address());

    MockERC20Pool        pool;
    MockLoanManager      loanManager;
    MockPoolCoverManager coverManager;

    uint256 coverPortion       = uint256(1e18);
    uint256 managementPortion  = uint256(10e18);
    uint256 managementFeeSplit = uint256(0.4e18);

    function setUp() public override {
        super.setUp();

        coverManager = new MockPoolCoverManager();
        loanManager  = new MockLoanManager();
        pool         = new MockERC20Pool(address(poolManager), address(asset), "Pool", "Pool");

        // Replace the pool in the poolManager
        address currentPool_ = poolManager.pool();
        vm.etch(currentPool_, address(pool).code);

        pool = MockERC20Pool(currentPool_);

        // Set mock cover manager
        vm.prank(POOL_DELEGATE);
        poolManager.setPoolCoverManager(address(coverManager));

        // Configure globals
        globals.setManagementFeeSplit(address(pool), managementFeeSplit);
        globals.setTreasury(TREASURY);

        // Set fees on LoanManager
        loanManager.__setCoverPortion(coverPortion);
        loanManager.__setManagementPortion(managementPortion);

        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), 1_000_000e18);

        // Get past zero supply check
        pool.mint(LP, 1);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setLoanManager(address(loanManager), true);
        poolManager.fund(1_000_000e18, LOAN, address(loanManager));
        vm.stopPrank();
    }

    function test_claim_failWithZeroSupply() external {
        pool.burn(LP, 1);

        vm.expectRevert("PM:C:ZERO_SUPPLY");
        poolManager.claim(LOAN);
    }

    function test_claim_failWithZeroLoanManager() external {
        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        address newLoan = address(new Address());

        vm.expectRevert("PM:C:NO_LOAN_MANAGER");
        poolManager.claim(newLoan);
    }

    function test_claim_failWithZeroCoverManager() external {
        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        // Nullify existing manager
        vm.prank(POOL_DELEGATE);
        poolManager.setPoolCoverManager(address(0));

        vm.expectRevert("PM:C:NO_COVER_MANAGER");
        poolManager.claim(LOAN);
    }

    function test_claim_failWithFailedCoverPayment() external {
        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        // Mint asset to the PoolManager
        asset.mint(address(poolManager), coverPortion - 1);

        vm.expectRevert("PM:C:PAY_COVER_FAILED");
        poolManager.claim(LOAN);
    }

    function test_claim_failWithTreasuryPayment() external {
        // Mint asset to the PoolManager
        asset.mint(address(poolManager), coverPortion + (managementPortion * 4 / 10) - 1);  //  4/10 of managementPortion goes to treasury

        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        vm.expectRevert("PM:C:PAY_TREASURY_FAILED");
        poolManager.claim(LOAN);
    }

    function test_claim_failWithPDPayment() external {
        // Mint asset to the PoolManager
        asset.mint(address(poolManager), coverPortion + managementPortion - 1);

        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        vm.expectRevert("PM:C:PAY_ADMIN_FAILED");
        poolManager.claim(LOAN);
    }

    function test_claim_success() external {
        // Mint asset to the PoolManager
        asset.mint(address(poolManager), coverPortion + managementPortion);

        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        assertEq(asset.balanceOf(POOL_DELEGATE),         0);
        assertEq(asset.balanceOf(TREASURY),              0);
        assertEq(asset.balanceOf(address(coverManager)), 0);

        poolManager.claim(LOAN);

        assertEq(asset.balanceOf(POOL_DELEGATE),         6e18); // 60% of 10e18 managementFeePortion
        assertEq(asset.balanceOf(TREASURY),              4e18); // 40% of 10e18 managementFeePortion
        assertEq(asset.balanceOf(address(coverManager)), coverPortion);
    }

}

contract FundTests is PoolManagerBase {

    MockLoan        loan;
    MockLoanManager loanManager;
    MockERC20Pool   pool;

    uint256 principalRequested = 1_000_000e18;
    uint256 collateralRequired = 0;

    function setUp() public override {
        super.setUp();

        loanManager = new MockLoanManager();
        loan        = new MockLoan(address(asset), address(asset));
        pool        = new MockERC20Pool(address(poolManager), address(asset), "Pool", "Pool");

        loan.__setPrincipal(principalRequested);
        loan.__setCollateral(collateralRequired);

        // Replace the pool in the poolManager
        address currentPool_ = poolManager.pool();
        vm.etch(currentPool_, address(pool).code);

        pool = MockERC20Pool(currentPool_);

        vm.prank(POOL_DELEGATE);
        poolManager.setLoanManager(address(loanManager), true);
    }

    function test_fund_notAdmin() external {
        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), principalRequested);

        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        vm.expectRevert("PM:F:NOT_ADMIN");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_zeroSupply() external {
        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), principalRequested);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:F:ZERO_SUPPLY");
        poolManager.fund(principalRequested, address(loan), address(loanManager));

    }

    function test_fund_transferFail() external {
        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("P:F:TRANSFER_FAIL");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_invalidLoanManager() external {
        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), principalRequested);

        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        // Remove the loanManager from the poolManager (added on setUp)
        vm.prank(POOL_DELEGATE);
        poolManager.setLoanManager(address(loanManager), false);

        vm.prank(POOL_DELEGATE);
        vm.expectRevert("PM:F:INVALID_LOAN_MANAGER");
        poolManager.fund(principalRequested, address(loan), address(loanManager));
    }

    function test_fund_success() external {
        // Mint ERC20 to pool
        asset.mint(address(poolManager.pool()), principalRequested);

        // Mint a share in pool so totalSupply is not 0
        pool.mint(address(new Address()), 1);

        assertEq(poolManager.loanManagers(address(loan)), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.fund(principalRequested, address(loan), address(loanManager));

        assertEq(poolManager.loanManagers(address(loan)), address(loanManager));
    }

}

contract RedeemTests is PoolManagerBase {

    address WITHDRAWAL_MANAGER = address(new Address());

    function test_redeem_notWithdrawalManager() external {
        vm.expectRevert("PM:R:NOT_WM");
        poolManager.redeem(0, address(0), address(0));
    }

    function test_redeem_success() external {
        vm.prank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);

        vm.etch(poolManager.pool(), address(new MockPool()).code);
        vm.prank(WITHDRAWAL_MANAGER);
        poolManager.redeem(0, address(0), address(0));
    }

}

contract SetLoanManager_SetterTests is PoolManagerBase {

    address LOAN_MANAGER      = address(new Address());
    address NOT_POOL_DELEGATE = address(new Address());

    function test_setLoanManager_notPD() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SIM:NOT_ADMIN");
        poolManager.setLoanManager(LOAN_MANAGER, true);
    }

    function test_setLoanManager() external {
        assertTrue(!poolManager.isLoanManager(LOAN_MANAGER));

        vm.prank(POOL_DELEGATE);
        poolManager.setLoanManager(LOAN_MANAGER, true);

        assertTrue(poolManager.isLoanManager(LOAN_MANAGER));

        vm.prank(POOL_DELEGATE);
        poolManager.setLoanManager(LOAN_MANAGER, false);

        assertTrue(!poolManager.isLoanManager(LOAN_MANAGER));
    }

}

contract SetWithdrawalManager_SetterTests is PoolManagerBase {

    address WITHDRAWAL_MANAGER = address(new Address());
    address NOT_POOL_DELEGATE  = address(new Address());

    function test_setWithdrawalManager_notPD() external {
        vm.prank(NOT_POOL_DELEGATE);
        vm.expectRevert("PM:SWM:NOT_ADMIN");
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);
    }

    function test_setWithdrawalManager() external {
        assertEq(poolManager.withdrawalManager(), address(0));

        vm.prank(POOL_DELEGATE);
        poolManager.setWithdrawalManager(WITHDRAWAL_MANAGER);

        assertEq(poolManager.withdrawalManager(), WITHDRAWAL_MANAGER);
    }

}

contract CanCallTests is PoolManagerBase {

    function test_canCall_deposit_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:D:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_deposit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:D:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_deposit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:deposit");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:D:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_depositWithPermit_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_depositWithPermit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_depositWithPermit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:depositWithPermit");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_, uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:DWP:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_mint_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:M:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mint_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:M:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mint_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:mint");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_);

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:M:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_mintWithPermit_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:MWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mintWithPermit_lenderNotAllowed() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(1_000e6, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:MWP:LENDER_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(receiver_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_mintWithPermit_liquidityCapExceeded() external {
        bytes32 functionId_ = bytes32("P:mintWithPermit");
        address receiver_   = address(this);

        vm.startPrank(POOL_DELEGATE);
        poolManager.setOpenToPublic();
        poolManager.setLiquidityCap(1_000e6);
        vm.stopPrank();

        bytes memory params = abi.encode(1_000e6 + 1, receiver_, uint256(0), uint256(0), uint8(0), bytes32(0), bytes32(0));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:MWP:DEPOSIT_GT_LIQ_CAP");
    }

    function test_canCall_transfer_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:transfer");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:T:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transfer_recipientNotAllowed() external {
        bytes32 functionId_ = bytes32("P:transfer");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:T:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(recipient_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transferFrom_notOpenToPublic() external {
        bytes32 functionId_ = bytes32("P:transferFrom");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(address(1), recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:TF:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setOpenToPublic();

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

    function test_canCall_transferFrom_recipientNotAllowed() external {
        bytes32 functionId_ = bytes32("P:transferFrom");
        address recipient_  = address(this);

        vm.prank(POOL_DELEGATE);
        poolManager.setLiquidityCap(type(uint256).max);

        bytes memory params = abi.encode(address(1), recipient_, uint256(1_000e6));

        ( bool canCall_, string memory errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(!canCall_);
        assertEq(errorMessage_, "P:TF:RECIPIENT_NOT_ALLOWED");

        vm.prank(POOL_DELEGATE);
        poolManager.setAllowedLender(recipient_, true);

        ( canCall_, errorMessage_ ) = poolManager.canCall(functionId_, address(this), params);

        assertTrue(canCall_);
        assertEq(errorMessage_, "");
    }

}
