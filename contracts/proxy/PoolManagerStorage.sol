// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IPoolManagerStorage } from "../interfaces/IPoolManagerStorage.sol";

abstract contract PoolManagerStorage is IPoolManagerStorage {

    address public override poolDelegate;
    address public override pendingPoolDelegate;
    address public override admin;
    address public override pendingAdmin;

    address public override asset;
    address public override globals;
    address public override pool;

    address public override poolDelegateCover;
    address public override withdrawalManager;

    bool public override active;
    bool public override openToPublic;

    // TODO: Should this be located somewhere else?
    uint256 public override liquidityCap;
    uint256 public override unrealizedLosses;
    uint256 public override managementFee;

    mapping(address => address) public override loanManagers;

    mapping(address => bool) public override isLoanManager;
    mapping(address => bool) public override isValidLender;

    address[] public override loanManagerList;

}
