# Immunefi Workflow — End-to-end

Complete operational flow for hunting on Immunefi (live bounties, production code). Use this document as an executable playbook. The phases follow the canonical numbering of `prompts/methodology.md`; only what is specific to Immunefi is detailed here.

---

## Pre-flight (before starting on the target)

### 1. Target selection (15 min)

Open [immunefi.com/explore](https://immunefi.com/explore) and filter:

- **Total bounty pool > $1M** (ensures critical pays at least $50k)
- **Program published < 6 months ago** (fewer accumulated hunters)
- **Codebase with recent commits** in public repos (new bugs)
- **TVL > $50M** (real reportable impact)

For each candidate, check on its Immunefi page:

- [ ] Severity table (critical = ?, high = ?)
- [ ] List of in-scope assets (deployed contracts)
- [ ] List of in-scope impacts (do they pay for oracle manipulation? logic bugs? only direct theft?)
- [ ] Out-of-scope (read carefully — many programs exclude flashloan attacks or griefing)
- [ ] KYC requirements (some don't pay anonymous researchers)
- [ ] Visible disclosure history — if there are 20 recent reports, it is saturated

**Red flags that kill the target:**
- In-scope list with addresses that are no longer active (the project migrated)
- Out-of-scope includes "anything related to oracle manipulation" → your main hypothesis is out
- The bounty pays in the project's own native token (devaluation risk)
- Last program update > 1 year ago ("ghost" program)

### 2. Environment setup (30 min)

```bash
# From the project root (web3-bounty-hunter/)
# Clone ONLY the in-scope code
# (some programs have 50 repos but only 3 are in scope)
git clone <main-repo> target/
cd target/
git checkout <commit-hash-from-immunefi-page>

# Verify the build
forge install
forge build
cd ..

# Hunt directory
mkdir -p findings/<slug>/{static,pocs,reports}

# If it doesn't compile → stop immediately. Ask in the project's Discord
# before burning time debugging compilation issues that may be your own.
```

If the Immunefi page lists a specific commit hash, use **exactly that one**. Not `main`. It is the code they are committed to paying for.

### 3. Initial reading of the program (1 hour)

Before touching code:

- **Read the project's whitepaper / docs** (1× in full).
- **Read 2-3 previous audit reports** (Spearbit, Cyfrin, Trail of Bits, etc). The complete inventory comes from three sources: the git repo, the project's website and the Immunefi program page (OL-11).
- **Read the disclosure history** of the Immunefi program.
- **Read the project's Twitter** for the last 3 months — they sometimes announce fixes.
- **Look the project up on rekt.news** — have they already been hacked? What did they learn?

Output: a context section in `findings/<slug>/STATE.md` summarizing:
- What the protocol does
- Current TVL
- Previous audits and their main findings
- Already-patched bugs (don't report them)
- Areas the previous audits did NOT cover well

---

## Phase 1: Recon (1-2 hours)

Launch `subagents/recon-agent.md`. Expected output: `findings/<slug>/recon-report.md`.

**Immunefi-specific:** during recon, tag each contract with its mainnet address (in-scope list). This is critical because some PoCs require a fork with those exact addresses.

```bash
# If the project is deployed, this is also useful:
cast code <contract-address> --rpc-url $MAINNET_RPC > deployed-bytecode.txt
forge inspect <ContractName> bytecode > local-bytecode.txt
diff deployed-bytecode.txt local-bytecode.txt
```

If the local bytecode differs from the deployed one, the code you have is NOT what is in production. Verify the commit hash.

---

## Phase 2: Static sweep (15 min)

```bash
./tools/analyze.sh ./target ./findings/<slug>
```

Launch `subagents/static-sweep-agent.md` to triage the output.

**Immunefi-specific:** generic detectors almost never find paying bugs in active programs — all the obvious bugs have already been reported or patched. But run the sweep anyway: whatever survives is input for hypotheses, not final output.

---

## Phase 3: Hypothesis generation (4-8 hours)

**This is the phase that defines the outcome.** Launch `subagents/hypothesis-agent.md`.

### Immunefi-specific: prioritization by real bounty

Compute the potential bounty per hypothesis:

```
Estimated bounty = critical_payout (or high_payout) × P(judges accept severity)
                   × P(not a duplicate)
                   − (PoC_effort × your_hourly_rate)
```

Only PoC the top 3-5. The rest, mark for post-bounty investigation.

### Immunefi-specific: the "first report" bonus

Immunefi pays the **first valid report**. If you see a recent disclosure of a similar bug (days ago), consider your window closed — move on to another hypothesis.

---

## Phase 4: PoC development (2-6 hours per hypothesis)

Launch `subagents/exploit-dev-agent.md`.

### Immunefi-specific: mainnet fork PoC is MANDATORY

The judges want to see the exploit running against real state:

```solidity
function setUp() public {
    vm.createSelectFork(vm.envString("MAINNET_RPC"), 19_500_000);
    target = ITargetContract(0x<deployed-address>);
}
```

PoCs on fresh deployments are accepted but **always downgraded in severity** — the judge reasons "does this happen in real production?". A fork proves that it does.

### Mandatory financial quantification

The report must have concrete numbers:
- "Vault holds $4.2M USDC at block 19500000"
- "Attacker extracts $4.18M in one transaction"
- "Attack cost: ~0.5 ETH gas + $5k flashloan fee"
- "Net profit: $4.17M"

Without these numbers, the judge cannot reliably assign critical.

Funds are read on-chain from the fork, not from the program's table, and only **user** funds count (OL-7): a pool whose capital belongs to the team itself, or that is closed by a whitelist, has no user funds even if it holds millions.

---

## Phase L-A: Exhaustive duplicate check (1 hour)

**Report nothing without this.** The #1 rejection reason on Immunefi is duplicates.

### Duplicate check checklist

- [ ] **Immunefi program disclosure history** — read EVERY past disclosure, not just the titles
- [ ] **The project's GitHub commits** — `git log --since="6 months ago" -- src/<vulnerable-file>.sol`
- [ ] **Repo issues** (including closed ones) — search for terms related to your bug
- [ ] **Twitter of the project + contributors** for the last 90 days
- [ ] **Solodit search** for the project + category
- [ ] **Search on C4 / Sherlock / Cantina** — maybe it was reported in a contest
- [ ] **rekt.news** — an attack already executed but not publicized?
- [ ] **The project's Discord/Telegram** — recent technical announcements

If you find an exact match: discard.
If you find a partial match: document the explicit difference in the report.
If nothing related: proceed with confidence.

---

## Phase L-B: Report drafting (2-4 hours)

Launch `subagents/reporter-agent.md` with `templates/immunefi-report.md`.

### Immunefi-specific: severity classification system

Immunefi uses the [v2.3 classification](https://immunefi.com/immunefi-vulnerability-severity-classification-system-v2-3/). **Quote exactly** the category that applies:

- "Direct theft of any user funds, whether at-rest or in-motion" → Critical
- "Permanent freezing of funds" → Critical (sometimes High)
- "Theft of unclaimed yield" → High
- "Smart contract unable to operate due to lack of token funds" → Medium

If your impact does not clearly fit a category, lay out **why it fits** with arguments from the real impact.

### Common mistakes that lower severity

- **Not quantifying funds at risk** → the judge assumes the worst case is low
- **Treating exploit steps as "obvious"** → the judge doesn't fill in the blanks
- **PoC on a fresh deployment** → "is this realistic in production?"
- **Frontend dependencies** → "does the bug exist without a cooperating frontend?"
- **Multi-step with unlikely conditions** → low likelihood

---

## Phase L-C: Submission

### Before submitting

- [ ] Read the full report out loud
- [ ] Ask a colleague (if you have one) to read it
- [ ] Verify the PoC runs fresh (clone into another directory, run it)
- [ ] Your Immunefi KYC is up to date
- [ ] Payment wallet configured

### Submission process

1. Log in to immunefi.com
2. Select the program
3. "Submit Bug" → fill in the form
4. **Attach the full report as markdown** + the PoC as a ZIP or a link to a private GitHub repo
5. Be specific in the submission title
6. **DO NOT post on Twitter or tell anyone** until the bug is paid and disclosed

### After submitting

Immunefi has a response SLA:
- Acknowledgment: 1-2 days
- Triaging: 5-14 days typically
- Resolution: 2-8 weeks (depends on the project)

**Keep the conversation professional.** If they ask for additional info, respond quickly and clearly. If they disagree on severity, argue with data (not emotionally).

### If the severity is disputed

It is common. The project will want to pay Medium where you reported Critical. Your argument must be:
1. An exact quote from the classification system
2. Concrete numbers from the PoC
3. Similar historical findings with that severity
4. (Optional) Escalation to an Immunefi mediator if the disagreement is serious

---

## Post-submission

### If paid

1. Document the whole process in `findings/<slug>/post-mortem.md` (`templates/post-mortem.md`)
2. **Ask for permission for public disclosure** (some programs allow it, others don't). Without permission, the report's content does not leave your machine.
3. If they allow it: write a blog post / Twitter thread (this builds your reputation → future bounties get easier)
4. Propose the pattern for `knowledge/patterns/` (written with the user's approval)

### If rejected or duplicate

1. Document the lesson in `findings/<slug>/post-mortem.md` (`templates/post-mortem.md`):
   - Which hypothesis you had
   - Why it was invalid or a duplicate
   - Which signal would have saved you the time
2. **Don't take the rejection personally.** Bounty hunting has a normal 60-80% rejection rate. What matters is the ratio of criticals / hours worked.

---

## Total Immunefi time budget

| Phase | Time |
|-------|------|
| Selection + setup | 1.5 h |
| Reading docs/audits | 1 h |
| Recon | 1-2 h |
| Static sweep | 0.25 h |
| Hypothesis | 4-8 h |
| PoC (3 hypotheses) | 6-15 h |
| Duplicate check | 1 h |
| Report | 2-4 h |
| Submit + follow-up | 1 h |
| **Total** | **17.75 - 33.75 h** |

For a serious target. If you find nothing during hypotheses → abort and move on to the next target. **Don't force it.**
