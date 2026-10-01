# PoC Foundry Template

Base template for building reproducible PoCs. Copy it to `findings/<slug>/pocs/H<N>-<name>/` every time you build a new PoC.

## Structure

```
poc/
├── README.md           # Setup and expected results
├── foundry.toml
├── remappings.txt
├── src/                # If you need to copy contracts from the target
├── test/
│   └── Exploit.t.sol   # The exploit test
└── trace.txt           # forge test -vvvv output (after running)
```

## Base foundry.toml

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200
fs_permissions = [{ access = "read", path = "./" }]
ffi = false
verbosity = 3

[fuzz]
runs = 256

[invariant]
runs = 64
depth = 32
fail_on_revert = false

[rpc_endpoints]
mainnet = "${MAINNET_RPC}"
arbitrum = "${ARBITRUM_RPC}"
optimism = "${OPTIMISM_RPC}"
base = "${BASE_RPC}"
polygon = "${POLYGON_RPC}"
```

## Exploit.t.sol template

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface ITargetContract {
    // Define the vulnerable contract's interface
    function vulnerableFunction(uint256) external;
}

contract ExploitTest is Test {
    // Constants
    uint256 constant FORK_BLOCK = 19_500_000;  // Pin the block for reproducibility

    // Actors
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address whale = 0x...;  // If you need to borrow balances from a whale

    // Targets (mainnet addresses if you use a fork)
    ITargetContract target;
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    function setUp() public {
        // Option A: fresh deployment
        // target = new TargetContract(/* params */);

        // Option B: mainnet fork
        vm.createSelectFork(vm.envString("MAINNET_RPC"), FORK_BLOCK);
        target = ITargetContract(0x...);

        // Fund actors
        deal(address(usdc), attacker, 10_000e6);
        deal(address(usdc), victim, 10_000e6);

        vm.label(attacker, "Attacker");
        vm.label(victim, "Victim");
        vm.label(address(target), "Target");
    }

    function test_exploit() public {
        console2.log("==================================================");
        console2.log("EXPLOIT START");
        console2.log("==================================================");

        _logBalances("INITIAL");

        // === Step 1 ===
        vm.startPrank(attacker);
        // ... attack actions
        vm.stopPrank();

        _logBalances("AFTER STEP 1");

        // === Step 2 ===
        // ...

        _logBalances("FINAL");

        // === Assertions ===
        uint256 attackerProfit = usdc.balanceOf(attacker) - 10_000e6;
        console2.log("Attacker profit (USDC):", attackerProfit / 1e6);
        assertGt(attackerProfit, 0, "Exploit failed: no profit");
    }

    function _logBalances(string memory label) internal view {
        console2.log("--- %s ---", label);
        console2.log("Attacker USDC:", usdc.balanceOf(attacker));
        console2.log("Victim USDC:", usdc.balanceOf(victim));
        console2.log("Target USDC:", usdc.balanceOf(address(target)));
    }
}
```

## When to fork vs when to deploy fresh

**Use a fork when:**
- The bug depends on specific mainnet state (prices, balances, configuration).
- The target is already deployed and you want to demonstrate the exploit under real conditions.
- You want to use real liquidity from Aave/Curve/Uniswap.

**Use a fresh deploy when:**
- The bug is in a contract that is not deployed yet (codebase audit).
- You want to isolate variables (controlled state).
- The bug is independent of mainnet state.

## When to use invariant testing vs a unit test

**Unit test (test_exploit):** When you already know the exact attack. It demonstrates the specific path.

**Invariant test:** When you suspect something is wrong but don't know exactly what. Foundry finds the sequence for you.

```solidity
contract Handler is Test {
    Vault public vault;
    address[] public actors;

    constructor(Vault _vault) {
        vault = _vault;
        actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("eve")];
    }

    function deposit(uint256 actorIdx, uint256 amount) external {
        address actor = actors[actorIdx % actors.length];
        amount = bound(amount, 0, 1e30);
        vm.startPrank(actor);
        deal(address(token), actor, amount);
        token.approve(address(vault), amount);
        try vault.deposit(amount, actor) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorIdx, uint256 shares) external {
        address actor = actors[actorIdx % actors.length];
        shares = bound(shares, 0, vault.balanceOf(actor));
        vm.startPrank(actor);
        try vault.redeem(shares, actor, actor) {} catch {}
        vm.stopPrank();
    }
}

contract VaultInvariantTest is Test {
    Vault vault;
    Handler handler;

    function setUp() public {
        vault = new Vault();
        handler = new Handler(vault);
        targetContract(address(handler));
    }

    function invariant_solvency() public {
        // The vault must hold at least the assets backing the issued shares
        assertLe(vault.totalSupply() * vault.pricePerShare(), vault.totalAssets() * 1e18);
    }
}
```

```bash
forge test --match-contract VaultInvariantTest --invariant-runs 1000 --invariant-depth 100
```

If an invariant fails, Foundry prints the reproducible sequence.

## When to use Halmos vs Foundry

Halmos for arithmetic properties / small input spaces / formal proofs:

```solidity
function check_no_free_money(uint256 amount) public {
    vm.assume(amount > 0 && amount < type(uint128).max);
    address user = address(0xBEEF);

    deal(address(token), user, amount);
    vm.startPrank(user);
    token.approve(address(vault), amount);
    uint256 shares = vault.deposit(amount, user);
    uint256 redeemed = vault.redeem(shares, user, user);
    vm.stopPrank();

    assert(redeemed <= amount);
}
```

```bash
halmos --function check_no_free_money --solver-timeout-assertion 60000
```

Halmos proves it for ALL symbolic inputs. If it finds a counterexample, it gives you the exact values.
