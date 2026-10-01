# Contest Workflow — Cantina / Sherlock / Code4rena

Flow for competitive contests with a deadline. Key differences vs Immunefi:

- **Fixed deadline** (typically 3-14 days)
- **You compete against other researchers** simultaneously
- **Severity is decided by the judge**, not negotiable as on Immunefi
- **Duplicates split the payout** (sometimes) or only the first one wins (other times)
- **Automatic public disclosure** after the contest

You optimize differently: speed + coverage, without losing depth. The perfect hypothesis not submitted in time is worth zero.

---

## Pre-contest (days before starting)

### Contest selection

Recommended filters:

- **Pool > $50k** (minimum decent ROI)
- **Duration 5-14 days** (shorter: you won't make it; longer: you burn out)
- **Protocol type within your expertise** (DeFi, MEV, AA, etc)
- **Few in-scope contracts** (< 2000 nSLOC) → you can do an exhaustive pass
- **Small/medium sponsor** → fewer top researchers competing

### Proactive watchlist

Follow:
- [Cantina competitions](https://cantina.xyz/competitions)
- [Sherlock contests](https://audits.sherlock.xyz/contests)
- [Code4rena contests](https://code4rena.com/audits)

Subscribe to the calendars. Good contests are announced 2-4 weeks in advance — use that time to study the protocol / domain if it is new to you.

### Pre-reading (mandatory before Day 1)

3-5 days before the start:
- The project's whitepaper
- Previous audit reports of the project (if any)
- Audit reports of similar protocols (if it is a Compound fork, read Compound's audits)
- Contest-specific documentation (the sponsor usually publishes the architecture)

If you arrive on Day 1 with no context, you lose 1-2 days understanding the protocol while others are already forming hypotheses.

---

## Day 1: Recon + Static + First round of hypotheses

**Target time:** 6-10 focused hours.

### Morning (3-4 h): Deep recon

```bash
# From the project root (web3-bounty-hunter/)
git clone <contest-repo> target/
cd target/
git checkout <commit-from-contest-page>
forge install
forge build
cd ..
mkdir -p findings/<slug>/{static,pocs,reports}
```

Launch the recon-agent. **Critical for contests:** identify the "**diff against previously audited code**". If the sponsor had a past audit, the new code is where the new bugs are:

```bash
# If you know the previous audit's commit (inside target/)
git diff <prev-audit-commit>..<contest-commit> -- 'src/*.sol'
```

The **changed sections** are where you concentrate 70% of the effort. Formalize it as a delta-map (OL-11): function by function, NEW / MODIFIED / REVIEWED.

### Afternoon (3-4 h): Static + first round of hypotheses

```bash
./tools/analyze.sh ./target ./findings/<slug>
```

Triage aggressively. Then, a first hypothesis-agent pass — not exhaustive yet, just "first impressions". Generate 5-10 tentative hypotheses.

### End of Day 1

`findings/<slug>/STATE.md`:
```
## Day 1 close
- Recon: completed
- Static triage: 8 surviving findings
- Tentative hypotheses: 7
- Top 3 prioritized: H1 (oracle), H4 (vault inflation), H7 (signature replay)
- Day 2 plan: dig into the top 3 + new hypotheses on [area X I didn't cover]
```

---

## Days 2-3: Deep dive + PoCs

**Loop:**
1. For each top hypothesis: attempt a PoC (time-boxed to 2-3 hours).
2. If it works: move on to another hypothesis (don't write the report yet).
3. If it fails within 2-3 hours: mark for review, keep going.
4. Every 4-5 hours: go back to the hypothesis-agent for new ideas with the knowledge acquired about the code.

**Contest-specific:** accumulate PoCs first, write reports at the end. This avoids writing reports for bugs you discover to be invalid on day 4.

### Systematic coverage (at the end of Day 3)

Up to here you were depth-first. At the end of Day 3, make sure you touched:
- [ ] Every in-scope contract (at least a surface read)
- [ ] Every external integration (see `findings/<slug>/integrations.md`)
- [ ] Admin/owner functions (they tend to have subtle bugs)
- [ ] Critical math/arithmetic (rounding, precision)
- [ ] Obvious edge cases (amount=0, totalSupply=0, etc)

If there are untouched areas, schedule them for Day 4.

---

## Days 4-5 (in 5-7 day contests): Validation + Reports

### Final validation

For each working PoC:

- [ ] Does it run cleanly on a fresh clone?
- [ ] Quantified outputs (USD, tokens, affected users)?
- [ ] Is it atomic or does it require an unrealistic setup?
- [ ] Does it fit the severity class you will claim?

Kill the PoCs that don't survive validation. **Don't report weak bugs** — they lower your reputation with judges for future contests.

### Report writing

For Sherlock: use `templates/sherlock-report.md`. **Quote the Sherlock judging rules exactly.**
For Cantina: use `templates/cantina-report.md`.
For C4: similar to Sherlock but with its own format.

**Contest-specific:** judges read 100+ reports in a few days. Your report competes for their attention.
- A specific title that sells
- A 3-line summary that decides whether they read the rest
- Severity justified with an exact quote of the rules
- PoC executable with 1 command

### Submission timing

Submitting at the end of the contest (last day), NOT the first, avoids others copying your finding (some contests have visible submissions). But DON'T wait until the last minute — bugs in the submission platform happen.

Recommendation: submit 2-4 hours before the deadline.

---

## Platform specifics

### Sherlock

- **Strict severity.** Typically only High/Medium pay. Lows build reputation but no $.
- **Public judging rules:** Always read them. https://docs.sherlock.xyz/audits/judging/judging
- **Watson tier system:** Your reputation affects payouts. Better 1 high than 5 dubious mediums.
- **Rigid issue templates.** If you don't follow the structure, automatic downgrade.

### Cantina

- **More flexibility** in format.
- **Severity tiers similar** to Immunefi.
- **Time-bounded judging** — disputes resolved within short deadlines.

### Code4rena

- **Pool split among researchers** (HM pool, QA pool, gas pool).
- **Very high quality bar** — judges are aggressive with downgrades.
- **Sherlock-style strictness** in following the rules.

---

## Tactical tips for contests

### The "obvious" bug

When you see something that looks like an obvious bug, **two possibilities**:
1. It is an obvious bug that many will report → submit anyway but don't spend much time on it.
2. It is NOT a bug because there is a protection you didn't see → re-read it 3 times before submitting.

### The "duplicate" report

In contests with many participants, high-severity bugs **tend to be found by multiple researchers**. It doesn't matter — submit anyway; duplicates split the payout but you still earn something.

What DOES matter: **finding the bug NOBODY else found**. That pays 10x more. That's why "depth" is priority #1: exotic vulns are not found by 20 hunters.

### When you doubt a bug

> "Is this really exploitable, or will the sponsor say it's expected behavior?"

Submit with a disclaimer in the report:
> "If the protocol intentionally allows X, this report is informational. However, given the documented invariant Y in [docs link], the behavior is unexpected."

This protects you if it is invalid (it doesn't hurt your reputation as much) but gives you the upside if it is valid.

### When the sponsor lists "Known Issues"

Read the contest's "Known Issues" section **before starting**. It is what you must NOT report. Reporting known issues = a wasted submission slot.

---

## Contest time budget (5 days)

| Day | Hours | Focus |
|-----|-------|-------|
| Pre-contest | 5-10 h | Pre-reading |
| Day 1 | 8-10 h | Recon + first hypotheses |
| Day 2 | 8-10 h | PoCs top 3 hypotheses |
| Day 3 | 8-10 h | More hypotheses + PoCs |
| Day 4 | 6-8 h | Coverage gaps + validations |
| Day 5 | 6-8 h | Reports + submission |
| **Total** | **41-56 h** | |

For 7-day contests: distribute similarly but with more buffer on Days 4-5.
For 14-day contests: add an "investigation week" between Day 5 (validation) and the reports.

---

## Post-contest

The post-mortem is **especially valuable in contests** because you can read:

1. **The official winners' report** (published after 1-2 weeks)
2. **Findings you didn't find** — which hypotheses you missed
3. **Findings you reported that were invalid** — why

Document it in `findings/<slug>/post-mortem.md` (`templates/post-mortem.md`), with the comparison against the official report. This is **the densest learning material available** — it is like auditing the same target twice (the first time on your own, the second with the answers from the top researchers).

After 5-10 contests with a rigorous post-mortem, your speed and depth will improve dramatically.
