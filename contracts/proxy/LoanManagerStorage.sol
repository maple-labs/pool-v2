// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

abstract contract LoanManagerStorage {

    address public fundsAsset;
    address public liquidator;
    address public pool;
    address public poolManager;

    uint256 public accountedInterest;
    uint256 public issuanceRate;
    uint256 public domainStart;
    uint256 public loanCounter;
    uint256 public loanWithEarliestPaymentDueDate;
    uint256 public principalOut;
    uint256 public domainEnd;

    mapping(address => uint256) public loanIdOf;
    mapping(address => uint256) public principalOf;
    mapping(address => uint256) public allowedSlippageFor;
    mapping(address => uint256) public minRatioFor;

    mapping(address => LiquidationInfo) public liquidationInfo;

    mapping(uint256 => LoanInfo) public loans;

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
        address vehicle;
    }

    struct LiquidationInfo {
        uint256 principalToCover;
        address liquidator;
    }

}
