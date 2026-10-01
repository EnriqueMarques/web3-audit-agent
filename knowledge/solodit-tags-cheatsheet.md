# Solodit Search Cheatsheet

[Solodit](https://solodit.cyfrin.io) aggregates 15,000+ findings from the top firms (Spearbit, Cyfrin, Trail of Bits, OpenZeppelin, ConsenSys, etc) and from contests (Code4rena, Sherlock, Cantina). **It is your best resource for avoiding time wasted on already-known bugs and for calibrating severity.**

## How to use it in each phase

### Phase 1 (Recon)
- Search for the **name of the project** you are auditing. Are there previous reports? What did they find?
- Search for the **fork** it comes from (e.g., Compound fork, Uniswap V3 fork). Common bugs in forks.

### Phase 3 (Hypothesis)
- For each hypothesis: run specific queries. If you find a similar finding, read:
  - How did they describe it?
  - Which severity did it get?
  - Is it mitigated in your target?
- If it is NOT mitigated in your target: possible bug.

### Phase L-A (Duplicate check)
- Broader searches for the project + bug type.

---

## Useful queries by category

### General

```
# By protocol type
"ERC4626"
"lending pool"
"AMM"
"perpetual"
"staking"
"vesting"
"governance"

# By concept
"reentrancy"
"flashloan"
"oracle manipulation"
"rounding"
"precision loss"
"signature replay"
"front-running"
```

### Reentrancy specifics

```
"cross-function reentrancy"
"cross-contract reentrancy"
"read-only reentrancy"
"ERC777 reentrancy"
"ERC1155 reentrancy"
"callback reentrancy"
```

### Oracle bugs

```
"spot price"
"TWAP manipulation"
"stale price"
"sequencer downtime"
"Chainlink"
"Pyth"
"oracle decimals"
"price feed"
```

### ERC4626 / Vault

```
"first depositor"
"inflation attack"
"share manipulation"
"donation attack"
"_decimalsOffset"
"virtual shares"
"convertToShares rounding"
```

### Lending

```
"liquidation"
"self-liquidation"
"bad debt"
"health factor"
"borrow cap bypass"
"collateral factor"
"interest rate manipulation"
"utilization rate"
```

### AMM

```
"K invariant"
"sandwich"
"JIT liquidity"
"slippage protection"
"deadline parameter"
"sqrtPriceX96"
"tick"
```

### Bridge

```
"replay attack"
"mint burn asymmetry"
"trusted source"
"chain ID"
"LayerZero"
"CCIP"
"Wormhole"
"validator set"
```

### Wallet / AA

```
"ERC4337"
"validateUserOp"
"session key"
"paymaster"
"account abstraction"
"bundler"
"signature aggregation"
"permit2"
```

### Token integration

```
"fee on transfer"
"rebasing"
"USDT"
"deflationary"
"weird ERC20"
```

### Storage / Proxy

```
"storage collision"
"uninitialized proxy"
"UUPS"
"transparent proxy"
"diamond"
"initialize"
"selfdestruct"
```

### MEV

```
"MEV"
"sandwich"
"front-run"
"back-run"
"JIT"
"liquidation MEV"
"oracle update arbitrage"
```

---

## Combinatorial queries

When you have a specific hypothesis, combine terms:

```
# Freshly deployed vault + flashloan
"first depositor flashloan"
"empty vault inflation"

# Lending + manipulation
"borrow rate manipulation"
"interest rate flashloan"

# Cross-chain + replay
"bridge replay nonce"
"cross-chain signature"
```

---

## Useful filters in the Solodit UI

- **By severity:** Filter by Critical/High to focus on the big bugs.
- **By date:** Recent findings (last year) are more relevant for current patterns.
- **By auditor:** Spearbit and Cyfrin tend to be the most rigorous. Trail of Bits is a classic.
- **By protocol:** If you are looking at a fork, filter by the original (e.g. Compound) to find inherited bugs.

---

## Efficient workflow

1. Before writing hypotheses: **5-min general queries** for the protocol type.
2. For each hypothesis: **1 specific query**, read the top 5 findings.
3. Before the PoC: confirm the hypothesis is not exactly a historical finding that is already patched.
4. Before submitting: a **deep query** for the project + category.

---

## Distill what you read

When a Solodit finding deserves a re-read, distill it into the project's knowledge base
(with the user's approval, see `prompts/orchestrator.md`):

- A reusable attack mechanism → `knowledge/patterns/<name>.md`
- A severity or process rule → `knowledge/heuristics/<name>.md`
- Details of a specific protocol (forks, quirks, line refs) → `knowledge/target-notes/<protocol>.md`

Always note the link to the original finding and why it is relevant. This becomes **very valuable**
after a few months.

---

## Solodit API (if available)

[Check whether Solodit has a public API. If it does, you can:]
- Auto-query from the agent when generating hypotheses
- Build a local cache of relevant findings
- Deduplicate automatically

If there is no API: use web scraping carefully (respect the ToS) or manual searches.

---

## More secondary sources

When Solodit doesn't have what you are looking for:

- **rekt.news** — post-mortems of successful exploits. Required reading.
- **DeFi Hack Labs** ([github](https://github.com/SunWeb3Sec/DeFiHackLabs)) — Foundry PoCs of historical exploits. The best resource for learning to write PoCs.
- **Audit reports directly:**
  - [Spearbit reports](https://github.com/spearbit/portfolio)
  - [Cyfrin reports](https://github.com/Cyfrin/audit-reports)
  - [Trail of Bits publications](https://github.com/trailofbits/publications)
- **C4 reports archive** — every past contest.
- **Smart Contract Weakness Registry (SWC)** — classics.
- **DASP Top 10** — classics too.
