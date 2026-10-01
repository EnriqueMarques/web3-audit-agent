# Wallet & Infra Security Patterns

Wallets, account abstraction, multisigs and infrastructure have their own specific vectors.

---

## ERC-4337 (Account Abstraction)

### Components

- **EntryPoint.** Singleton, receives UserOperations.
- **Account contract.** The user's smart contract wallet.
- **Bundler.** Off-chain, groups UserOps and sends them to the EntryPoint.
- **Paymaster.** (Optional) Pays gas on behalf of the user.
- **Aggregator.** (Optional) Optimizes signature verification.

### Bundler restrictions

`validateUserOp` has **opcode/storage restrictions** during simulation (ERC-7562):
- It cannot access the storage of other contracts (except SELF, paymaster, factory).
- It cannot use `BLOCKHASH`, `TIMESTAMP`, `BASEFEE` in validation.
- It cannot call external contracts (except whitelisted ones).

**Bug pattern:** An account contract that passes the honest bundler's simulation but does something different at execution.

```solidity
function validateUserOp(...) external returns (uint256) {
    if (block.number == 0) {
        // Bypass during simulation
        return 0;
    }
    // Real logic here
    require(/* strict check */);
}
```

`block.number == 0` during eth_call simulation on some providers → bypass.

### Typical bugs

#### Validation/execution divergence

`validateUserOp` approves the op, but `executeOp` does something different. If validation depends on `userOp.callData` superficially without reproducing the execution, there is a gap.

#### Nonce management

ERC-4337 uses 2D nonces (key, sequence). If the wallet does not handle the keys correctly, replay may be possible.

#### Signature aggregation bugs

If the wallet uses BLS or similar to aggregate signatures, errors in the verifier can allow invalid signatures.

#### Paymaster griefing

If the paymaster validates the userOp but then fails in `postOp`, gas is lost. The attacker can execute UserOps that pass validation but force a revert after execution.

#### Factory front-running

Wallet creation with CREATE2 + initCode. The attacker front-runs the deployment with a malicious initCode but the same address (CREATE2 collision with a different salt, or exploiting the init logic).

---

## Multisigs (Safe / Gnosis-style)

### Specific bugs

#### Threshold bypass

Edge cases:
- `threshold > owners.length` after a removal → permanent DoS.
- `threshold = 0` → anyone executes.
- Off-by-one in signature counting.

#### Module / guard bypasses

Safe allows modules that execute without signatures. If a module has bugs, every Safe that uses it is compromised.

#### Delegate call risks

Safe uses `delegatecall` for modules. If a module manipulates the Safe's storage → owner change.

#### Recovery contract bugs

Recovery flow: the owner loses their key, a recovery contract with a timelock can swap it. Bugs:
- Recovery without a real timelock.
- Recovery that anyone can initiate.
- Race conditions between recovery and normal ops.

---

## Smart Wallet Specific

### Session keys

Pattern: the user grants a key with a limited scope (a specific dApp, a specific contract, a specific selector).

Bugs:
- **Scope too broad.** "Any Aave contract" → the attacker uses an unaudited contract from the Aave ecosystem to drain.
- **Selector wildcards.** Allowing `*` in selectors → any function, including `transfer` and `approve`.
- **Replay across keys.** If two session keys of the same user share the nonce space.
- **Time validity.** Edge cases in `validUntil`. Off-by-one. Timezone issues with timestamps.

### Module installation

Modular wallets (Safe, Biconomy, ZeroDev): a malicious module compromises the whole wallet.

Bugs:
- Install without a properly verified signature.
- Uninstall that does not clean up state → a "ghost" module keeps executing.
- Reinit attacks on modules.

### Gas griefing

```solidity
function execute(UserOp memory op) external {
    uint256 gasStart = gasleft();
    // executes op
    uint256 gasUsed = gasStart - gasleft();
    paymaster.postOp(gasUsed, ...);
}
```

The attacker sends a UserOp with a correct gas estimation during validation but an `op.callData` that consumes all the gas at execution → the paymaster pays the maximum.

---

## Hardware wallet integration

If the target is a protocol that integrates with hardware wallets:

- **Clear signing.** Does the signature show readable info to the user? "Approve unlimited USDC to 0xabc..." vs "Sign 0x12abf...".
- **EIP-712 message construction.** If the message is structured, the hardware wallet displays it correctly. If it is an opaque hash, the user doesn't know what they are signing.
- **Blind signing exploits.** Phishing dApps that generate messages that look innocuous but contain destructive actions.

### Reportable bugs

- The protocol builds EIP-712 messages that do NOT include critical info (e.g., the transfer target does not appear in the visible struct).
- Replay attacks across protocol versions (no versionId in the domain).

---

## RPC / Node infrastructure

Less common in bounties, but it exists:

- **JSON-RPC method exposure.** Nodes with `admin_*` or `personal_*` publicly exposed.
- **eth_sendTransaction acceptance** without auth → the node's key gets drained.
- **Trace API leaks.** Traces of pending transactions leaking strategies.

---

## Bridge wallet/relayer infra

Bridges typically have relayers that move messages off-chain. Bugs:

- **Relayer key compromise.** If ONE relayer is compromised, how much damage? (It should be zero in a correct design, but sometimes it isn't.)
- **Replay protection on the relayer side.** A relayer that resends already-processed messages.
- **Censorship resistance.** Is there a fallback if the main relayer censors?

---

## Permit2 (Uniswap)

A widespread standard, a common bug vector:

- **Allowance race conditions.** Multiple permits with the same nonce.
- **Witness data manipulation.** Permit2 allows witness data in signatures; if the protocol does not validate it correctly, it can be injected.
- **Permit batch issues.** Edge cases in batched permits.

```solidity
// Vulnerable: trusting permit2 without verifying the witness
permit2.permitWitnessTransferFrom(
    permit, transferDetails, signer, witnessHash, witnessTypeString, signature
);
// if witnessTypeString != what the protocol actually uses → signature replay with a different witness
```

---

## Wallet integration in dApps

Patterns where dApp + wallet contract → bugs:

### Approval drain

The dApp asks for maximum USDC approval. If the dApp has a bug that lets an attacker call `transferFrom`, the allowance gets used.

**Bounty bug:** A dApp with a public function `executeWithApproval(address user, uint256 amount)` that does `transferFrom(user, ...)` without auth.

### Frontend phishing assistance

The dApp builds transactions that the user signs. If the contract accepts arbitrary calldata without restrictions, a compromised frontend can build malicious txs.

**Typical bug:** Multicall / batch functions without restrictions → a phishing frontend injects `transfer(victim_addr, attacker_addr, all)`.

---

## Solodit searches

- "ERC4337" / "account abstraction"
- "session key"
- "permit2"
- "multisig"
- "validation execution divergence"
- "paymaster"
- "blind signing"

---

## Active targets in this space

Interesting programs (verify current status):

- Safe (Gnosis Safe) — Immunefi, pays high
- Stackup, ZeroDev, Biconomy — AA programs
- Argent, Braavos (Starknet wallets)
- LayerZero, Wormhole, Axelar — bridge infra
- WalletConnect — connection layer

---

## How to approach a wallet audit

Different from DeFi:

1. **More complex threat model.** The attacker can be another user, a compromised frontend, a malicious signer, a malicious validator, a malicious module.
2. **Critical state machines.** Especially in recovery, multisig, session management.
3. **Signature schemes.** Verify that every use of ecrecover is correct, with appropriate EIP-712 domains.
4. **Storage layouts.** Upgradeable wallets are highly sensitive to storage collisions.
5. **Deployment edge cases.** CREATE2 collisions, factory front-running, init reuse.
