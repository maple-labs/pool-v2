// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { ILoanManagerStorage } from "../interfaces/ILoanManagerStorage.sol";

abstract contract LoanManagerStorage is ILoanManagerStorage {

    // TODO: Can this struct be optimized?
    struct LoanInfo {
        uint256 previous;
        uint256 next;
        uint256 incomingNetInterest;
        uint256 refinanceInterest;
        uint256 issuanceRate;
        uint256 startDate;
        uint256 paymentDueDate;
        uint256 platformManagementFeeRate;
        uint256 delegateManagementFeeRate;
    }

    struct LiquidationInfo {
        uint256 principal;
        uint256 interest;
        uint256 platformFees;
        address liquidator;
        bool    triggeredByGovernor;
    }

    address public override fundsAsset;
    address public override pool;
    address public override poolManager;

    uint256 public override accountedInterest;
    uint256 public override domainStart;
    uint256 public override domainEnd;
    uint256 public override issuanceRate;
    uint256 public override loanCounter;
    uint256 public override loanWithEarliestPaymentDueDate;
    uint256 public override principalOut;
    uint256 public override unrealizedLosses;

    mapping(address => uint256) public override loanIdOf;
    mapping(address => uint256) public override allowedSlippageFor;
    mapping(address => uint256) public override minRatioFor;

    mapping(address => LiquidationInfo) public override liquidationInfo;

    mapping(uint256 => LoanInfo) public override loans;

}
