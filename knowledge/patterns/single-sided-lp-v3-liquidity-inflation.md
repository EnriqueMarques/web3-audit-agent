# Pattern: Single-sided LP V3 inflates ISolidlyV3Pool.liquidity() without proportional balanceOf change

Adding single-sided V3 liquidity (e.g. only BOOST to a range away from the
current price) inflates the aggregate `ISolidlyV3Pool.liquidity()` without changing
`IERC20.balanceOf(pool)` proportionally. Any AMO formula that
uses `(totalLiquidity * f(balanceOf))` for sizing becomes manipulable.

**Family:** V3-specific donation manipulation / oracle-spot manipulation
**Reference example:** AXION, Sherlock contest #552 (official H-1 `unfarmBuyBurn`, H-4 `_addLiquidity` DoS)
**Severity when present:** HIGH (see [[severity-heuristic-high]])
**Detection by Slither/Aderyn:** NOT flagged (economic logic, not a static
pattern)
**Solodit tags:** amm-manipulation, liquidity-inflation, v3-specific

---

## Core mechanism

V3 allows LP positions in arbitrary ranges (concentrated liquidity).
`liquidity()` aggregates the L of every position active at the current tick.
`balanceOf(pool)` only reflects physical tokens.

Donating single-sided LP in a range that includes the current price raises
`liquidity()` without changing `balanceOf` proportionally. The inflation is
asymmetric: with token A alone you can lift `liquidity()` without
contributing B, because the chosen range makes the whole position A-side.

Key difference with V2:
- V2 donation = a direct `transfer` to the `pair`. Changes `balanceOf`.
- V3 donation = `mint` of an LP position. Changes the aggregate `liquidity()`.

AMOs written against V3 with V2-style assumptions (mixing `liquidity`
with `balanceOf`) are exploitable.

---

## Minimal vulnerable pattern (AXION V3AMO)

```solidity
// V3AMO._unfarmBuyBurn — sizing of the LP to remove
uint256 boostBalance = IERC20(boost).balanceOf(pool);
uint256 usdBalance   = IERC20(usd).balanceOf(pool);
uint256 totalLiquidity = ISolidlyV3Pool(pool).liquidity();

uint256 liquidity = (totalLiquidity * (boostBalance - usdBalance)) /
                    (boostBalance + usdBalance);
liquidity = (liquidity * LIQUIDITY_COEFF) / FACTOR;

// The AMO tries to remove `liquidity` LP, but only owns a fraction
// of the position. Since `totalLiquidity` is inflated by the attacker,
// the computed `liquidity` > the AMO's real LP -> overburn / revert / over-
// pump of the price.
```

`liquidity` (aggregate) and `balanceOf` (physical) are incommensurable; an
attacker can unbalance them at near-zero cost via single-sided LP minting
(no tokens are left stranded — they are withdrawn after the exploit by closing
the position).

---

## AXION vector (H-1)

1. The attacker mints a single-sided LP position with BOOST in an ITM range.
2. The aggregate `ISolidlyV3Pool.liquidity()` goes up; `balanceOf(pool, BOOST)`
   goes up; `balanceOf(pool, USD)` does not change.
3. The operator (or anyone, depending on access control) calls
   `unfarmBuyBurn`.
4. The AMO computes removing more LP than it holds; the path pushes the price
   above the peg (heavy BOOST buying).
5. The attacker (with pre-positioned BOOST or from the removed position
   itself) sells BOOST expensively against the overbought pool.
6. The attacker closes the donated LP; net profit positive, BOOST ends up
   above the peg.

---

## How to detect it (audit checklist)

In any AMO/strategy on top of V3:

1. Grep formulas that combine `pool.liquidity()` with `balanceOf(pool)`
   or reserves.
2. Any `totalLiquidity * f(balanceOf)` mix is a candidate.
3. Confirm whether the formula assumes V2-style proportionality.
4. If so: vector. Probable severity HIGH (see the counter conditions in
   [[severity-heuristic-high]]).

Anti-pattern: treating `liquidity()` as a "TVL proxy" is wrong in V3.
`liquidity()` is the aggregate L at the current tick, not value.

---

## Typical refuters that are NOT sufficient

- **`nonReentrant`:** the donation happens BEFORE the call, not inside the vulnerable
  tx. The attacker mints LP, calls the victim in a separate tx (or the same
  tx, two steps), withdraws the LP.
- **Pause guard:** the donation does not require a call to the AMO; it is an LP mint into the
  underlying pool. Pausing the AMO does not prevent it.
- **Aggregate 1:1 floor / post-hoc peg check:** does not protect against
  inflation of the aggregate `liquidity()` during the path; the later check
  sees a price moved by a legitimate unfarmBuyBurn action.
- **Slippage check on the AMO's swap:** unfarmBuyBurn executes the expected
  path; the AMO's "output" is consistent with its inflated sizing.

---

## Sufficient refuter (correct mitigation)

Compute the LP sizing from the AMO's own position
(`positions(tokenId)`) or from the liquidity the AMO controls, not from the
aggregate `pool.liquidity()`. If the sizing depends on the pool's global
state, that state must be sanitized (excluded range, TWAP oracle instead
of spot).

---

## Exploitation heuristic: buy-side first

In AMOs on top of V3 (Solidly V3, UniV3, Aerodrome V3), try the **BUY-side** path first in the PoC. It closes the atomic loop through V3-specific vectors (single-sided LP, `liquidity()` inflation) without needing concentrated stableswap.

- **Sell-side (doesn't close in a CP mock):** the attacker raises the price → the AMO mints+sells → the attacker buys back; the CP math makes the attacker lose.
- **Buy-side (closes, V3-specific):** the attacker manipulates `liquidity()`/depth → the AMO buys+burns more → the price goes up → the attacker (with pre-positioned tokens) sells high.

Example: in AXION the sell-side PoC (`mintSellFarm`) did not close atomically on a constant-product mock; the official finding (HIGH) was the buy-side `unfarmBuyBurn`.

---

## Cross-refs

- [[oracle-spot-price-amm-manipulation]] — parent class (manipulation of
  AMM spot/aggregates).
- [[flashloan-repayment-balance-conflation]] — family (mixing liquidity metrics
  with balance metrics).
- [[severity-heuristic-high]] — severity heuristic
  for this class.
- [[fork-behavior-divergence-checklist]] — when the V3 fork diverges,
  widen the sweep.
