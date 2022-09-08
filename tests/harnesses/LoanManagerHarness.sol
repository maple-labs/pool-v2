// SDPX-License-Identifier: AGLP-3.0-only
pragma solidity ^0.8.7;

import { Address, console } from "../../modules/contract-test-utils/contracts/test.sol";

import { LoanManager } from "../../contracts/LoanManager.sol";

contract LoanManagerHarness is LoanManager {

    function addPaymentToList(uint48 paymentDueDate_) external returns (uint256 paymentId_) {
        paymentId_ = _addPaymentToList(paymentDueDate_);
    }

    function removePaymentFromList(uint256 paymentId_) external {
        _removePaymentFromList(paymentId_);
    }

    function __setUnrealizedLosses(uint256 unrealizedLosses_) external {
        unrealizedLosses = _uint128(unrealizedLosses_);
    }

    function __queueNextPayment(address loan_, uint256 startDate_, uint256 nextPaymentDueDate_) external returns (uint256 newRate_) {
        newRate_ = _queueNextPayment(loan_, startDate_, nextPaymentDueDate_);
    }

    function castUint24(uint256 input_) external pure returns (uint24 output_) {
        return _uint24(input_);
    }

    function castUint48(uint256 input_) external pure returns (uint48 output_) {
        return _uint48(input_);
    }

    function castUint96(uint256 input_) external pure returns (uint96 output_) {
        return _uint96(input_);
    }

    function castUint112(uint256 input_) external pure returns (uint112 output_) {
        return _uint112(input_);
    }

    function castUint120(uint256 input_) external pure returns (uint120 output_) {
        return _uint120(input_);
    }

    function castUint128(uint256 input_) external pure returns (uint128 output_) {
        return _uint128(input_);
    }

}
