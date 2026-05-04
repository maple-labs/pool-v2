# Top of File
All files should have a license and pragma defined in the top two lines of the file, with a line spacing:
```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;
```

# Contract Imports

1. All imports must be explicit, importing only what is necessary from each file.
2. All imports must be in order from most external to most internal in terms of file structure.
3. Imports must be grouped by hierarchy as listed above, with line spacing between groups.
4. For multiple grouped import statements, the `from` keywords must be aligned.
5. Import statements within groupings must be ordered alphabetically according to file path.
6. For multi-line imports, tab in imported contracts and use a new line for the import.
7. For multiple imports within brackets, order alphabetically by import name.
8. When dealing with a large group of imports with multiple different subdirectories, they can be grouped by subdirectory if they have more than two imports from the same subdirectory.

See a full example below:

```solidity
import {
    Address,
    console,
    InvariantTest,
    TestUtils
} from "../../modules/contract-test-utils/contracts/test.sol";

import { MockERC20 } from "../../modules/erc20/contracts/test/mocks/MockERC20.sol";

import { InvariantERC20User }     from "./accounts/ERC20User.sol";
import { InvariantOwner }         from "./accounts/Owner.sol";
import { InvariantStakerManager } from "./accounts/Staker.sol";
import { Warper }                 from "./accounts/Warper.sol";

import { MutableRDT } from "./utils/MutableRDT.sol";
```

# Interfaces
1. All contracts must have a corresponding interface with all functions and events defined with named parameters and full NatSpec documentation.
2. All public/external functions and public variables in the inheriting contract must use the `override` keyword.
3. All events must be defined in the interface.
4. Enums and structs should be defined in the contract so that there are no storage issues with proxies.

# Declarations
Declarations must be ordered in the following way (group by type + visibility):
```solidity
Enums
Structs
Libraries
Variables
---
constant
immutable
mutable
---
private
internal
public
---
Primitive fixed-size types (e.g., address, bool, etc.)
User-defined fixed-size types (e.g., MapleLoan)
Arrays
Mappings
----
Fixed length (arrays)
Least nested
Most nested
---
address
...
bool
...
uint256
...
```
1. All declarations with alike types must be grouped and aligned.
2. All declarations must be alphabetically ordered based on type then variable name.

## Example
```solidity
using SafeMath for uint256;

enum ExampleEnum { VAL1, VAL2 }

struct ExampleStruct {
    uint256 item1;
    uint256 item2;
    uint256 item3;
}

uint256 public override constant WAD = 10 ** 18;

address public override immutable mpl;

bool private isTrue;

address[] private arrayExample;

uint256 internal _internalExampleVar;

address public override globalAdmin;
address public override governor;

bool public override protocolPaused;

uint256 public override defaultGracePeriod;
uint256 public override fundingPeriod;
uint256 public override investorFee;

address[5] public override fixedArray;

address[] public override arrayExample1;
address[] public override arrayExample2;

bytes[] public override arrayExample2;

address[][] public arrayExample2;

mapping(address => address) public override oracleFor;

mapping(address => bool) public override isValidBalancerPool;
mapping(address => bool) public override isValidCollateralAsset;

mapping(address => mapping(address => address)) public override defaultUniswapPath;

mapping(address => mapping(address => bool)) public override validSubFactories;
```

# Function Ordering and Sectioning

Functions in larger contracts can be typically grouped based on general purpose into sections, for example:
```
Admin Functions
LP Functions
View Functions
Helper Functions
```

If this is the case, these sections must maintain like functionality and visibility across all functions (e.g., external/public, internal/private) a section of functions must be labelled with a large comment with the following format (136 characters long to add a 140 character total length):
```solidity
/**************************************************************************************************************************************/
/*** Internal Payment Accounting Functions                                                                                          ***/
/**************************************************************************************************************************************/
```

Multiple functions within the same section must be ordered alphabetically.

# Contract and Function Spacing

A new line must exist between each of the brackets in a contract. Code within functions must start on the first line and end on the last line, with logical spacing in between lines of code.
## Example

```solidity
contract ExampleContract is IExampleContract {

    address public override immutable variable1;

    bool public override immutable variable2;

    uint256 public override immutable variable3;
    uint256 public override immutable variable4;

    address public override variable5;
    address public override variable6;

    uint256 public override variable6;
    uint256 public override variable7;
    uint256 public override variable8;
    uint256 public override variable9;

    constructor() public {
        code;
        code;
    }

    /**************************************************************************************************************************************/
    /*** External Functions                                                                                                             ***/
    /**************************************************************************************************************************************/

    function functionName() external override {
        code;
        code;
        code;

        code;
        code;
    }

    /**************************************************************************************************************************************/
    /*** Internal Functions                                                                                                             ***/
    /**************************************************************************************************************************************/

    function functionName() internal view returns (uint256 variable1) {
        code;
        code;
        code;

        code;
        code;
    }

}

```

A single space must be used between top level declarations:
```solidity
interface interfaceName {

    code;
    ...
    code;

}

contract contractName1 {

    code;
    ...
    code;

}

```

# Function Declarations
When declaring a new function, the following approach should be used for styling:
1. If short enough, keep to one line:
```solidity
function functionName(uint256 variable1, uint256 variable2) external view returns (uint256 variable4) {
    code;
}
```

2. If one line is not possible because the line becomes too long, use multi-line with the following syntax, keeping the modifiers and return on the same line if possible:
```solidity
function functionName(
    uint256 variable1,
    uint256 variable2,
    uint256 variable3,
    uint256 variable4,
    uint256 variable5
)
    external view returns (uint256 variable4)
{
    code;
}
```

or

```solidity
function functionName(uint256 variable1)
    external view
    returns (
        uint256 variable2,
        uint256 variable3,
        uint256 variable4
    )
{
    code;
}
```

Depending on which results in less lines of code.

3. If the line with modifiers and return is too long, it can be broken into two lines, one for modifiers and one for return:
```solidity
function functionName(
    uint256 variable1,
    uint256 variable2,
    uint256 variable3,
    uint256 variable4,
    uint256 variable5
)
    external view customModifier1(variable1, variable2) customModifier2
    returns (uint256 variable4)
{
    code;
}
```

4. If the return statement is too long, it can be broken out to be multiline:
```solidity
function functionName(
    uint256 variable1,
    uint256 variable2,
    uint256 variable3,
    uint256 variable4,
    uint256 variable5
)
    external view customModifier1(variable1, variable2) customModifier2
    returns (
        uint256 variable5,
        uint256 variable6,
        uint256 variable7,
        uint256 variable8,
        uint256 variable9
    )
{
    code;
}
```

# Large Integers
Any integer value that is at least 4 figures must be represented using underscore syntax:
```
1k  => 1_000
10k => 10_000
10m => 10_000_000
10b => 10_000_000_000
etc
```

ERC-20 values that contain decimals can use scientific notation to denote decimals:
```
10,000                   (3 decimals) => 10_000e3;
10,000,000.991900        (6 decimals) => 10_000_000.9919e6;
10,000,000,000.112991100 (9 decimals) => 10_000_000_000.1129911e9;
```

# Equals Signs
1. Equals signs should always have at least a single space on either side.
2. Equals signs should always be aligned for assignments on groups of lines of code.

## Example
```solidity
function _initialize(
    address borrower_,
    address[2] memory assets_,
    uint256[3] memory termDetails_,
    uint256[3] memory amounts_,
    uint256[4] memory rates_
)
    internal
{
    // Principal requested needs to be non-zero (see `_getCollateralRequiredFor` math).
    require(amounts_[1] > uint256(0), "MLI:I:INVALID_PRINCIPAL");

    // Ending principal needs to be less than or equal to principal requested.
    require(amounts_[2] <= amounts_[1], "MLI:I:INVALID_ENDING_PRINCIPAL");

    require((_borrower = borrower_) != address(0), "MLI:I:INVALID_BORROWER");

    _collateralAsset = assets_[0];
    _fundsAsset      = assets_[1];

    _gracePeriod       = termDetails_[0];
    _paymentInterval   = termDetails_[1];
    _paymentsRemaining = termDetails_[2];

    _collateralRequired = amounts_[0];
    _principalRequested = amounts_[1];
    _endingPrincipal    = amounts_[2];

    _interestRate        = rates_[0];
    _closingRate         = rates_[1];
    _lateFeeRate         = rates_[2];
    _lateInterestPremium = rates_[3];
}
```

## Natspec
Natspec must only exist in interface files and must be aligned according to the following example:
```solidity
/**
 *  @dev    Repay all principal and fees and close a loan.
 *  @param  amount_    An amount to pull from the caller, if any.
 *  @return principal_ The portion of the amount paid paying back principal.
 *  @return interest_  The portion of the amount paid paying interest fees.
 */
function closeLoan(uint256 amount_) external returns (uint256 principal_, uint256 interest_);
```

# Function Modifiers
Function modifiers should be ordered in the following manner:
```
Visibility
Mutability
Virtual
Override
Custom modifiers
```

# Tuples
When destructuring a tuple returned from a function, use spaces between all commas and brackets. Example:
```solidity
( , , uint256 foo, uint256 bar, , uint256 baz, , , ) = functionName();
( success, ) = functionName();
```

```solidity
(
    , // Unused
    , // Unused
    uint256 foo,
    uint256 bar,
    , // Unused
    uint256 baz,
    , // Unused
    , // Unused
      // Unused
) = functionName();

( success, ) = functionName();
```

# Inline Comments
When making larger comments, make the comment above line of code, with a line break above.
If its a small comment, it can me made inline with two spaces after the semicolon.
Comments at the end of a line must be aligned with other comments made at the end of other lines within a group of lines.

# Conditional Statements
If an if statement must be used, use the following ordering in terms of preference:
1. Ternary operator syntax
2. If statement exit condition (write the if statement that returns/reverts/breaks/continues first, to minimize indentation)
3. If/else statement

# Underscore Syntax for Variables
1. Prepend underscore for internal variable: `_variableName`
2. Append underscore for all variables that are scoped to a given function: `variableName_`
3. No underscore for public storage variables: `variableName`

# Underscore Syntax for Functions
1. Prepend underscore for internal/private functions: `_functionName()`
2. No underscore for public/external functions: `functionName()`

# Memory variable Caching
If a storage variable is needed more than once, cache it to memory.

# Types in function signatures (arguments and returns)
Only use primitive types for arguments and return statements (never use interface or contract types). Structs can be used as parameters in private and/or internal functions.

# Array Assignment
When initializing and assigning to arrays, include a newline between the initialization and assignments, and align the assignments.

```solidity
uint256[] memory myArray = new uint256[](4);

myArray[0] = 0;
myArray[1] = 1;
myArray[2] = 2;
myArray[3] = 3;
```
