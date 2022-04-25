// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IInvestmentManagerLike, ILoanLike } from "./interfaces/Interfaces.sol";

/// @dev A loan wrapper for pools that can manage multiple loans.
contract LoanInvestmentManager is IInvestmentManagerLike {

    address pool; 

    mapping (address => InvestmentVehicle) public investments; // This contract manages multiple loans

    // TODO: We could consolidate lastClaim and nextClaim into a single storage slot
    struct InvestmentVehicle {
        uint256 lastClaim;
        uint256 nextClaim;
        uint256 pendingInterest;
        uint256 principalOut;
    }

    constructor(address pool_) {
        pool = pool_;
    }

        // This function claims funds and indicates the next payment cycle
    function claim(address investment_) external override 
        returns (
            uint256 principal_, 
            uint256 interestAdded_, 
            uint256 interestRemoved_, 
            uint256 nextPaymentDate_
        ) 
    {
        InvestmentVehicle memory investment = investments[investment_];
        
        ILoanLike loan    = ILoanLike(investment_); 
        uint256 claimable = loan.claimableFunds();

        require(claimable != 0, "SIV:F:NO_CLAIMABLE");

        nextPaymentDate_ = loan.nextPaymentDueDate();

        if (nextPaymentDate_ == 0) {
            // If the only thing missing is the last payment, just return, the accounting will be settled in exit()
            return ( 0, 0, 0, 0);
        }

        // Get next payment
        ( , uint256 nextInterest ) = loan.getNextPaymentBreakdown();
        interestAdded_ = nextInterest;

        // First, from claimable, know how much is interest and how much is principal
        principal_ = investment.principalOut - loan.principal();
        
        uint256 interest = claimable - principal_;     // TODO can this underflow (not considering refinances)? 
        interestRemoved_ = investment.pendingInterest;

        // Adjust if the amount of interest from loan is any different than what was expected
        if (interest >= investment.pendingInterest) {
            interestRemoved_ += interest - investment.pendingInterest;
        } else  {
            interestRemoved_ -= investment.pendingInterest - interest;
        }

        investments[investment_].lastClaim       = block.timestamp;
        investments[investment_].nextClaim       = nextPaymentDate_;
        investments[investment_].pendingInterest = interestAdded_;
        investments[investment_].principalOut    = loan.principal(); 

        loan.claimFunds(claimable, address(pool)); // Presumably pool is the pool
    }

    // Used to close this investment vehicle
    function closeInvestment(address investment_) external override returns (uint256 expectedPrincipal, uint256 principal_, uint256 interest_) {
        InvestmentVehicle memory investment = investments[investment_];
        
        require(msg.sender == pool,        "LIV:E:NOT_ADMIN");
        require(investment.nextClaim == 0, "LIV:F:NOT_ENDED");

        ILoanLike loan = ILoanLike(investment_); 
        uint256 claimable = loan.claimableFunds();   

        // TODO: Close accounting

        investments[investment_].pendingInterest = 0;
        investments[investment_].principalOut    = 0; 
    }

    function fund(address investment_) external override returns (uint256 interestAdded_, uint256 nextPaymentDate_) {
        require(msg.sender == pool, "LIV:F:NOT_ADMIN");

        ILoanLike loan = ILoanLike(investment_); 

        loan.fundLoan(address(this), 0);
        
        nextPaymentDate_ = loan.nextPaymentDueDate();

        ( , uint256 nextInterest ) = loan.getNextPaymentBreakdown();
        interestAdded_ += nextInterest;

        investments[investment_].lastClaim       = block.timestamp;
        investments[investment_].nextClaim       = nextPaymentDate_;
        investments[investment_].pendingInterest = interestAdded_;
        investments[investment_].principalOut    = loan.principal(); 

        // TODO: Investigate double funding/refinance implications here
    }

    /**********************/
    /*** View Functions ***/
    /**********************/

    function expectedInterest(address investment_) external view override returns (uint256 interest_) {
        InvestmentVehicle memory investment = investments[investment_];

        return investment.pendingInterest * (block.timestamp - investment.lastClaim) / (investment.nextClaim - investment.lastClaim);
    }

}
