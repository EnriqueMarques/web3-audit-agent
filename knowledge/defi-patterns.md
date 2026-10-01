# DeFi-Specific Patterns

Patterns specific to each type of DeFi protocol. When recon identifies the target as a Lending / AMM / Vault / etc protocol, read the corresponding section.

---

## Lending Protocols (Aave/Compound forks)

### Critical components

1. **Interest rate model.** How is the utilization rate computed? Is there a kink? Is it manipulable?
2. **Collateral factor.** Per asset or global? Modifiable by governance? With a timelock?
3. **Liquidation logic.** Bonus, close factor, partial vs full.
4. **Oracle integration.** Critical, see the oracle patterns.
5. **Borrow caps / supply caps.** Do they exist? Can they be bypassed?

### Typical lending bugs

#### Liquidation profit + collateral bonus arithmetic

The attacker creates an almost-liquidatable position, waits for (or manipulates) the price for liquidation, and captures their own collateral bonus. If the bonus calculation does not consider that the liquidator can be the same user, profit.

```solidity
function liquidate(address user, uint256 repay) external {
    require(healthFactor(user) < 1e18);
    // Liquidator pays repay, receives collateral + bonus
    uint256 collateralOut = (repay * 1.1) / price;
    transferCollateral(user, msg.sender, collateralOut);
    burnDebt(user, repay);
}
```

If `msg.sender == user`, the user pays the repay with their own liquidity and captures the bonus. Is that prevented?

#### Self-borrow, self-supply loops to farm governance tokens

If the protocol distributes COMP/AAVE-style rewards by participation, the attacker can artificially inflate borrows/supplies to harvest tokens.

**Example:** Compound bug 2021 ($90M wrong distribution).

#### Donation to break the exchange rate

cTokens/aTokens have an exchangeRate based on `cash + borrows - reserves` / `totalSupply`. If the protocol allows sending tokens directly to the cToken, the attacker can manipulate the exchangeRate.

#### Bad debt distribution

When a position is not 100% liquidatable (the price falls fast), bad debt is left. Who eats it? If it is socialized among LPs without warning, exit run.

#### Borrow before liquidation

```
1. The attacker deposits 100 ETH as collateral.
2. The attacker borrows the equivalent of 100 ETH in USDC (max LTV).
3. ETH falls 5%. The position is liquidatable.
4. The attacker front-runs the liquidator with an additional `borrow` using the same (now fallen) price.
5. The attacker extracted more value than their original collateral.
```

Is the borrow function blocked when the healthFactor approaches 1?

---

## AMMs (Uniswap/Curve forks)

### Constant product (UniV2 style)

Typical bugs:
- **Skim attack.** If internal reserves get out of sync with real balances (someone sends tokens directly), `skim()` transfers them out. But if the protocol assumes `reserves == balance`, error.
- **Sync griefing.** `sync()` can be manipulated to cause temporary mispricing.
- **K invariant violation.** `(x + dx) * (y - dy) >= x * y`. If the fee is applied incorrectly, k decreases → free profit for the attacker.

### Concentrated liquidity (UniV3 style)

- **Liquidity sniping.** Add liquidity at a specific tick right before a large swap, remove it afterwards → steal fees.
- **Just-in-time (JIT) liquidity.** MEV vector.
- **Range manipulation.** Artificial tick movements to force other LPs out of range.
- **Tick spacing edge cases.** Liquidity at ticks outside the valid spacing.

### Curve-style stableswap

- **Imbalanced pool exploits.** When the ratio deviates far from the peg, slippage changes. The attacker can force an imbalance and profit from the rebalance.
- **Read-only reentrancy via get_virtual_price().** Critical for protocols that use it as an oracle.
- **Rounding in `add_liquidity` with `[0,0,...,amount]`.** Edge cases where a single-token deposit miscomputes shares.

---

## Yield Vaults / Strategy Vaults (Yearn-style)

### Components

1. **deposit/withdraw with shares (ERC4626).**
2. **Strategy contracts** that invest the assets.
3. **harvest()** that updates pricePerShare.
4. **Performance fees / management fees.**

### Typical bugs

#### Inflation attack (covered)

Yes, again. It is the number one bug in new vaults.

#### Harvest sandwich

Before harvest, pricePerShare is old. After it, it is new (higher if there was profit). The attacker:
1. Front-runs harvest with a massive `deposit` at the old price.
2. Harvest raises pricePerShare.
3. The attacker withdraws at the new price.

Mitigation: a minimum lockup or a performance fee on recent exits.

#### Strategy emergency exit losing funds

If the strategy can be bricked by an external dependency (Aave pause, etc), is there a rescue? How is it executed? Can the owner drain under that pretext?

#### Fee accounting bugs

Performance fees computed on accumulated gains vs per harvest. Off-by-one errors when fees change.

---

## Liquid Staking (Lido-style)

- **Maintaining the stETH/ETH ratio.** Is it guaranteed 1:1? Or floating? Protocols that assume 1:1 → bug during depeg events.
- **Withdrawal queue.** Ordering, MEV, race conditions.
- **Validator slashing impact.** How is it distributed? Negative rebase?
- **Restaking layer (EigenLayer-style).** AVS slashing, operator misbehavior.

---

## Perps / Synthetic Assets (GMX/Synthetix forks)

### Components

- **Funding rate.** Mechanism to keep the price close to spot.
- **Margin requirements.** Initial vs maintenance.
- **PnL calculation.** Open price vs close price, fees.
- **Liquidation engine.** Different from lending.

### Typical bugs

#### Funding rate manipulation

If funding is computed with the utilization of only one side, the attacker can open massive positions to force favorable funding.

#### Open + close in the same block

Some perps charge fees on opening AND on closing. If the closing fee is < the spread, there are sandwich-style attacks.

#### GLP-style mint/redeem

GMX V1 GLP had a bug where priceImpact was computed differently on mint vs redeem, allowing risk-free profit.

#### Self-trade via two accounts

An attacker with account A long and account B short. Does the protocol count both as "open interest"? Cross liquidations?

---

## Bridges (cross-chain messaging)

Already covered in vulnerability-classes but it deserves emphasis: **bridges carry the highest bounties** ($1M-$10M+ on Immunefi).

Specific patterns:
- **Mint/burn parity.** Any asymmetry = exploit.
- **Trusted source verification.** Source chain ID + source address, not just the chain.
- **Replay protection.** Nonces per chain pair, not global.
- **Validator set transitions.** What happens during a validator change? Messages in flight?
- **Light client verification.** Does it assume finalized blocks? L2 reorgs?

---

## Stablecoin protocols

### Algorithmic vs Collateralized vs CDP

**CDP (MakerDAO, Liquity-style):**
- Liquidation logic (covered)
- Oracle dependency (covered)
- Stability fee accumulation rounding
- Emergency shutdown logic

**Algorithmic (UST-style, 💀):**
- Death spiral mechanics
- Mint/burn arbitrage
- Reflexive collateral

**LSD-collateral (Lybra, Prisma):**
- Yield-bearing collateral changes value without a transfer
- Rebasing collateral edge cases

---

## Governance Tokens / Voting

- **Snapshot manipulation.** If the snapshot can be front-run with borrowed tokens, governance hijack.
- **Flash loan governance attack.** Borrow tokens → vote → repay.
  - **Example:** Beanstalk ($182M, April 2022).
- **Delegation transitivity.** Bugs in delegate chains.
- **Proposal execution arbitrary calls.** If a proposal can execute arbitrary calldata, governance compromise = total drain.
- **Quorum bypass.** Proposals when there are few active voters.

---

## NFT / NFTfi

- **Royalty enforcement.** Bypass via a marketplace that doesn't respect it.
- **Lending/borrowing with NFT collateral.** Pricing is subjective.
- **Lazy minting signature reuse.** Off-chain signatures for minting — with replay protection?
- **Reveal manipulation.** A random reveal is vulnerable to manipulation if it uses the block hash.

---

## How to use this document

When the recon-agent identifies the protocol type, **load the corresponding section** and use it as a mental checklist during hypothesis generation. It is not exhaustive — but every time you find a new bug in one of these types, propose the pattern for this file in the post-mortem (it is added with the user's approval). The knowledge base grows with experience.
