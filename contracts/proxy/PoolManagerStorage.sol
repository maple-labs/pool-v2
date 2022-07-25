// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IPoolManagerStorage } from "../interfaces/IPoolManagerStorage.sol";

abstract contract PoolManagerStorage is IPoolManagerStorage {

    address public admin;
    address public pendingAdmin;

    address public asset;
    address public globals;
    address public pool;

    address public poolDelegateCover;
    address public withdrawalManager;

    bool public active;
    bool public openToPublic;

    // TODO: Should this be located somewhere else?
    uint256 public liquidityCap;
    uint256 public unrealizedLosses;
    uint256 public override managementFee;

    mapping(address => address) public loanManagers;

    mapping(address => bool) public isLoanManager;
    mapping(address => bool) public isValidLender;

    address[] loanManagerList;

}
