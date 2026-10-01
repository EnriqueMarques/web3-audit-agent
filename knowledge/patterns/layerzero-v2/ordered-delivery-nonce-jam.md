# Pattern: LayerZero V2 ordered-delivery nonce jam (the channel never bricks; the *ordered OApp* does)

**Family:** DoS / liveness (LayerZero V2 ordered delivery)
**References:** windhustler's checklist (#5, High); an area of real findings (Drips/Cantina, BridgedGovernor, cross-chain governance). Calibration axis shared with [[severity-gate-funds-at-risk]].
**Severity when present:** **DoS/liveness, gated by (recovery reachability) × (value of what is stuck).** Recoverable (owner `skip`/`nilify`/`clear`/`setOrderedNonce`) + non-critical payload → **MED**. Escalates to **High** when recovery is unreachable (owner renounced + no OApp-level counter reset) OR the stuck messages lock funds / the OApp is governance-critical. Nothing is *stolen*.
**Detection by Slither/Aderyn:** NO (ordered delivery is an OApp-level convention; no detector models "a reverting `_lzReceive` jams later nonces")
**Solodit tags:** layerzero, oapp, ordered-delivery, nonce, dos, liveness, recovery, severity-by-recoverability

---

## Core mechanism

Two facts about V2 nonces that together define the bug:

1. **The channel enforces contiguous *VERIFICATION*, not contiguous *EXECUTION*.** `MessagingChannel._clearPayload:126` walks `lazyInboundNonce+1 … N` and requires each to be *verified* (loop `:137-139`) before executing N; it does **not** require them *executed*. It deletes the payload hash (`:150`) **AFTER** the receiver call, so **a revert rolls the whole tx back and restores the hash → the channel NEVER bricks.** Out-of-order *execution* is allowed once 1..N are verified.

2. **Ordered *delivery* is an OApp-level property, not a channel guarantee.** The endpoint default is unordered (`OAppReceiver.nextNonce:78` returns 0). An OApp opts into ordering by overriding `nextNonce` and enforcing it — the canonical pattern is `OmniCounterAbstract._acceptNonce:243-252`: `require(_nonce == maxReceivedNonce + 1, "OApp: invalid nonce")`.

**The jam:** an ordered OApp + a nonce whose `_lzReceive` *always reverts* (poison content, a bug, a dependency that reverts) ⇒ every later nonce is rejected with `"OApp: invalid nonce"` and the backlog is stuck. The channel is healthy (the poison nonce's hash is still present); the *ordered integrator* is jammed.

**The sharp, reusable sub-finding (why endpoint recovery alone is NOT enough):** the endpoint recovery primitives (`skip`/`nilify`/`burn`/`EndpointV2.clear`) advance the **endpoint's** lazy nonce — but **NOT the OApp's own `maxReceivedNonce`.** So clearing the poison at the endpoint still leaves nonce N+1 rejected by the OApp's own check. An ordered OApp that keeps its own counter needs its **own** recovery: the canonical `OmniCounter.skipInboundNonce:264-269` calls `endpoint.skip` **AND** bumps `maxReceivedNonce`. An ordered OApp missing that dual recovery is the stuck case. **That recovery exists is exactly why the ceiling is MED, not Critical.**

## Severity by recoverability × magnitude (the gate's worked example)

| | value | reasoning |
|---|---|---|
| (a) naive | **HIGH/Critical** | "one poison message permanently bricks the whole ordered channel → all later messages stuck forever / funds locked" |
| (b) gate | **MED** (DoS/liveness) | nothing stolen; **channel never bricks** (hash restored on revert); jam is OApp-level and **recovery EXISTS** (owner/delegate `setOrderedNonce`/`skip`/`clear`/`nilify`). Recoverable DoS ⇒ MED. **Escalates to HIGH** when (i) recovery unreachable (owner renounced + no OApp counter reset) AND/OR (ii) stuck messages lock funds, OR the OApp is governance-critical |
| (c) official | **High** (windhustler checklist) + Drips/Cantina on BridgedGovernor | checklist grades the worst-case (governance-critical / unrecoverable) instance |

**Reconciliation:** B2 severity = **(recovery reachability) × (value of what is stuck).** Cheap owner recovery + non-critical payload → MED; unrecoverable + governance/funds stuck → High. The PoC proves recovery works (→ MED for the generic case); BridgedGovernor sits at the High end because **governance liveness itself is the asset.** This is the gate's *magnitude × recoverability* axis — the over-sell bait is "permanently bricked channel"; the cap is "recovery is privileged but it exists."

## Minimal vulnerable / canonical pattern

```solidity
// ORDERED OApp (opt-in). A nonce whose _lzReceive always reverts jams every later nonce.
function _acceptNonce(uint32 srcEid, bytes32 sender, uint64 nonce) internal {
    uint64 cur = maxReceivedNonce[srcEid][sender];
    if (orderedNonce) require(nonce == cur + 1, "OApp: invalid nonce");   // out-of-order rejected
    if (nonce > cur) maxReceivedNonce[srcEid][sender] = nonce;
}
function nextNonce(uint32 s, bytes32 p) public view override returns (uint64) {
    return orderedNonce ? maxReceivedNonce[s][p] + 1 : 0;
}
// SAFE recovery must bump BOTH layers — endpoint.skip ALONE does not unjam this OApp:
function skipInboundNonce(...) external onlyOwner {
    endpoint.skip(...);                 // advances ENDPOINT lazy nonce
    maxReceivedNonce[srcEid][sender]++; // advances the OApp's OWN counter  ← the part integrators forget
}
```
A Foundry PoC against the real core (EndpointV2 + MessagingChannel + ReceiveUln302/DVN) shows: (1) poison jams nonce 2 (`executedCount==0`, channel healthy); (2) `endpoint.clear(poison)` alone does NOT unjam (nonce 2 still `"OApp: invalid nonce"`); (3) `setOrderedNonce(false)` unjams (`executedCount==2`) ⇒ recoverable; (4) recovery is `onlyOwner`/`_assertAuthorized`.

## Required conditions

1. OApp opts into **ordered** delivery (`nextNonce` override / `OmniCounter`-style `_acceptNonce`).
2. Some nonce's `_lzReceive` can **revert deterministically** on attacker-influenceable content (poison payload, a sub-call that reverts, a state that never clears).
3. **Recovery is unreachable or incomplete** for the escalation: owner renounced, or the OApp keeps its own counter but lacks a recovery that resets it (endpoint `skip`/`clear` alone won't). → severity by recoverability × stuck value.

## Detection heuristic

- Is the OApp **ordered**? Look for a `nextNonce` override returning non-zero / an `_acceptNonce` with `require(nonce == cur+1)`. Unordered OApps (default) are immune — a revert only blocks that one message.
- Can `_lzReceive` revert on content the source/attacker influences? (decode that can throw, a downstream call, an assert).
- **Does the OApp have its own recovery that resets ITS counter** (not just `endpoint.skip`/`clear`)? If it keeps `maxReceivedNonce` but offers no `skipInboundNonce`-style reset, a jam is unrecoverable at the app layer → escalate.
- Is the owner/delegate live, or renounced/timelocked? Is the payload governance-critical or fund-locking? → sets the High-vs-MED point.
- Grep: `nextNonce`, `maxReceivedNonce`, `orderedNonce`, `_acceptNonce`, `skipInboundNonce`, `endpoint.skip`, `endpoint.clear`.

## Cross-reference

- [[severity-gate-funds-at-risk]] — the gate (this pattern adds the **magnitude × recoverability** axis: recoverable DoS = MED ceiling; the "bricked channel" naive call is the over-sell bait).
- [[hook-jit-donation-capture]] — sibling "naive HIGH → gate MED" DoS/MEV-class calibration (different mechanism, same over-sell shape).
- [[audit-block-and-consumers-after-finding]] — after spotting an ordered OApp, audit its recovery path AND every `_lzReceive` branch that can revert.
- Target notes: `knowledge/target-notes/layerzero-v2.md` §2 (channel/recovery) + §6 points 4-5 + §7 (B2).
- Loci @ pin `9c741e7`: channel `MessagingChannel._clearPayload:126` (`:137-139`, delete `:150`) / `_inbound:37` / `inboundNonce:54` / recovery `skip:82`/`nilify:95`/`burn:112`; `EndpointV2.clear:211` + `_assertAuthorized` (`EndpointV2:355`); OApp `OAppReceiver.nextNonce:78`; canonical `OmniCounterAbstract._acceptNonce:243`/`skipInboundNonce:264`.
