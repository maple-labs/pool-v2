// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.7;

import { IRevenueDistributionToken } from "../../modules/revenue-distribution-token/contracts/interfaces/IRevenueDistributionToken.sol";

interface IPoolV2 is IRevenueDistributionToken { 

    // TODO natspec
    function claim(address investment_) external;

    function fund(uint256 amountOut_, address investment_) external returns (uint256 issuanceRate_);
    
    function interestOut() external view returns (uint256 interest_);
    
    function principalOut() external view returns (uint256 principal_);
    
    function setInvestmentManager(address investmentManager_) external;

}
