# Knowledge base

Reference material for the agent. The orchestrator and the hypothesis-agent use it in Phase 3 to
generate and calibrate hypotheses. Any change to this folder requires explicit user approval (see
`prompts/orchestrator.md` → "Binding rules").

The `[[name]]` references inside the files point to `<name>.md` in this same folder
(Obsidian style).

## Fundamentals

| File | Contents |
|---|---|
| `vulnerability-classes.md` | Vulnerability classes with real examples |
| `defi-patterns.md` | DeFi-specific patterns (lending, AMMs, vaults, stablecoins) |
| `mev-flashloan-patterns.md` | MEV and flashloan vectors |
| `wallet-infra-patterns.md` | Account abstraction, smart wallets, infrastructure |
| `historical-exploits.md` | Anatomy of the major historical exploits |
| `solodit-tags-cheatsheet.md` | How to search historical findings on Solodit |

## `patterns/` — distilled attack mechanisms

Each file: trigger condition, mechanism, severity (and what it depends on), detection heuristic and
public references.

| File | Family |
|---|---|
| `erc4626-totalassets-balanceof.md` | Vaults: `balanceOf`-based `totalAssets()` (donation / inflation) |
| `flashloan-repayment-balance-conflation.md` | Accounting: flashloan repayment validated by balance |
| `flashloan-arbitrary-call.md` | Arbitrary call as the protocol (flashloan callback) |
| `erc2771-multicall-sender-confusion.md` | Meta-tx: ERC2771 + multicall, `_msgSender()` spoofing |
| `governance-current-votes-flashloan.md` | Governance: voting power measured at the current block |
| `oracle-spot-price-amm-manipulation.md` | Oracles: manipulable AMM spot price |
| `single-sided-lp-v3-liquidity-inflation.md` | V3 AMMs: `liquidity()` inflated with single-sided LP |
| `mint-on-redeem-no-vault-balance-gate.md` | Accounting: protocols that mint collateral on redeem |
| `cross-chain-gmp-replay-defense.md` | Cross-chain: defensive checklist for message verification |
| `uniswap-v4-hooks/` | V4 hooks: missing `onlyPoolManager`, delta skim, JIT-donation, permission bits |
| `layerzero-v2/` | LayerZero V2: `lzCompose` origin, OFT precision, nonce jam in ordered delivery |
| `vyper/` | `@nonreentrant` codegen bug (Curve 2023): the compiler is in the TCB |
| `solana/` | Account validation on Solana (owner / signer / type / address) |

## `heuristics/` — severity and process rules

| File | When to use it |
|---|---|
| `severity-gate-funds-at-risk.md` | **Always** before labeling a finding HIGH/Critical |
| `severity-heuristic-high.md` | The HIGH rule, its counters and the trust-model downgrade |
| `audit-block-and-consumers-after-finding.md` | When closing a finding or a refutation in a region |
| `fork-behavior-divergence-checklist.md` | When the target integrates or is a fork of another protocol |
| `surgical-blindness-escalation.md` | Shadow audits: a hypothesis blocked by an upstream dependency |

## `target-notes/` — per-protocol notes

Line-by-line readings with `file:line` citations against a pinned commit, mechanisms, subtle points
and a bug-class → code map.

| File | Protocol |
|---|---|
| `uniswap-v4-hooks.md` | Uniswap V4 core + periphery (hooks) |
| `layerzero-v2.md` | LayerZero V2 (endpoint, DVN/Executor, OApp/OFT) |
| `erc4626-solmate.md` | Solmate's ERC4626 implementation |

## How it grows

When a hunt closes, the post-mortem (`templates/post-mortem.md`) proposes what to distill. With the
user's approval, each proposal becomes a new file or an extension of an existing one in the
corresponding folder.
