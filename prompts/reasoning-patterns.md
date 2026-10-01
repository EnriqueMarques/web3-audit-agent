# Reasoning Patterns — How a top hunter thinks

This document encodes the reasoning patterns that separate the top researchers from the rest. Read it before you start generating hypotheses. When you are in Phase 3, **think explicitly about which of these patterns apply** to the code in front of you.

---

## Pattern 1: Invariant Breaking

Every protocol assumes invariants — properties that must always hold. Bugs live where these invariants break.

**Exercise:** For each contract, list the invariants in natural language. Then, for each one, look for a path that breaks it.

**Common DeFi invariants:**
- "The sum of individual balances = totalSupply"
- "A position can never have `collateralValue < debtValue * liquidationThreshold`"
- "The LP token price never decreases (in the absence of negative fees)"
- "A user can never withdraw more than they deposited (in the absence of yield)"
- "Only the owner can execute X"
- "The nonce always increases monotonically"

**How to break them:**
- Reentrancy between the write and the read of the invariant
- Operations where order matters: A→B vs B→A produce different states
- Numerical edge cases: `amount = 0`, `totalSupply = 0`, first depositor
- Visible intermediate states: during a callback, what state does the attacker read?

**Historical example:** Wormhole Solana ($326M). Assumed invariant: "a VAA is only processed if it is signed by the guardians". The bug: verification was done with a sysvar that was not validated, allowing a full bypass.

---

## Pattern 2: Economic Adversary with $∞

**Mindset:** Assume the attacker has an unlimited flashloan from Aave/Balancer/Maker. What can they do in a single atomic transaction?

Questions to answer for each protocol:

- **Oracle manipulation.** Does the protocol read prices from an AMM? Spot or TWAP? If TWAP, what window? Is it manipulable with a large swap during that window?
- **Share price manipulation.** In vaults: can I donate tokens directly to the contract to inflate `pricePerShare` and front-run the first depositor (donation/inflation attack)?
- **Utilization rate manipulation.** In lending: can I borrow massively to push interest rates up before my position gets liquidated?
- **Ratio manipulation.** In concentrated liquidity AMMs: can I temporarily move the tick range to extract value from LPs?

**Historical example:** Mango Markets ($114M). The attacker manipulated the MNGO price with a flashloan, inflated the value of their collateral, borrowed against that inflated collateral, drained. The broken assumption: the oracle was manipulable within a single block.

---

## Pattern 3: Cross-Protocol Composability

The protocol you are auditing does not live in isolation. It talks to others. Bugs live in the interfaces.

**Questions:**

- Does it receive ETH/tokens from third-party protocols? If so: what happens if those tokens are ERC777 with hooks? ERC721? Fee-on-transfer tokens? Rebasing tokens (stETH, AMPL)?
- Does it call external protocols with `call`? Does it handle reentrancy from those calls correctly?
- Does it assume `transfer()` returns `true`? Tokens like USDT return nothing.
- Does it assume `balanceOf` is stable? Rebasing tokens change without a transfer.
- Does it integrate with LayerZero/CCIP/Wormhole? Cross-chain message replay is a classic vector.
- Does it use Permit2? Does it handle signature vs allowance vs nonce correctly?

**Historical example:** Cream Finance ($130M). Reentrancy via ERC777 tokens (AMP). The protocol was safe against reentrancy in its own tokens, but did not consider that a supported token might have hooks.

---

## Pattern 4: State Machine Modeling

Model the contract as a state machine: states, transitions, guards. Look for:

- **Impossible transitions that happen.** State A → State C without going through B.
- **Terminal states that aren't.** After "withdraw", can the user do anything else?
- **Race conditions between transitions.** Two users trigger simultaneous transitions; one invalidates the other.

**Application:** Especially useful in protocols with phases (vesting, auctions, governance, escrow). Draw the state diagram before auditing.

---

## Pattern 5: Time and Block Manipulation

Time is an adversarial input.

- **Manipulable block.timestamp.** Miners/sequencers can shift the timestamp by ~15s. Is there logic sensitive to this?
- **L2 quirks.** On Arbitrum/Optimism, `block.number` does not mean the same as on mainnet. Does the code assume it does?
- **Sequencer downtime.** On L2s, if the sequencer goes down, what happens to liquidations? Chainlink has a Sequencer Uptime Feed for a reason.
- **Reorg vulnerability.** On L2s with slow finality, are there cross-block race conditions?
- **Vesting/cliff edge cases.** At the exact cliff: does 0% or 100% unlock? Off-by-one errors are common.

---

## Pattern 6: Numerical Edge Cases

Special amounts break logic:

- `amount = 0` — is it validated? Division by zero? Empty loops?
- `amount = 1` — wei dust attacks, rounding
- `amount = type(uint256).max` — overflow in later arithmetic
- `amount = totalSupply` — what happens if Alice tries to withdraw everything?
- **First depositor** — the most exploited case. `shares = amount * totalShares / totalAssets`; if `totalShares = 0` the formula does not apply and there is usually special logic. Is it robust?
- **Last withdrawal** — when the last wei is withdrawn, is the contract left in a consistent state?

**Donation/Inflation attack (critical in vaults):**

```
1. The attacker sees that a freshly deployed vault has no deposits.
2. The attacker deposits 1 wei → receives 1 share.
3. The attacker transfers 10000e18 directly to the contract.
4. The victim deposits 10000e18 → formula: shares = 10000e18 * 1 / 10000e18 = 1.
5. But because of rounding, they receive 0 shares.
6. The attacker withdraws their 1 share, draining everything.
```

Mitigations: virtual shares (OpenZeppelin ERC4626), an initial dead-shares deposit, or using `convertToShares` with offsets.

---

## Pattern 7: Rounding and Precision

Division in Solidity always rounds down. The question is: **who benefits from the rounding?**

- In `mintShares`: does the user receive fewer shares than they pay for (round down favors the protocol) or more?
- In `redeem`: does the protocol pay out fewer assets (round down favors the protocol)?
- **Rule of thumb:** Round down must favor the protocol, not the user. If it is the other way round, there is free money.

**Multiply before dividing.** `(a / b) * c` loses precision. Always `(a * c) / b`. If this is wrong, it is usually a bug.

**Accumulation of rounding errors.** Are there loops with calculations that accumulate error wei by wei? Repeated calls can drain the contract 1 wei at a time. Reportable as Medium even if small.

---

## Pattern 8: Signatures and Replay

Any protocol with EIP-712:

- Is `chainId` in the domain? If not: cross-chain replay.
- Is there a nonce? Is it per-user or global? Can the attacker increment it to DoS the user?
- Is `deadline` validated? With `>=` or `>`? Off-by-one.
- **Permit + transferFrom race.** If I front-run the `permit()` with my own (allowance = 0), the subsequent `transferFrom` fails → DoS.
- **Signature malleability.** Does it use raw `ecrecover` or OZ ECDSA? `ecrecover` allows malleable signatures (s vs n-s).

---

## Pattern 9: Access Control Subtleties

Beyond "is this function `onlyOwner`?":

- **Init functions.** Can `initialize()` be called twice? On the implementation contract as well as the proxy?
- **DELEGATECALL in proxies.** Does the implementation have `selfdestruct`? UUPS where the proxy can be destroyed through an uninitialized implementation.
- **Transferable roles.** Is `transferOwnership` one-step or two-step? One-step = risk of transferring to a mistyped address and permanent bricking.
- **Frontend assumptions.** The protocol assumes it is called from its frontend with certain parameters. What happens if you call it directly?
- **Multisig threshold edge cases.** What happens if threshold > owners.length? If an owner removes themselves?

---

## Pattern 10: MEV / Flashloan Specific

- **Sandwich attacks.** Does every swap in the protocol have slippage protection? Is it controlled by the user or by the contract?
- **JIT liquidity.** In Uniswap V3 forks: can liquidations be front-run by adding liquidity right before and removing it right after to capture fees?
- **Liquidation MEV.** Does liquidation give a fixed bonus or is it an auction? Can the liquidator be front-run?
- **Oracle update sandwich.** If the protocol reads an on-chain oracle: when the oracle updates, is there a window that can be arbitraged?
- **Flashloan callbacks.** If the protocol issues flashloans: can the callback modify state that the rest of the flashloan depends on?
- **Atomic composability.** Can the attacker, in one transaction: take a flashloan → manipulate the price → liquidate themselves → repay the flashloan with profit?

---

## Pattern 11: Wallet & Infra Specific

- **Account Abstraction (ERC-4337).** Is off-chain vs on-chain validation consistent? Can `validateUserOp` have side effects? Bundler restrictions (no storage access) — does the contract respect them?
- **Smart wallet upgrades.** Pre/post upgrade hooks? Can they be bypassed?
- **Session keys / delegated signers.** Is the scope correctly limited? Replay across sessions?
- **Gas griefing.** Can an attacker make the wallet pay gas for operations it did not authorize?
- **Storage layout in upgradeable wallets.** Layout changes between versions break active wallets.
- **Recovery mechanisms.** Social recovery, guardians: is the quorum bypassable? Is the time-lock respected?

---

## Anti-pattern: things that are (usually) NOT bugs

To avoid wasting time:

- Pure "centralization risk". The owner can do X. Yes, they know. Only report it if it is undisclosed.
- "Gas optimization" in a bug bounty. Doesn't pay.
- "Missing events" in a bug bounty. Doesn't pay (in contests, low).
- Issues that require > 51% of validators colluding. Doesn't pay.
- "The user could lose money if they sign a malicious transaction." That is UX, not a bug.

---

## Final check before moving to PoC

For each hypothesis, answer these 4 questions:

1. **Which invariant or assumption breaks?** (In one concrete sentence)
2. **Who gains what?** (The attacker deposits X, receives Y. The difference must be positive and exceed gas.)
3. **Is it atomic or does it require a multi-block setup?** (Atomic = easier, higher severity.)
4. **Is there a similar finding on Solodit?** (If there is, read how it was reported and verify it is not the same bug, already patched.)

If all 4 have a clear answer, the PoC is worth it. If any of them is vague, refine the hypothesis first.
