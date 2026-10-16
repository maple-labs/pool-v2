# Naming

Tests should be prefixed with `test_` and fuzz tests must be prefixed with `testFuzz_`. The name of the function should be the second part of the test function's name. If there are any unique conditions being tested, they should be described succinctly and explicitly as the 3rd part of the test function's name (i.e. `test_functionName_description`, e.g., `test_foo_notAuthorized`).

# Declarations

Variable declarations in tests should never declare visibility since it is unnecessary.
Constants in this example refer not to `constant` keyword declarations, but rather variables that are declared above teh `setUp` and are treated as constants for the entirety of the test suite.

"Constants" (can be assigned at compile time) can be used for actors and values that will remain constant over the course of a test suite, denoted using `CAPITAL_SYNTAX`.

Constant numerical values should **never** be used in base test contracts that are intended to be extended. Constant addresses for actors are permitted in this situation.

Examples:
- Actors (e.g., `GOVERNOR`)
- Small, highly used variables for unit testing (e.g., `DEPOSIT_AMOUNT`)

```solidity

contract TestBase {

    address GOVERNOR = address(new Address());

    Pool pool;

    function setUp public virtual {
        pool = new Pool();
    }
}

contract PoolTest is TestBase {

    address LP = address(new Address());

    uint256 DEPOSIT_AMOUNT = 100;

    function setUp() public override {
        asset.mint(LP, DEPOSIT_AMOUNT);
    }

    test_deposit_success() external {
        assert...
        vm.prank(LP);
        pool.deposit(DEPOSIT_AMOUNT);
        assert...
    }

}
```

# Fuzzing (Revisit)

Prioritize a single fuzzing test that can reasonable test all possible transitions from random starting points, assuming the outcomes can be trivially checked without reimplementing the function itself.

Addresses do not need to be fuzzed (REVISIT, investigate `vm.assume`).

Unreasonable/infeasible fuzz tests include:
- Test outcome depends on a very specific value of an argument (specific address or specific signature)
- Dynamic output is impossible to verify exactly without the very math/logic being tested
- State of dependencies are unforeseeable or difficult to plan for

# Unit Tests

Tests should be grouped within test contracts such that they all rely on the same setup function, or no setup function. It is important that all lines of code in the setup function be required for each test, to prevent setup bloat, and to prevent the need to undo or modify setup parameters in a test. Further, tests should not contains lines or operations unnecessary to what is being tested (often the result of copy-pasting tests as a starting point).

Create test(s) for successful outcomes, then individual tests for each failure mode. Tests should only assert what was intended to be tested, and identical happy paths should be avoided.

For setter functions, failure modes and success path tests can be contained within the same test contract, as long as the contract name is appended with `_SetterTests`.

For all other tests, there should be a dedicated test contract for failure and one for seuccess for each function.

(REVISIT BELOW)

If a feasible fuzz tests cannot properly validate outcomes, then tests those specific outcomes with known fixtures.

For example, the following would e for a function `foo` that would succeed if called by the owner, with `y` less than `x`, if the contract is not ended, resulting in only a return, an update to `baz`, and some testable arbitrary invariants:

```solidity
    Foo foo;

    function setUp() external {
        foo = new Foo(address(this));
    }

    function testFuzz_bar(uint255 x_, uint256 y_) external {
        y_ = constrictToRange(y_, 0, x_);

        uint256 value = foo.bar(x_, y_);

        assertTrue(value < x_ && value < y_);
        assertTrue(testInvariants(foo));

        assert(foo.baz() == x_);
    }

    function testFuzz_bar_fixture1() external {
        uint256 value = foo.bar(2, 1);

        assertTrue(testInvariants(foo));

        assert(value, 0);
        assert(foo.baz() == 2);
    }

    function testFuzz_bar_fixture2() external {
        uint256 value = foo.bar(13, 3);

        assertTrue(testInvariants(foo));

        assert(value, 1);
        assert(foo.baz() == 13);
    }

    function testFuzz_bar_fixture3() external {
        uint256 value = foo.bar(1324, 100);

        assertTrue(testInvariants(foo));

        assert(value, 19);
        assert(foo.baz() == 1324);
    }

    function test_bar_notOwner() external {
        vm.startPrank(address(1234));
        vm.expectRevert(bytes("UNAUTHORIZED"));
        foo.bar(0, 0);
    }

    function test_bar_xSmallerThanY(uint255 x_, uint256 y_) external {
        x_ = constrictToRange(x_, 0, y_);

        vm.expectRevert(bytes("X_SMALLER_THAN_Y"));
        foo.bar(x_, y_);
    }

    function test_bar_alreadyEnded() external {
        foo.end();
        vm.expectRevert(bytes("ALREADY_ENDED"));
        foo.bar(0, 0);
    }
```

Finally, avoid testing that the solidity compiler works, that the EVM works, or that state changes in unrelated contracts occurred. For example, don't test:
- That different optimizer values still result in passing tests
- That state has not changed after a revert
- That a contract was deployed after explicitly calling `new` successfully in a test or set up
- That the balance or allowance of an ERC20 decreased after a successful transfer, if the ERC20 is mocked, 3rd party, or itself tested elsewhere

# Testing initial states (constructors) (REVISIT)

Testing initial states of contracts should be done as separate unit test (ideally fuzzed), and not as tests at the beginning of another test intended to test the outcome of some function. Further, unit tests should thus not test the initial state of variables, but only that a function succeeds or fails, and the returned variables and/or resulting state. If one notices a need to test an initial state, it indicates that another test should be created for that specific set of assertions.

# Setups

Setups should be minimal and sufficient for the tests that are dependant on it. Bloated setups are an indicator that the dependant unit tests should be split into different test contracts. If several test contracts have some repeated steps in their set up functions, consider an inheritable contract/function that performs much of the setup, with as many arguments as needed, and remains as pure as possible (i.e. accepts an instance as an argument and/or returns the required instances created).

# Invariants

Within the `test` directory, an `invariants` directory can exist, which can contain files, either generically/globally named (i.e. `Invariants.sol`), or `FooInvariants.sol`. These contracts should contains a single function `_checkInvariants` which returns a boolean and an array of booleans indicating if all invariants hold true and if each invariant holds true, respectively. The function should never revert (unless the tested instance is invalid) For example:

```solidity

function checkInvariants(address instance_) public returns (bool allHold_, bool[] memory holds_) {
    ...
}
```

Such invariant checking contracts would be useful when inherited by unit testing contracts, integration testing contracts, simulation contracts, and testnet/mainnet monitoring contracts.

# Harnesses

Contracts with many internal functions can be great for being able to isolate and test specific logic/math (especially to get around ), but require harnesses to expose them, which are to be located in the `test/harnesses` directory:

```solidity
contract  Foo {
    uint256 z_;

    ...

    function bar(uint256 x_, uint256 y_) external returns (uint256 result_) {
        ...
        result_ = _baz(x_, y_, z_);
        ...
    }

    function _baz(uint256 x_, uint256 y_, uint256 z_) internal returns (uint256 result_) {
        result_ = (x_ * y_) % z;
    }
}

contract FooHarness is Foo {
    function baz(uint256 x_, uint256 y_, uint256 z_) external returns (uint256 result_) {
        result_ = _bar(x_, y_, z_);
    }
}
```

# Mocks

Mocks required as dependencies for functions/instances being tested should implement the minimal logic for tests to proceed. **Specifically, if a tests depends on a mock returning a dynamic variable, the mock should be setup or forced to return a chosen variable, not compute it.** Also, avoid constructors as they often result in set up functions with mocks constructed with arbitrary and unnecessary constructor arguments. For example:

```solidity
contact MockFoo {

    address public owner;

    bool public isPaused;

    uint256 public rate;

    mapping(address => address) internal oracle;

    bool internal isSufficient;

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function setIsPaused(bool isPaused_) external {
        isPaused = isPaused_;
    }

    function setRate(address rate_) external {
        rate = rate_;
    }

    function setOracle(address asset_, address oracle_) external {
        oracle[asset_] = oracle_;
    }

    function getOracle(address asset_) external returns (address oracle_) {
        return oracle[asset_];
    }

    function setIsSufficientDeposit(bool isSufficient_) external {
        isSufficient = isSufficient_;
    }

    // Note how this is even more simple to force/mock than a isSufficient[asset_][user_][amount_] mapping;
    function isSufficientDeposit(address asset_, address user_, uint256 amount_) returns (bool isSufficient_) {
        isSufficient_ = isSufficient;
    }

}
```

## Test Assertions

For assertions of the same type, the parameters must be aligned so that the second set of parameters is left justified, and the inline comments (if any exist) are aligned to be two spaces from the longest line. Example shown below:
```solidity
assertEq(mockToken.balanceOf(address(treasury)), 0);    // Withdraws all funds
assertEq(mockToken.balanceOf(address(mpl)),      100);  // Withdrawn to MPL address, where accounts can claim funds
assertEq(mockToken.balanceOf(address(holder1)),  0);    // Token holder hasn't claimed
assertEq(mockToken.balanceOf(address(holder2)),  0);    // Token holder hasn't claimed
```

Another example of this:
```solidity
assertEq(token.fundsBalance(),   60_000);
assertEq(token.pointsPerShare(), expectedPointsPerShare);
```

When asserting a failure condition, align the `assertTrue` functions so that the function names are aligned. Example shown below:
```solidity
assertTrue(!notGov.try_treasury_distributeToHolders(address(treasury)));  // Non-governor can't distribute
assertTrue(    gov.try_treasury_distributeToHolders(address(treasury)));  // Governor can distribute
```

Every single state variable that changes as a result of a function call MUST have both before and after assertions. If there are variables that important to highlight that their state has NOT changed, they can be added to before/after assertions with an inline comment `// Not changed`.

# Test Helpers
Reduce duplication of code (both setup, operations, and assertions) by creating internal functional helpers that accept interfaces as arguments. Doing this early on, when duplication is first detected, is a great and easy way to reduce the tedious effort required later refactor large duplication of code. Keep this helper functions very specific, as bloated ones could themselves cause tediousness in writing new tests.

Investigate writing libraries for user-specific functionality to enable a more functional approach, while preventing potential stack overflow errors.
