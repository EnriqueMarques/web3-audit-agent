# Pattern: On Solana the runtime does NOT authenticate accounts for you — validate owner / signer / type / address on EVERY account (Sealevel Attacks)

**Family:** access control / authentication — account-model validation (the Solana port of "who is the caller, and is this the right object?")
**References:** a canonical class (Neodyme's "Sealevel Attacks" taxonomy), recurrent in nearly every Solana audit; the Wormhole incident (Feb 2022, ~$325M — a forged account passed to a Solana program).
**Severity when present:** = severity of what the un-validated handler controls, **BY CUSTODY** of the account it mutates. Drains/spoofs a custodial vault or token account ⇒ Critical/High; touches only stateless/non-custodial state ⇒ capped. The missing check is the *enabler*, not the grade — run [[severity-gate-funds-at-risk]]. (Canonical instances drain token vaults ⇒ historically High/Critical.)
**Detection by Slither/Aderyn:** N/A — those are EVM/AST tools and do not read Rust/Solana. The defect is the ABSENCE of a constraint, so the primary detector is human review (raw `AccountInfo`/`UncheckedAccount` + missing owner/signer/has_one), reinforced by Anchor's typed constraints and Solana-specific scanners (Sec3 X-Ray/Soteria, L3X). No EVM static analyzer applies.
**Solodit tags:** solana, account-confusion, owner-check, signer-check, type-confusion, discriminator, missing-validation, anchor, sealevel, wormhole

---

## Core mechanism (the mental model an EVM mind is missing)

On the **EVM** the runtime authenticates the world for you: `msg.sender` is the
cryptographically-verified caller, and a contract's identity + storage are bound
to its address by the protocol. You rarely ask "is this really the account I
think it is?" — the VM already answered it.

On **Solana** the runtime authenticates much LESS. A program receives a *list of
accounts* the caller chose to pass, and the runtime guarantees only a few
low-level facts about each:

| Field | Runtime guarantee (ground truth, un-forgeable) | Program's job |
|-------|-----------------------------------------------|---------------|
| `owner`     | only the owning program may mutate the account's data / debit its lamports | **read & compare** (is it owned by who I expect — SPL Token? my program?) |
| `is_signer` | true iff this key signed the tx | **read** (did the authority actually sign?) |
| `key`       | the account's real address | **compare** to the expected address (PDA / `has_one`) |
| `data`      | opaque bytes | **check a type discriminator** before trusting the layout |

The runtime does **not** tell the program "this is the right account / the SPL
token account / my own state account." THAT is the program's job, on EVERY
account, every instruction. Forget one and an attacker substitutes an account
**they fully control** — they OWN it, so they wrote its bytes — where the
program expected a trusted one. The program deserializes attacker-chosen data as
an authentic struct (authority = attacker, balance = huge) and acts on it.

The canonical axes (Neodyme "Sealevel Attacks"):
- **Missing owner check** → *account substitution / type confusion*: pass a
  look-alike account owned by someone else (or a different type owned by the
  same program, e.g. a Mint where a TokenAccount is expected). The discriminator
  / owner would have caught it.
- **Missing signer check** → *authority spoofing*: NAME the victim's pubkey as
  the "authority" without making them sign. Naming a key is free; only
  `is_signer` proves authorization.
- **Missing address / `has_one` check** → wrong-but-valid account of the right type.
- **Arbitrary CPI** → invoke a program supplied by the attacker instead of the
  expected one.

**Real-incident anchor — Wormhole, Feb-2022 (~$325M).** The Solana bridge
program verified signatures via an instructions-sysvar account it did **not
validate** (deprecated `load_instruction_at`, no address/owner check), so the
attacker passed a **forged account** and produced a "verified signatures" set
that was never signed → minted 120k wETH unbacked. Squarely a missing
account-validation (address/owner) bug — the most expensive instance of this
class.

## Replicated PoC (the model, runnable)

Reproduction (not included in this repo): a plain-Rust
model of the SVM's account guarantees (no external crates). `src/lib.rs` exposes
`withdraw_vulnerable` (checks only a logical `stored authority == passed key`)
and `withdraw_hardened` (validates **owner → discriminator → has_one → signer**,
i.e. what Anchor's `Account<'_,T>` / `Signer<'_>` / `has_one` generate). `cargo
test` → **5 PASS** (CARGO_EXIT=0):

- `..._missing_owner_check` — attacker fabricates a vault account they own
  (`owner = ATTACKER`, balance forged) → vulnerable handler releases funds.
  Hardened → `IncorrectOwner`.
- `..._missing_signer...` — real Alice vault; attacker NAMES Alice as authority
  with `is_signer = false` → vulnerable handler spends her funds. Hardened →
  `MissingRequiredSignature`.
- happy-path → hardened allows the legit owner+signer.

The fields `owner`/`is_signer`/`key` are written as loader-set GROUND TRUTH the
program cannot forge but the vulnerable handler simply never consults — that
forgetting IS the bug class. (Honest scope: this models the runtime guarantees
rather than running `solana-program-test`/`litesvm` — the SBF toolchain isn't
installed, and making the guarantee boundary *explicit* is stronger for a
mental-model deliverable than hiding it in a framework; cf. B-Vyper compile-diff
over fork. README has the full AP-1.)

## Minimal vulnerable pattern (the shape to grep for)

```rust
// raw handler over AccountInfo / UncheckedAccount — NO constraints
pub fn withdraw(vault: &AccountInfo, authority: &AccountInfo, amount: u64) {
    let state = VaultState::deserialize(&vault.data);   // (no discriminator check)
    require(state.authority == *authority.key);          // logical check only
    // MISSING: vault.owner == program_id   (account substitution / type confusion)
    // MISSING: authority.is_signer          (authority spoofing)
    // MISSING: vault.key == expected_pda    (wrong-but-valid account)
    pay_out(state, amount);
}
```
In **Anchor**, the equivalent danger sign is `AccountInfo<'info>` /
`UncheckedAccount<'info>` (or `#[account(...)]` without `has_one`/`constraint`/
`owner`) instead of typed `Account<'info, T>` + `Signer<'info>` + `has_one`.

## The transferable lesson (the headline, not the Solana trivia)

**When you leave the EVM, re-derive what the runtime authenticates for you —
because it's less.** EVM intuition silently assumes the platform verified the
caller and bound identity to address. Solana verifies almost nothing about
*which* account you got: it hands you what the caller chose and guarantees only
`owner`/`is_signer`/`key` truthfulness and raw bytes. **Every account is
attacker-influenced until the program proves otherwise** — validate owner,
signer, type (discriminator), and address on each one. "The account says it's
the vault" is a claim by whoever passed it; only the four checks make it a fact.
(Generalizes to any non-EVM target: ask "what does THIS runtime authenticate,
and what must I check myself?" before reusing EVM habits.)

## Required conditions

1. A handler reads or mutates state/funds based on an account it was passed.
2. It trusts that account's data/identity without validating one of: **owner**,
   **signer**, **type/discriminator**, **address (PDA/has_one)**.
3. A reachable instruction where an attacker controls which accounts are passed
   (almost always — accounts are caller-chosen) and can supply one they own.

## Detection heuristic

- **Inventory every account a handler reads/writes; for each, find the four
  checks.** Missing owner → substitution/type-confusion; missing signer →
  authority spoof; missing address/`has_one` → wrong-but-valid; attacker-supplied
  program id → arbitrary CPI.
- **Grep the danger surface:** raw `AccountInfo` / `UncheckedAccount`; manual
  `try_from_slice` / `*_unchecked` deserialization without a discriminator
  guard; `#[account(...)]` lacking `has_one` / `constraint` / `owner`; CPI whose
  target program is read from an account instead of pinned.
- **Recover the trust map first** (which program owns each account, who must
  sign), then verify the code consults it — the EVM-trained reviewer's default
  ("the VM checked the caller") is the failure mode to suppress.
- EVM static analyzers (Slither/Aderyn) do not apply; lean on Anchor's typed
  constraints, Solana scanners (Sec3/Soteria, L3X), and manual review.

## Cross-reference

- [[severity-gate-funds-at-risk]] — the missing check inherits the severity of
  what the handler controls BY CUSTODY (custodial vault/token account ⇒
  Critical; stateless ⇒ capped). The bug is the enabler, not the grade.
- [[lzcompose-origin-not-validated]] — the EVM sibling in the SAME conceptual
  family: don't assume the caller/origin is who it claims. There, `lzCompose`
  trusts a composed message's origin without validating it; here, a handler
  trusts an account without validating owner/signer. "Authenticate the
  counterparty yourself" is the shared invariant.
- [[vyper-nonreentrant-codegen-source-vs-bytecode]] — sibling Part-B lesson:
  both are "porting EVM assumptions to a non-Solidity target breaks silently" —
  there the compiler (TCB) doesn't emit the guard you read; here the runtime
  doesn't authenticate the account you assumed. Re-derive the platform's
  guarantees per language.
- [[flashloan-arbitrary-call]] — EVM cousin on the *other* side of identity:
  there an attacker makes a trusted contract act AS itself on attacker calldata;
  here an attacker makes a program treat an attacker account AS trusted. Both
  collapse an unverified identity assumption.
- Anchor `#[account(...)]` constraints (`Account<'_,T>`, `Signer<'_>`,
  `has_one`, `owner`, `seeds`/`bump`) are the framework-level discharge of this
  checklist; raw `AccountInfo`/`UncheckedAccount` opt out of all of it.
- Incident anchor: Wormhole Feb-2022 (~$325M). Taxonomy:
  Neodyme "Sealevel Attacks".
