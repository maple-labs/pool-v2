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
    bool public openToPublic;

    // TODO: Should this be located somewhere else?
    uint256 public liquidityCap;
    uint256 public unrealizedLosses;
    
    uint256 public coverFee;
    uint256 public managementFee;

    mapping(address => address) public investmentManagers;

    mapping(address => bool) public isInvestmentManager;
    mapping(address => bool) public isValidLender;

    address[] investmentManagerList;

}
