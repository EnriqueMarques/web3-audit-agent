# MEV & Flashloan Patterns

MEV is one of the most sophisticated and best-paid vectors.

---

## Mental model: adversarial MEV

Assume every user transaction can be:
1. **Front-run.** The attacker sees your tx in the mempool and sends theirs with more gas.
2. **Back-run.** The attacker executes immediately afterwards, taking advantage of your state change.
3. **Sandwiched.** Front + back combined.
4. **Censored.** The bundler/builder does not include your tx.

For protocols: **which of the protocol's functionality is vulnerable to each of these?**

---

## Flashloan attack toolkit

Unlimited capital, atomic, near-zero cost (fees of 0.05-0.09% on Aave/Balancer/Maker).

### What an attacker can do with a $1B flashloan

1. **Move the price in any AMM.** By how much depends on the pool's depth.
2. **Trigger liquidations.** Almost-liquidatable positions become liquidatable.
3. **Manipulate the utilization rate** in lending to change rates instantly.
4. **Bypass token-gated functions.** If a function requires "holding X tokens", the flashloan provides them.
5. **Governance attacks.** If voting power is computed from the current balance.
6. **Inflate vault shares** with a massive deposit + manipulation.

### Standard defenses

- **TWAP oracles** (not spot). Window of 30+ min.
- **Snapshot voting**, not the current balance.
- **Multi-block requirements** for critical actions.
- **Anti-flashloan modifiers:** checking `tx.origin != msg.sender` (weak) or more sophisticated ones.
- **Min/max position sizes** per block.

### How to identify a protocol vulnerable to flashloans

```bash
# Look for spot price reads
grep -rn "getReserves\|slot0\|getAmountsOut" src/

# Look for dependence on the current balance
grep -rn "balanceOf(address(this))\|balanceOf(msg.sender)" src/

# Look for balance-based governance
grep -rn "votes\|delegates\|getVotes" src/
```

For each match, ask yourself: **what happens if this value is manipulated by a flashloan within a single block?**

---

## MEV-specific attacks

### Sandwich attacks (front + back run)

**Target:** Any AMM swap without appropriate slippage protection.

**Mechanics:**
```
Block N:
  TX1 (attacker front): Large WETH→USDC swap, pushes the USDC price up
  TX2 (victim): WETH→USDC swap with the old expected price, receives less USDC
  TX3 (attacker back): USDC→WETH swap, recovers more WETH than sold + profit

Attacker profit = (post-victim price - post-attacker price) over the size of the front-run
```

**When is it a protocol bug (not UX)?**

- If the protocol executes swaps internally without letting the user set slippage.
- If the slippage parameter is controlled by the contract, not by the caller.
- If there is a hardcoded slippage that is too high (>5%).

**Example:** Any vault that does `harvest()` with an internal swap without slippage = permanently sandwichable.

### Just-In-Time (JIT) liquidity

Specific to UniV3 and forks with concentrated liquidity.

```
Block N:
  TX1 (attacker): mints a position in the specific tick range where the victim is about to swap
  TX2 (victim): swaps, pays fees to the attacker (who holds 99% of the liquidity at that tick)
  TX3 (attacker): burns the position, withdraws capital + fees
```

**Bug?** It is not a Uniswap bug — it is a feature. But protocols that assume "LPs are passive" can have bugs.

### Liquidation MEV

**Vulnerable design:**
```solidity
function liquidate(address user) external {
    uint256 bonus = getBonus(user);
    payable(msg.sender).transfer(bonus);
}
```

Any searcher in the mempool can front-run with more gas. It becomes a gas auction.

**Better design:** An on-chain auction (Dutch auction), or liquidation auctions with a time delay. Liquity has a Stability Pool that avoids the auction.

**Bug in a bounty?** If the liquidation has a design flaw (e.g. the bonus doesn't compensate the risk, so there are no liquidations → bad debt accumulates), that is a business logic bug.

### Oracle update arbitrage

When an oracle updates on-chain, there is 1 block where:
- Block N-1: old price, borderline-healthy position
- Block N: oracle updates, position liquidatable

Searchers compete to liquidate in block N. But if the protocol also lets the user `borrow` in block N, before the update lands, at the old price, the attacker:
1. Sees the oracle update in the mempool
2. Front-runs it with an additional `borrow` at the old price
3. After the update, their position is underwater
4. But they already took the money

**Mitigation:** Oracle updates lock borrows in the same block, or use the previous block's price.

---

## Documented flashloan attack patterns

### Pattern 1: Oracle manipulation → inflated mint/borrow

```
1. Flashloan $100M USDC.
2. Swap $50M in the TOKEN-USDC pool, pushing the TOKEN price up.
3. Deposit 1M TOKEN as collateral in a lending protocol that uses this pool as its oracle.
4. Borrow $20M USDC against the inflated collateral.
5. Swap back to recover USDC and repay the flashloan.
6. Profit: $20M - costs.
```

**Examples:** Inverse Finance ($15M, June 2022), Mango Markets ($114M, October 2022).

### Pattern 2: Vault inflation after a flashloan

Combination of a flashloan + ERC4626 inflation.

```
1. The attacker spots a freshly deployed vault.
2. Flashloan $10M.
3. Deposits 1 wei + donates $10M directly to the vault.
4. Waits for a victim deposit (or induces it via the frontend).
5. Withdraws their shares + profit.
6. Repays the flashloan.
```

### Pattern 3: Self-liquidation farming

Protocols that distribute tokens to the liquidator.

```
1. The attacker creates an almost-liquidatable position A.
2. The attacker creates position B (another account) that liquidates A.
3. Captures the liquidation bonus + reward tokens.
4. Repeats it millions of times.
```

**Mitigation:** Exclude `msg.sender == user` in liquidation, or make distributions merkle-based.

### Pattern 4: Read-only reentrancy in an oracle

```
1. The attacker calls Curve.add_liquidity with their own tokens and a callback.
2. In the callback (from the ETH receive), Curve is in an intermediate state.
3. The callback invokes another protocol that reads Curve.get_virtual_price().
4. The reported virtual_price is wrong (D updated, totalSupply not).
5. The other protocol mints tokens based on the wrong price.
```

**Example:** dForce ($3.6M, April 2023).

---

## MEV defenses for protocols

If you audit a protocol and do NOT see these defenses, an MEV hypothesis is valid:

| Concern | Defense |
|---------|---------|
| Sandwich on internal swaps | minOut parameter, controlled by the user |
| Front-running deposits | commit-reveal, batch auctions |
| Oracle manipulation | TWAP 30+ min, multiple sources |
| Liquidation MEV | Dutch auction, stability pool |
| Governance flashloan | Snapshot voting, lockup |
| First-deposit inflation | Virtual shares, dead shares, deployer initial deposit |
| Replay across chains | chainId in signatures |

---

## Relevant Solodit searches

- "MEV"
- "sandwich"
- "JIT liquidity"
- "flashloan oracle"
- "manipulation Curve"
- "self-liquidation"
- "read-only reentrancy"

---

## MEV tooling

- **Tenderly fork.** To simulate flashloan attacks against real mainnet state.
- **Phalcon (Blocksec).** Transaction decompilation and trace analysis.
- **mev-inspect-py.** To analyze historical MEV.
- **Flashbots.** RPC and bundler. Useful for understanding the conditions under which a PoC would execute (never broadcast from a hunt).
- **Anvil with `--fork`.** Local mainnet fork for PoCs.

```bash
# Anvil fork
anvil --fork-url $MAINNET_RPC --fork-block-number 19500000

# Your PoC connects to localhost:8545 and reproduces the atomic attack
forge script script/Exploit.s.sol --rpc-url http://localhost:8545 --broadcast
```
