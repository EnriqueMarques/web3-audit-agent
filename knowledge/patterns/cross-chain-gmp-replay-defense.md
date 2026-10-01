# Pattern (DEFENSIVE / positive reference): correct cross-chain GMP verification — replay guard

**Family:** cross-chain messaging (GMP / LayerZero / CCIP / notary consortium)
**Type:** DEFENSIVE reference — "what correct looks like", in order to detect its ABSENCE
**Reference example:** Lombard Finance — Consortium/Mailbox/AssetRouter (correct implementation)
**Cross-ref:** [[lzcompose-origin-not-validated]], [[oft-shared-decimals-precision]], [[flashloan-arbitrary-call]] (severity-by-custody), [[severity-gate-funds-at-risk]]

---

## What this card is for
The cross-chain attack cards say what fails. This one says **what a correct
verification looks like**, so that on the next cross-chain target you can quickly
spot *which piece is MISSING*. If all of these pieces are present, the
"message forgery/replay" seam folds (the Lombard case); if one is missing, that is where the bug is.

## The invariant of an authenticated cross-chain message
Execute the action (mint/unlock/release) iff: the message was **signed by the
configured verifier** (DVN quorum / notary consortium / CCIP), AND **it has not been
executed before**, AND **it was destined for THIS chain/handler**. All three dimensions
— authenticity, uniqueness, destination — must be bound to what was signed.

## The correct pieces (checklist; Lombard as the verified example)
1. **payload.id = hash(rawPayload) covers the full route.** `payload.id =
   sha256(rawPayload)` where rawPayload includes `msgPath` (origin+destination+nonce+
   sender+body). ⇒ mutating any field (destination, recipient, amount) changes the id and
   **breaks the signature**. (Typical absence: id = hash of only a subset → unsigned
   fields are manipulable.)
2. **Inbound path enabled by LOCAL chainId.** The handler requires
   `inboundMessagePath[msgPath] != 0` where the key is derived from `LChainId.get()`
   (the local chain), not from a field in the message. ⇒ a message for A replayed on
   B reverts because that path is not enabled on B. (Typical absence: validating the
   destination against a field of the message itself instead of against the local identity →
   cross-chain replay.)
3. **Spent guard per payload.id in EVERY handler, with CEI.** `usedPayloads[id]` /
   `payloadSpent[id]` checked and **set BEFORE** the external effect (mint).
   Each handler keeps its own. ⇒ same-chain replay reverts. (Absence: set
   after the mint, or a shared guard inconsistent across handlers → reentrancy /
   double spend.)
4. **Sender/origin authenticated, not assumed.** The handler requires
   `payload.msgSender == <expected module>` and `msg.sender == <mailbox/endpoint>`.
   (Connects with [[lzcompose-origin-not-validated]]: the composer must validate `_from`,
   not only that msg.sender == endpoint.)
5. **Signature without malleability + correct threshold.** `_checkProof` uses a recover
   that resists malleability (OZ `tryRecover` rejects high-s), a **positional** walk
   over signers with no double counting, and the correct threshold boundary (`>=` vs `>`).
6. **Explicit trust boundary.** Forgery-via-quorum (a malicious majority of notaries/DVNs)
   is usually declared TRUSTED/OUT. ⇒ in-scope = only the implementation BUG in 1-5,
   not the trust model.

## How to use it in a hunt
For the seam "can I forge/replay a cross-chain message?": walk 1-6 and look for
the missing or weak piece. If all six are there → it folds (don't waste a PoC; document it and
move to the next seam, OL-6). The value is in locating the ONE that is missing.

## Where I have seen it complete (correct)
- Lombard Finance: Consortium `_checkProof` + Mailbox `_deliver` (inboundMessagePath by
  local LChainId) + AssetRouter.handlePayload (onlyMailbox + msgSender==BTC_STAKING_MODULE +
  usedPayloads CEI). All 6 pieces present → the Critical forged-mint hypothesis was discarded.
