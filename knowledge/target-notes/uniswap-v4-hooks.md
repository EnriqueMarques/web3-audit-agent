# Target Notes — Uniswap V4 hooks (core + periphery)

**Scope:** line-by-line reading of the hook surface (core + periphery).
**Pin:**
- v4-core @ `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (`v4.0.0-12-g59d3ecf5`, 2025-05-13)
- v4-periphery @ `3779387e5d296f39df543d23524b050f89a62917` (2025-11-05); submodule `lib/v4-core` == 59d3ecf (zero drift).
- solc 0.8.26, evm cancun, via_ir. All `file:line` citations below are at this pin.
**Sources read (blindness OFF):** the contracts below + on-disk audits (OZ/ToB/Spearbit core) + `docs/security/Known_Effects_of_Hook_Permissions.pdf`.

---

## 0. Mental model (the two things that make V4 different)

### 0.1 Flash accounting via transient `unlock`
There is ONE singleton `PoolManager` holding all pools' funds. You cannot call `swap`/`modifyLiquidity`/`donate`/`take`/`settle`/`mint`/`burn` directly — they are gated by `onlyWhenUnlocked` (`PoolManager.sol:96`). To act you call `unlock(data)` (`PoolManager.sol:104`), which:
1. sets the transient `IS_UNLOCKED` flag (`Lock.unlock()`),
2. calls back `IUnlockCallback(msg.sender).unlockCallback(data)` (`PoolManager.sol:110`) — you do everything here,
3. **requires `NonzeroDeltaCount.read() == 0` before returning** (`PoolManager.sol:112`), else `CurrencyNotSettled`,
4. re-locks.

So the whole interaction is one re-entrant callback during which the manager tracks per-(account,currency) **deltas** in transient storage, and the only hard invariant at the end is **every delta nets to zero**.

### 0.2 Delta sign convention (memorize — most reasoning hinges on it)
A delta is owed *between an account and the manager*:
- **delta > 0 ⇒ account is OWED currency (credit).** It can be realized via `take` / `mint` / `clear`.
- **delta < 0 ⇒ account OWES currency (debt).** It must be cleared via `settle` / `burn`.
- `take(cur,to,amt)` does `_accountDelta(cur, -amt, msg.sender)` then transfers out (`PoolManager.sol:294-295`) → taking makes you more negative (you owe).
- `settle` credits `_accountDelta(cur, +paid, recipient)` (`PoolManager.sol:364`) → paying in makes you more positive.
- IHooks NatSpec restates this for hook deltas: "Positive: the hook is owed/took currency; negative: the hook owes/sent currency" (`IHooks.sol:54,85,101,114`).

`NonzeroDeltaCount` is just a counter so the manager can cheaply check "are there any unsettled deltas?" without iterating (`_accountDelta` inc/dec it on zero-crossings, `PoolManager.sol:373-377`).

---

## 1. PoolManager — entry, lock, flash accounting

### 1.1 unlock / lock / onlyWhenUnlocked
- `onlyWhenUnlocked` (`PoolManager.sol:96-99`): `if (!Lock.isUnlocked()) revert ManagerLocked`.
- `unlock` (`:104-114`): `AlreadyUnlocked` guard (no nesting of unlock), `Lock.unlock()`, callback, **`NonzeroDeltaCount.read()!=0 ⇒ CurrencyNotSettled`**, `Lock.lock()`.
- `Lock` (`Lock.sol`): single transient bool slot `IS_UNLOCKED_SLOT` (`:8`). unlock/lock/isUnlocked are tstore/tload (`:10-27`).
- **Invariants assumed:** (a) exactly one unlock frame at a time (no re-unlock); (b) all deltas zero at frame end; (c) `initialize`/`sync`/`updateDynamicLPFee` are NOT `onlyWhenUnlocked` — they can run outside a lock because they don't move user funds out (initialize sets pool state; sync reads balances; updateDynamicLPFee is hook-only).
- **Subtle:** `unlock` is the ONLY re-entrancy door, and it is fully re-entrant *by design* (your callback can do anything). The protection is not "no re-entrancy", it is "deltas must net to zero" + per-function `noDelegateCall`. Anything that can leave a nonzero delta that someone else later inherits, or zero a delta without paying, is the bug shape here.

### 1.2 Flash-accounting libraries
- `CurrencyDelta` (`CurrencyDelta.sol`): transient map. `_computeSlot = keccak256(target ++ currency)` (`:10-16`); `getDelta` tload (`:18`); `applyDelta` reads prev, `next = previous + delta`, tstore (`:28-41`). int128 delta added into an int256 transient slot — no realistic overflow.
- `NonzeroDeltaCount` (`NonzeroDeltaCount.sol`): transient counter. `decrement` can underflow (explicit warning `:26-27`); current usage matches inc/dec via `_accountDelta` zero-crossings so it stays balanced; an underflow would wrap to a huge value ⇒ `unlock` reverts (fail-safe direction).
- `CurrencyReserves` (`CurrencyReserves.sol`): two transient slots — synced `CURRENCY_SLOT` and `RESERVES_OF_SLOT`. `syncCurrencyAndReserves` sets both (`:27`), `resetCurrency` zeroes the currency slot (`:21`). Drives the sync→settle ERC-20 measurement.
- `_accountDelta` (`PoolManager.sol:368-378`): no-op if delta==0; `applyDelta`; if next==0 decrement count, else if previous==0 increment. `_accountPoolBalanceDelta` (`:381-384`) splits a `BalanceDelta` into currency0/currency1 calls.

### 1.3 Settlement primitives (where delta-accounting bugs live)
- `take(cur,to,amt)` (`:291-297`): `_accountDelta(-amt, msg.sender)` then `cur.transfer(to,amt)`. Realize a credit (or go into debt) and pull tokens out.
- `settle()` / `settleFor(recipient)` (`:300-307`) → `_settle` (`:349-365`):
  - reads `getSyncedCurrency()`. If `isAddressZero()` (native sentinel) ⇒ **`paid = msg.value`** (`:353-354`).
  - else ⇒ require `msg.value==0`, **`paid = balanceOfSelf() - reservesBefore`** (`:358-360`), `resetCurrency()`.
  - `_accountDelta(currency, +paid, recipient)` (`:364`).
  - Comment `:348`: "if settling native, integrators should still call `sync` first to avoid DoS attack vectors."
- `sync(cur)` (`:279-288`): native ⇒ `resetCurrency()` (no reserves needed); ERC-20 ⇒ `syncCurrencyAndReserves(cur, balanceOfSelf())`. The "measure-before, transfer, settle-measures-after" pattern for fee-on-transfer safety.
- `clear(cur,amt)` (`:310-319`): burns an *exact positive* delta without taking tokens (`amountDelta != current ⇒ MustClearExactPositiveDelta`). Used to abandon dust credit.
- `mint`/`burn` (`:322-336`): ERC-6909 claims. mint ⇒ `_accountDelta(-amt)` + `_mint` (you take a claim, you owe). burn ⇒ `_accountDelta(+amt)` + `_burnFrom` (you give a claim, you're credited).
- **Invariant assumed:** one physical token movement maps to exactly one delta change. **The native dual-token break (OZ C-01):** on chains where the gas token ALSO has an ERC-20 representation (CELO, MATIC, zkSync ETH), one physical transfer increments BOTH measurements — `msg.value` (native path) and `balanceOfSelf` delta (ERC-20 path) — so the same coins can be settled twice, crediting two deltas for one payment. The locus is `_settle` native vs ERC-20 branches (`:353-361`) + `sync` (`:279-288`).

### 1.4 Hook call-sites & ordering (callback ↔ pool-state)
- `initialize` (`:117-142`, `noDelegateCall`, NOT onlyWhenUnlocked): validates tickSpacing, `currency0 < currency1`, **`isValidHookAddress(key.fee)`** (`:126`) → `beforeInitialize` (`:130`) → `_pools[id].initialize` (`:134`) → emit (`:139`) → `afterInitialize` (`:141`). Event before afterInitialize so events stay ordered.
- `modifyLiquidity` (`:145-184`): `beforeModifyLiquidity` (`:156`) → `pool.modifyLiquidity` (`:159`) → `callerDelta = principalDelta + feesAccrued` (`:171`) → emit (`:175`) → **`afterModifyLiquidity` returns `(callerDelta, hookDelta)`** (`:178`) → if `hookDelta!=0` account it to the hook (`:181`) → account `callerDelta` to msg.sender (`:183`). **The after-hook can mutate the caller's delta** (it subtracts its own hookDelta from callerDelta inside `Hooks.afterModifyLiquidity`).
- `swap` (`:187-227`): `amountSpecified!=0` guard (`:193`) → **`beforeSwap` returns `(amountToSwap, beforeSwapDelta, lpFeeOverride)`** (`:202`) → `_swap` with the *hook-adjusted* amount and fee (`:206`) → **`afterSwap` returns `(swapDelta, hookDelta)`** (`:221`) → hookDelta to hook (`:224`), swapDelta to msg.sender (`:226`). `_swap` (`:230-253`) runs the pool curve, takes protocol fee on the input currency (`:238`).
- `donate` (`:256-276`): `beforeDonate` (`:266`) → `pool.donate` (`:268`) → account delta to msg.sender (`:270`) → emit → `afterDonate` (`:275`).
- **Ordering subtlety:** before-hooks run BEFORE the state mutation and can change inputs (swap amount, fee) or revert; after-hooks run AFTER and can change the caller's resulting delta or revert. A revert in `beforeRemoveLiquidity`/`afterRemoveLiquidity` can permanently lock LP funds + fees (per `Known_Effects` doc).

---

## 2. Delta types (packing & sign)

- `BalanceDelta` (`BalanceDelta.sol`): `int256` with **upper 128 = amount0, lower 128 = amount1** (`:6-8`). `toBalanceDelta` packs via `or(shl(128,a0), a1 & lowerMask)` (`:14-18`). Extraction: `amount0 = sar(128,·)` (signed shift, `:61-65`), `amount1 = signextend(15,·)` (sign-extend from bit 127, `:67-71`). `add`/`sub` are componentwise with `SafeCast.toInt128` overflow checks (`:20-46`).
- `BeforeSwapDelta` (`BeforeSwapDelta.sol`): same packing but **upper 128 = deltaSpecified, lower 128 = deltaUnspecified** (`:4-6`). `getSpecifiedDelta = sar(128,·)` (`:25`), `getUnspecifiedDelta = signextend(15,·)` (`:33`).
- **Subtle:** both halves are independent signed int128. "specified" vs "unspecified" is relative to the swap's `amountSpecified` token, NOT to currency0/1 — the mapping to currency0/1 happens later in `Hooks.afterSwap` (see §4.3) and depends on swap direction & exactIn/out. Getting that mapping wrong is a classic sign bug.

---

## 3. Hooks library — permission bitmap & address validation

### 3.1 The 14-flag bitmap (lives in the hook's ADDRESS low bits)
`Hooks.sol:27-47`. From MSB(13) to LSB(0):
`BEFORE_INITIALIZE(13) AFTER_INITIALIZE(12) BEFORE_ADD_LIQ(11) AFTER_ADD_LIQ(10) BEFORE_REMOVE_LIQ(9) AFTER_REMOVE_LIQ(8) BEFORE_SWAP(7) AFTER_SWAP(6) BEFORE_DONATE(5) AFTER_DONATE(4) BEFORE_SWAP_RETURNS_DELTA(3) AFTER_SWAP_RETURNS_DELTA(2) AFTER_ADD_LIQ_RETURNS_DELTA(1) AFTER_REMOVE_LIQ_RETURNS_DELTA(0)`.
`ALL_HOOK_MASK = (1<<14)-1` (`:27`). `hasPermission(self,flag) = uint160(addr) & flag != 0` (`:337-339`).
- **Invariant:** permissions are IMMUTABLE and read straight from the deployed address. No setter, no storage. To get a permission, the contract must be deployed at an address whose corresponding low bit is 1 (mined via `HookMiner`/CREATE2).

### 3.2 isValidHookAddress (called by PoolManager.initialize)
`Hooks.sol:109-127`:
- Four "RETURNS_DELTA requires the base action flag" checks (`:111-120`): you cannot have `*_RETURNS_DELTA` without the matching `BEFORE_SWAP/AFTER_SWAP/AFTER_ADD_LIQ/AFTER_REMOVE_LIQ` flag.
- Final validity (`:124-126`): address(0) ⇒ fee must NOT be dynamic; non-zero address ⇒ must have ≥1 flag bit OR a dynamic fee.
- **Subtle:** a hook with ZERO flag bits is valid *only* on a dynamic-fee pool (so it can call `updateDynamicLPFee`). This is the cheap "fee manager only" hook shape.

### 3.3 validateHookPermissions (used in hook constructors, e.g. BaseHook)
`Hooks.sol:83-103`: reverts `HookAddressNotValid` unless EVERY one of the 14 declared `Permissions` booleans `==` the address bit. This is a self-check the hook performs at deploy; PoolManager itself only calls `isValidHookAddress`.
- **Gap worth noting:** `isValidHookAddress` (what the manager enforces) is WEAKER than `validateHookPermissions` (what BaseHook self-enforces). The manager only checks the returns-delta-implies-base rule + "≥1 flag or dynamic". It does NOT check that the address bits match what the hook *implements*. A hook deployed at an address with a flag bit set but no real implementation just gets its (reverting/empty) function called; a hook missing a flag bit it "wanted" simply never gets that callback. Mismatch = silent mis-wiring, caught only if the hook uses `validateHookPermissions`.

### 3.4 callHook / return-data handling (return-data bug class)
- `callHook` (`Hooks.sol:131-155`): raw `call(gas(), self, 0, data...)` (`:134`); on failure `CustomRevert.bubbleUpAndRevertWith` (`:137`); then **manually copies the full `returndatasize()` into a fresh memory array** (`:140-149`); requires `result.length>=32 && result.parseSelector()==data.parseSelector()` (`:152`) — the hook MUST echo back the selector it was called with.
- `callHookWithReturnDelta(self,data,parseReturn)` (`:159-168`): if `parseReturn` requires **exactly 64 bytes** (selector + 32-byte delta, `:166`) then `parseReturnDelta`.
- `ParseBytes` (`ParseBytes.sol`): `parseSelector = mload(result+0x20)` (`:9`), `parseReturnDelta = mload(result+0x40)` (`:23`), `parseFee = mload(result+0x60)` (`:16`) — blind fixed-offset mloads, gated by the length checks above.
- `bubbleUpAndRevertWith` (`CustomRevert.sol:83-119`): copies the entire hook revert payload via `returndatacopy(...,returndatasize())` (`:109`) and re-reverts wrapped in ERC-7751 `WrappedError`. **Explicit note `:82`: "this method can be vulnerable to revert data bombs."** → OZ M-01 / returndata-bomb class. Accepted risk (the hook is chosen per-pool).
- **noSelfCall** (`Hooks.sol:171-175`): the before/after wrappers skip the hook call when `msg.sender == address(self)` — prevents a hook from re-triggering its own callbacks when it initiates the action (the self-reentrancy guard ToB verified). For the delta-returning wrappers the same check is inline (`:217, :253, :293`).

### 3.5 IHooks interface
`IHooks.sol`: 10 callbacks. Return shapes: plain `bytes4` (initialize/donate/before-liq); `(bytes4, BalanceDelta)` (afterAdd/afterRemoveLiquidity); `(bytes4, BeforeSwapDelta, uint24)` (beforeSwap — selector + delta + lpFee override); `(bytes4, int128)` (afterSwap — selector + unspecified delta). lpFee override only applies if dynamic fee + override bit `0x400000` set + ≤ max fee (`:102`).

---

## 4. beforeSwap / afterSwap delta mechanics (custom accounting — the heart of #6)

### 4.1 beforeSwap (`Hooks.sol:248-282`)
- `amountToSwap = params.amountSpecified` (`:252`); self-call short-circuit (`:253`).
- `callHook`; require `result.length==96` (`:259`); if dynamic fee `lpFeeOverride = parseFee` (`:263`).
- if `BEFORE_SWAP_RETURNS_DELTA_FLAG`: `hookReturn = parseReturnDelta`; `hookDeltaSpecified = getSpecifiedDelta` (`:266-270`); if nonzero, **`amountToSwap += hookDeltaSpecified`** and check the swap type didn't flip (`exactInput ? amountToSwap>0 : amountToSwap<0 ⇒ HookDeltaExceedsSwapAmount`, `:273-279`).
- **Mechanism:** the hook eats part (or all) of the specified amount before the pool curve runs. `CustomCurveHook` returns `-amountSpecified` to drive `amountToSwap` to 0 (full NoOp of the CL swap, `CustomCurveHook.sol:47`).

### 4.2 afterSwap (`Hooks.sol:285-315`)
- carries `hookDeltaSpecified/Unspecified` from the beforeSwap return (`:295-296`).
- if `AFTER_SWAP_FLAG`: `hookDeltaUnspecified += afterSwap_return` (`:299`).
- **currency mapping (`:307-309`):** `hookDelta = (params.amountSpecified<0 == params.zeroForOne) ? toBalanceDelta(specified, unspecified) : toBalanceDelta(unspecified, specified)`. i.e. specified token is currency0 iff (exactInput XNOR zeroForOne).
- **`swapDelta = swapDelta - hookDelta`** (`:312`): the hook's delta is subtracted from the swapper's delta and accounted to the hook's own address (`PoolManager.sol:224`). Positive hookDelta ⇒ hook credited / swapper pays.

### 4.3 The skim, concretely (Known_Effects doc + DeltaReturningHook)
A hook with `BEFORE_SWAP|BEFORE_SWAP_RETURNS_DELTA` (and/or AFTER_SWAP variants) can return a positive specified/unspecified delta, which credits the hook and debits the swapper. The hook realizes it with a physical `take` (`DeltaReturningHook._settleOrTake`: delta>0 ⇒ take, delta<0 ⇒ settle, `DeltaReturningHook.sol:86-99`; `FeeTakingHook.afterSwap` takes a 1.23% fee on the unspecified token, `FeeTakingHook.sol:48-51`). The hook nets to zero (take offset by the positive return); **the swapper bears the cost**. Whether the swapper is *harmed* is exactly the severity question: a correct router enforces min-output/max-input, so in normal operation funds-at-risk may be only the slippage tolerance — NOT an unconditional drain. This is the calibration centerpiece (apply [[severity-gate-funds-at-risk]]).

---

## 5. BaseHook + deployment (periphery)

- `BaseHook` (`v4-periphery/src/utils/BaseHook.sol`): abstract, `is IHooks, ImmutableState`. Constructor calls `validateHookAddress(this)` (`:18-20`) ⇒ `Hooks.validateHookPermissions(this, getHookPermissions())` (`:31-33`) — deploy reverts if address bits ≠ declared permissions. Every external callback is `onlyPoolManager` and delegates to an internal `_*` virtual that `revert HookNotImplemented` by default (e.g. beforeSwap `:144-150`).
- `ImmutableState.onlyPoolManager` (`v4-periphery/src/base/ImmutableState.sol:17-20`): `if (msg.sender != address(poolManager)) revert NotPoolManager()`. **This is the exact guard whose ABSENCE caused Cork (#4).** A stateful hook callback without it can be called directly by anyone with attacker-chosen `hookData`/`sender`.
- `HookMiner` (`v4-periphery/src/utils/HookMiner.sol`): brute-forces a CREATE2 salt so `uint160(addr) & ALL_HOOK_MASK == flags` and the address is empty (`find` `:23-41`, `computeAddress` standard CREATE2 `:48-56`). For PoCs: either mine a salt or `vm.etch` an implementation onto a flag-correct address (BaseHook's `validateHookAddress` is virtual precisely so tests can override it, `:28-33`).

---

## 6. Example hooks (PoC bases — all in `v4-core/src/test/`)

- `DeltaReturningHook.sol` — settable specified/unspecified deltas; `beforeSwap`/`afterSwap` return them and `_settleOrTake` (`:86-99`). Minimal base for the **custom-accounting skim (#6)**.
- `FeeTakingHook.sol` — `afterSwap` fee on unspecified token (`:34-52`); `afterAdd/RemoveLiquidity` fee on liquidity (`:54-90`). Base for **hook-fee**.
- `CustomCurveHook.sol` — `beforeSwap` takes full input, settles full output, returns `-amountSpecified` to NoOp the curve (`:33-49`); blocks direct add-liquidity. Base for **full custom accounting**.
- (also available: `EmptyTestHooks`, `BaseTestHooks` (all-revert default), `DynamicFeesTestHook`, `LPFeeTakingHook`, `SkipCallsTestHook`.)

---

## 7. Bug-class → code map (citations at pin 59d3ecf)

| # | Class | Where the mechanism lives (file:line @ 59d3ecf) | Why it's the locus |
|---|-------|--------------------------------------------------|--------------------|
| 1 | **delta-accounting** (OZ C-01 native dual-token) | `PoolManager._settle:349-365` (native `:353-354` vs ERC-20 `:358-360`) + `sync:279-288` + `_accountDelta:368-378` | one physical transfer can hit both the native (`msg.value`) and ERC-20 (`balanceOf` delta) measurements ⇒ double credit. Needs a dual native/ERC-20 currency mock. |
| 2 | **callback-ordering / JIT (Spearbit 5.1.1)** | `Pool.donate:466` (`feeGrowthGlobal += amount*Q128/liquidity` to *current* in-range `state.liquidity`) + `PoolManager.donate:256-276` (before/after donate window) | donation accrues to whoever is in-range *now*; JIT liquidity added inside the same unlock right before donate captures it. CL-positioning drill. |
| 3 | **return-data handling** (OZ M-01 / returndata-bomb) | `Hooks.callHook:131-155` (copy `:140-149`) + `CustomRevert.bubbleUpAndRevertWith:83-119` (note `:82`, copy `:109`) + `ParseBytes` fixed offsets | a malicious hook returns oversized/crafted returndata; the manager copies it wholesale (gas grief / wrapped-revert). Length checks (`:152,:166,:259`) gate the parsers. |
| 4 | **permission / access-control** (Cork) | `ImmutableState.onlyPoolManager:17-20` (the guard) vs a hook callback missing it; contrast BaseHook applying it everywhere (`BaseHook.sol:144-150`, …) | a stateful `beforeSwap`/callback without `onlyPoolManager` is callable directly with attacker `hookData`/`sender` ⇒ forged privileged action. Trivial, clean PoC. |
| 5 | **rounding / delta-accounting in hook math** (Bunni) | hook-side, not core. Pattern: any hook doing `balance.mulDiv(shares,totalSupply)` style accounting (cf. `Pool.donate` `simpleMulDiv` `:474,:477`; swap fee-growth `Pool.sol:405`). Core swap/curve math: `Pool.swap:279`, `Pool.modifyLiquidity:146` | rounding in the hook's own liquidity/idle-balance accounting, amplified by structured swaps + many tiny withdrawals. Heaviest PoC (LDF). |
| 6 | **hook-fee / custom-accounting delta** (Known_Effects) | `Hooks.beforeSwap:248-282` (amountToSwap += specified `:275`) + `Hooks.afterSwap:285-315` (currency map `:307-309`, `swapDelta-=hookDelta` `:312`) + `BeforeSwapDelta.sol` + `DeltaReturningHook.sol` | hook returns a delta that debits the swapper; severity is context-dependent on router min-output checks. Calibration centerpiece. |
