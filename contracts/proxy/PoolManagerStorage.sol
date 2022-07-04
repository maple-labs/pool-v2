// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

abstract contract PoolManagerStorage {

    address public admin;
    address public pendingAdmin;

    address public asset;
    address public globals;
    address public pool;

    address public poolCoverManager;
    address public withdrawalManager;

    bool public active;

    // TODO: Should this be located somewhere else?
    uint256 public liquidityCap;
    uint256 public unrealizedLosses;

    mapping(address => address) investmentManagers;
    mapping(address => bool)    isInvestmentManager;

    address[] investmentManagerList;

}
