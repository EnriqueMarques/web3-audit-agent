# Refutation Anti-patterns (AP-check)

Three forms of **invalid** refutation that nearly cost real findings. Binding rule (see
`prompts/orchestrator.md`): before marking a hypothesis as REFUTED, the refutation is checked against
AP-1, AP-2 and AP-3, with a written justification of why it fits none of them. If it fits any of
them, it is not refuted: dig deeper.

---

## AP-1: "The test environment doesn't allow X" (refutation due to a tooling limitation)

**Example (Damn Vulnerable DeFi — Unstoppable):** hypothesis about the expiry of a grace period.
Wrong refutation: *"we can't advance time past `end` in the test environment, so the hypothesis is
not actionable"*.

**Why it is invalid:**
1. `vm.warp()` in Foundry lets you advance timestamps freely.
2. Even if you couldn't, the bug would live in production, where time really does advance.
   Test limitation ≠ the bug does not exist.

**A correct refutation shows that:**
- the bug does NOT happen IN PRODUCTION, not just in the test; or
- even if it happens, it does not produce exploitable economic damage.

**Alarm signal:** the refutation mentions "test environment", "current setup" or "initial state set
by the test".

---

## AP-2: "There is a partial mitigation" (refutation due to partial protection)

**Example (Damn Vulnerable DeFi — Unstoppable):** recursive callback hypothesis. Wrong refutation:
*"the vault is paused at the start of the callback, which prevents recursion"*.

**Why it is invalid:** the nested revert can be caught with `try/catch`. The attacker can wrap the
call in their own contract, catch the propagating revert and control the error flow. The
"self-mitigation" does not apply if whoever receives the revert is an attacker contract.

**A correct refutation considers:**
- Can the attacker catch the revert with `try/catch`?
- Are there alternative paths where the mitigation does not apply?
- Does the mitigation cover ALL scenarios or only the obvious adversarial path?

**Alarm signal:** the refutation says "the revert prevents X". Ask: who receives that revert?

---

## AP-3: "Low severity in this specific case" (severity by context isolation)

**Example (Damn Vulnerable DeFi — Unstoppable):** rounding in `convertToShares` classified as
Medium because "it only extracts 1 wei per iteration".

**Why it is invalid:** in production, repeated extraction of dust via automated flashloans is an
established vector. What looks like "1 wei" in a challenge can be a Critical drain with thousands of
atomic iterations.

**A correct severity assessment:**
1. Computes the aggregate impact in a realistic production scenario.
2. Considers atomicity: can N iterations be chained in one transaction?
3. Considers an economic adversary with unlimited flashloans and bots (Pattern 2 of
   `reasoning-patterns.md`).
4. **Measures the error in the domain where the truncation happens.** "Dust" computed in the
   domain of the result (e.g. Q64) can be an error of tens of percent in the domain where the
   `floor` falls (e.g. a price with 8 decimals). Compute `ulp/value` in THAT domain, with the most
   unfavorable pair/price in scope, and record the domain in the verdict. A dust verdict without
   an explicit domain does not count as a refutation. See OL-14.

**Alarm signal:** a hypothesis is discarded because "the damage is 1 wei" or "it only loses dust".
