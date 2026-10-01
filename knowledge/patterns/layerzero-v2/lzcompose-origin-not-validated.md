# Pattern: LayerZero V2 `lzCompose` origin not validated (`msg.sender==endpoint` is the trap)

**Family:** access control / origin validation (LayerZero V2 compose path)
**References:** Brix Money, Code4rena 2025-11 (official Medium). The *severity by custody* rule is the same as in [[flashloan-arbitrary-call]], [[hook-callback-missing-onlypoolmanager]] and [[severity-gate-funds-at-risk]] (drainable impersonation ⇔ what is custodied).
**Severity when present:** **DEPENDS ON CUSTODY** — Critical if the composer custodies/forwards funds keyed on the compose message; LOW/MED if stateless (spoofable but moves no value); Medium if the bypassed composed action is a *permission/logic restriction* (Brix staking-bypass). NOT Critical automatic.
**Detection by Slither/Aderyn:** NO (they cannot know `_from` must equal the trusted upstream OApp; `msg.sender==endpoint` looks like a correct access-control guard)
**Solodit tags:** layerzero, oapp, lzcompose, cross-chain, access-control, origin-validation, severity-by-custody

---

## Core mechanism

A LayerZero V2 OApp can ask the destination endpoint to run a **second** message — a *compose* — after `lzReceive`. The compose channel lives in `MessagingComposer` (REAL contract, **inherited by `EndpointV2`**):

```
sendCompose(_to,_guid,_index,_message)  // PERMISSIONLESS; composeQueue[msg.sender][_to][_guid][_index] = keccak(_message)
lzCompose(_from,_to,_guid,_index,_message,_extraData)
  → ILayerZeroComposer(_to).lzCompose{value}(_from, _guid, _message, msg.sender, _extraData)
```

The natspec is explicit (`MessagingComposer.sol:17`): *"the composer MUST assert the sender because anyone can send a compose msg with this function."* The legit producer is `OFTCore._lzReceive`: it credits tokens to the composer (`:251`) and then calls `endpoint.sendCompose(toAddress, guid, 0, composeMsg)` with `from = the OFT` (`:267`). So a well-behaved composer expects `_from == that OFT`.

**THE subtlety (the whole bug).** Because `EndpointV2` *is* the `MessagingComposer`, the composer's own `msg.sender` during `lzCompose` is **always the endpoint** — *including when an attacker drives the attack* through the real permissionless `sendCompose` + `lzCompose`. Therefore:

> `require(msg.sender == endpoint)` is **necessary but NOT sufficient** — it passes for the attack too.

The decisive guard the composer MUST add is **`_from == trusted source`**, because the attacker fully controls `_from` (they bound it in `sendCompose` = their own address). An integrator who adds *only* the `msg.sender==endpoint` check feels safe and is still fully exploitable. **This is the single most reusable lesson of the pattern**, and it generalizes beyond LayerZero (the same shape as "the guard checks the wrong variable" — cf. [[erc2771-multicall-sender-confusion]], where `msg.sender` is right but `_msgSender()` is attacker-controlled).

## Brix Money (the canonical official instance, C4 2025-11, Medium)

Brix's lzCompose handler did not validate the origin, letting a crafted compose **bypass a staking restriction**. Graded **Medium** — because the composed action it gated was a *permission restriction*, not a fund-custody operation. That places the official instance at the low end of the custody axis; the same missing check on a fund-forwarding composer is Critical (see drill).

## Minimal vulnerable pattern

```solidity
// VULNERABLE — guards ONLY the necessary-but-insufficient check, trusts _from/the message
contract CustodialComposer is ILayerZeroComposer {
    function lzCompose(address _from, bytes32, bytes calldata _message, address, bytes calldata)
        external payable
    {
        require(msg.sender == endpoint, "not endpoint");      // TRUE even for the attacker's routed call
        // MISSING: require(_from == trustedOFT, "untrusted from");
        uint256 amountLD  = OFTComposeMsgCodec.amountLD(_message);
        address recipient = abi.decode(OFTComposeMsgCodec.composeMsg(_message), (address));
        token.transfer(recipient, amountLD);                  // forwards its float, ASSUMING upstream really credited it
    }
}
```
Attack (no cross-chain transfer at all): `endpoint.sendCompose(victim, guid, 0, evilMsg)` then `endpoint.lzCompose(attacker, victim, guid, 0, evilMsg, "")` → endpoint calls `victim.lzCompose(_from=attacker, …)`. In a PoC against LayerZero V2 core, the custodial composer's **100e18 float is fully drained, attacker loots 90e18, zero real bridge**. The fixed variant (`_from==trustedOFT`) reverts `"untrusted from"` (it bubbles — `MessagingComposer.lzCompose` has **no** try/catch; that is the Executor's job, so a direct `endpoint.lzCompose` propagates the revert).

## Severity by custody (the gate's worked example)

Same structure as [[hook-callback-missing-onlypoolmanager]] / [[flashloan-arbitrary-call]]: the mechanism (forge a compose) is always present, but severity is gated by **what the composer custodies in NORMAL operation**:

| composer custody | (a) naive | (b) gate | (c) official |
|---|---|---|---|
| custodies / forwards funds keyed on the msg | Critical | **CRITICAL confirmed** — drains custodied funds, permissionless, atomic, no bridge | — |
| stateless (bookkeeping, no value) | Critical | **LOW/MED** — spoof accepted (proves the missing `_from`) but no funds-at-risk | — |
| Brix instance (staking-restriction bypass) | High | **MEDIUM** — bypassed action is a permission restriction, not a fund op | **Medium** (Brix C4 2025-11) |

Rule: `lzCompose without _from check` + `composer custodies/forwards funds in normal op` → **Critical**; stateless → LOW/MED; restriction-bypass → Medium. Run [[severity-gate-funds-at-risk]] BEFORE labeling (this is the CONFIRM-Critical side when funds are custodied; the cap side when not). gate↔official **matches** at Brix.

## Required conditions

1. A contract implements `ILayerZeroComposer.lzCompose` and takes a **state-changing / value-moving** action using `_from` or the decoded `_message`.
2. It does **not** assert `_from == expected upstream OApp` (with or without the `msg.sender==endpoint` check — the latter alone does not help).
3. The composer holds/controls value (or authority over value) reachable by that action **in normal operation** (→ severity by custody).

## Detection heuristic

For every `lzCompose` implementation in scope:
- Does it check **`_from`** against the expected source (the peer OFT / app)? **Absence on a fund-touching composer = Critical candidate** (then run the custody gate).
- Treat a lone `require(msg.sender == endpoint)` as a **red flag, not a mitigation** — it is necessary but insufficient; the attacker's routed call satisfies it.
- Note the funds window: tokens are credited in `OFTCore._lzReceive:251` *before* `sendCompose` (`:267`) — a composer that forwards "what it was just credited" without binding `_from` forwards on a forged credit.
- Grep targets: `function lzCompose(`, `ILayerZeroComposer`, `OFTComposeMsgCodec.composeFrom`, `sendCompose`.

## Cross-reference

- [[severity-gate-funds-at-risk]] — the by-custody gate (worked example: custodial=Critical, stateless=LOW/MED, Brix=Medium).
- [[hook-callback-missing-onlypoolmanager]] — identical by-custody structure (forge a privileged callback ⇔ what's custodied); the V4 analog.
- [[flashloan-arbitrary-call]] — impersonation severity ⇔ custody of the impersonated contract.
- [[erc2771-multicall-sender-confusion]] — the same "guard checks the wrong variable" shape (`msg.sender` right, origin attacker-controlled).
- Target notes: `knowledge/target-notes/layerzero-v2.md` §4 (compose channel) + §6 point 6 + §7 (B1).
- Loci @ pin `9c741e7`: `MessagingComposer.sendCompose:23` / `lzCompose:39` (call `:57`) / natspec `:17`; `OFTCore._lzReceive:251`(credit)`/:267`(sendCompose); `OFTComposeMsgCodec` `composeFrom@44`,`amountLD@12`.
