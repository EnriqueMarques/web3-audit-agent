# Pattern: V4 hook callback missing `onlyPoolManager` (access-control by custody)

**Family:** access control / privileged callback (Uniswap V4 hooks)
**References:** the Cork Protocol incident (2025-05-28, ~$12M). The *severity by custody* rule is the same as in [[flashloan-arbitrary-call]] and [[severity-gate-funds-at-risk]].
**Severity when present:** **DEPENDS ON CUSTODY** — Critical if the hook custodies TVL/collateral/redeemable claims; LOW/MED if the callback is stateless / moves no funds. NOT Critical automatic.
**Detection by Slither/Aderyn:** NO (they don't know `msg.sender` should be the PoolManager for a hook callback)
**Solodit tags:** uniswap-v4, hooks, access-control, missing-modifier, severity-by-custody

---

## Core mechanism

A V4 hook is called by the PoolManager at lifecycle points (`beforeSwap`, `afterSwap`, `before/afterAddLiquidity`, `before/afterDonate`, …). The hook author often assumes "this callback only ever runs *inside* a swap/liquidity op initiated through the PoolManager", and trusts the `sender` / `hookData` arguments accordingly — using them to mint derivatives, release collateral, credit balances, or gate privileged state.

That assumption holds **only if the callback is guarded by `onlyPoolManager`**. The guard is one line:

```solidity
// v4-periphery/src/base/ImmutableState.sol:17-18  (BaseHook applies it to EVERY callback)
modifier onlyPoolManager() {
    if (msg.sender != address(poolManager)) revert NotPoolManager();
    _;
}
```

Remove it (or hand-roll a hook that doesn't extend `BaseHook` and forget it) and the callback is just a **public function**. Anyone calls it directly, choosing `sender` and `hookData` freely — forging the privileged action with no swap, no manager, no flash-accounting settlement.

## Cork Protocol (the canonical real incident, ~$12M, 2025-05-28)

Root cause (Dedaub + cork.tech post-mortem): `CorkHook.beforeSwap` had **no `onlyPoolManager`**. The attacker called it directly with crafted `hookData`, forcing an unauthorized "CorkCall" that minted redeemable derivative tokens (DS/CT) backed by real wstETH deposits → drained ~$12M. The hook **custodied the backing** → Critical.

## Minimal vulnerable pattern

```solidity
// VULNERABLE — no onlyPoolManager; trusts it's only called by the manager
function beforeSwap(address sender, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
    external returns (bytes4, BeforeSwapDelta, uint24)
{
    (address recipient, uint256 amount) = abi.decode(hookData, (address, uint256));
    backing.transfer(recipient, amount);          // ← privileged release, forgeable
    return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
}
```
Attacker: `hook.beforeSwap(attacker, key, params, abi.encode(attacker, allReserves))` → walks away with the custodied reserve. In a Foundry PoC the vulnerable hook loses its full 1e24 custodied TVL; the fixed version reverts with `NotPoolManager`.

## Severity by custody (hooks into the gate)

Same structure as [[flashloan-arbitrary-call]]: the mechanism (forging a privileged action) may always be present, but severity is gated by **what the hook custodies in NORMAL operation**:

| Case | What the forged callback custodies | Severity |
|---|---|---|
| Cork `beforeSwap` | wstETH backing + mint of redeemable derivatives (real TVL) | **Critical** |
| Stateless hook (only returns a delta/selector, moves no funds) | nothing | **LOW/QA** (misconfiguration, not a drain) |
| Hook that only emits an event / updates a non-economic accumulator | non-custodial state | **LOW/MED** |

Rule: `callback without onlyPoolManager` + `the hook custodies TVL/collateral/redeemable claims in the normal flow` → **Critical**. If the callback moves no funds and mints no claims → ceiling of LOW/MED. Pass [[severity-gate-funds-at-risk]] BEFORE labeling anything Critical (this is the side that CONFIRMS Critical when there really is custody).

## Required conditions

1. A hook callback performs a **state-changing privileged action** (mint, transfer, credit, role/flag set) using `sender` or `hookData`.
2. The callback lacks `onlyPoolManager` (or any `msg.sender == poolManager` check).
3. The hook holds/controls value (or authority over value) reachable by that action **in normal operation**.

## Detection heuristic

For every hook in scope, grep each external callback for the guard:
```
beforeSwap|afterSwap|beforeInitialize|afterInitialize|beforeAddLiquidity|afterAddLiquidity|beforeRemoveLiquidity|afterRemoveLiquidity|beforeDonate|afterDonate
```
For each: is there `onlyPoolManager` / `msg.sender != address(poolManager) ... revert`? **Absence on a stateful, fund-touching callback = immediate Critical candidate** (then run the custody gate).
- Hooks that **don't** extend `BaseHook` are the high-risk set — `BaseHook` bakes the guard into every callback (`BaseHook.sol:144-150`, …); hand-rolled `IHooks` implementers are where it goes missing.
- Also check helper/admin functions the callback calls: the guard on `beforeSwap` is moot if it delegates to a public `_doCorkCall()`.

## Cross-reference

- [[severity-gate-funds-at-risk]] — the by-custody gate (this pattern is the CONFIRM-Critical side).
- [[flashloan-arbitrary-call]] — identical by-custody severity structure (impersonation drainable ⇔ what's custodied).
- [[hook-permission-address-bits-mismatch]] — the *other* hook access-control failure (permission bits vs implementation).
- Target notes: `knowledge/target-notes/uniswap-v4-hooks.md` §5 (the guard) + §7 (#4).
- Loci @ pin 59d3ecf / periphery 3779387: `ImmutableState.sol:14,17-18`; `BaseHook.sol:144-150`.
