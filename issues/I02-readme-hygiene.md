# I02 — infra/readme.md hygiene cleanup

**Priority:** medium
**Size:** small
**File to change:** `infra/readme.md`
**Dependencies:** none
**Verification:** review rendered markdown on GitHub (or locally with a Markdown previewer) to confirm all sections read correctly and no stale instructions remain

---

## Summary

`infra/readme.md` contains several stale or incorrect sections that create confusion for operators following the runbook. This issue covers six targeted fixes: relocating the abandoned EFS section, two typos, a stale `maxRetries` reference, a resolved DB-path TODO, a vague "Untested" label, and an architecture diagram mismatch.

---

## Items to fix

### 1. EFS section — move to appendix (or delete)

**Location:** `infra/readme.md`, "### EFS volume (metaomics databases)" section (lines ~100–250), including subsections:
- "1. Create the EFS security group"
- "2. Create the EFS filesystem"
- "3. Create a mount target in each Batch subnet"
- "4. Record the filesystem ID"
- "5. Populate the databases"
- "Teardown" (EFS teardown commands)

**Problem:** The EFS approach was evaluated and abandoned. The chosen strategy is `aws s3 sync` in the EC2 Launch Template, which populates `/mnt/dbs` on each worker from S3 at boot. The EFS section is currently presented inline in "Part 1: First Time Setup" as if it is an active, required step. Operators following the runbook will waste time on commands that serve no purpose.

The file even contains an inline comment acknowledging this:
```
# EFS volume is unfinished. Instead, we run `aws s3 sync` in Launch Template
```
That comment is buried inside the section heading and easy to miss.

**Fix:** Either:
- **Option A (preferred):** Delete the entire EFS section. The `aws s3 sync` approach is fully wired in the CloudFormation Launch Template UserData; no supplementary instructions are needed.
- **Option B:** Move the EFS section to a clearly labelled appendix at the bottom of the file, e.g. `## Appendix: Abandoned approaches — EFS`, with a note explaining why it was not used and that it is retained for reference only.

The architecture diagram's `EFS: nf-reads-profiler-dbs` line (inside the ASCII diagram in "### Architecture") should also be removed if Option A is chosen, or marked `[NOT USED]` if Option B is chosen.

---

### 2. Typo — `dashbaord` → `dashboard`

**Location:** Line 8, in the introductory paragraph:

```
To see what's running right now, view [the dashbaord](https://...)
```

**Fix:**

```
To see what's running right now, view [the dashboard](https://...)
```

---

### 3. Typo — `deleation` → `deletion`

**Location:** Line 43, in the "# 3. Wait for deleation" comment inside the stack-teardown code block:

```bash
# 3. Wait for deleation
```

**Fix:**

```bash
# 3. Wait for deletion
```

---

### 4. Stale `maxRetries=3` reference

**Location:** Line 738, inside "### Untested: CloudWatch Alarms":

```
Spot interruptions are handled by `maxRetries=3` in `aws_batch.config` and do not trigger alarms.
```

**Problem:** `conf/aws_batch.config` sets `maxRetries = 0`. There are no retries on spot interruptions; the current policy is to log and skip failed samples rather than retry. The `maxRetries=3` value is stale and may have been from an earlier version of the config.

**Fix:** Replace the sentence with one that reflects the actual policy:

```
Spot interruptions are handled at the pipeline level (failed samples are logged and skipped);
`aws_batch.config` sets `maxRetries = 0` and `resourceLimits` caps memory to prevent runaway
retry storms.
```

---

### 5. Stale DB-path TODO

**Location:** Lines 469–483, "### Database paths" subsection under "## Run the Pipeline":

```
`nextflow.config` defaults point to local paths (`/dbs/omicsdata/...`).

TODO: Override with S3 URIs for AWS runs in the `aws_batch.config` file, or with the CLI:
```

**Problem:** This TODO is resolved. `conf/aws_batch.config` already sets all DB paths to `/mnt/dbs/...` (populated by the Launch Template `aws s3 sync`). The TODO and the example CLI block that follows it (showing `--direct_metaphlan_db s3://your-db-bucket/...`) describe a path that was never taken.

**Fix:** Replace the stale TODO block with a brief statement of the actual current approach:

```markdown
### Database paths

Database paths for AWS runs are set in `conf/aws_batch.config` and point to `/mnt/dbs/...`.
These paths are populated at worker boot time by `aws s3 sync` in the EC2 Launch Template
UserData — no manual override is needed for standard runs.
```

Remove the stale `nextflow.config` local-path reference and the entire `nextflow run main.nf ... --direct_metaphlan_db s3://...` CLI example block.

---

### 6. "Untested" block — clarify what has and hasn't been tested

**Location:** Line 697, the horizontal-rule separator:

```
# Untested from here down
```

**Problem:** The blanket label is coarse. After the label, the file contains:
- "### Untested: AWS Budgets" — still plausibly untested
- "### Untested: AWS Cost Explorer" — still plausibly untested
- "### CloudWatch Dashboard" — the `aws cloudformation describe-stacks` command to retrieve the dashboard URL appears to be part of the tested deploy flow (it's in the pre-run checklist); calling it "untested" is inconsistent
- "### Untested: CloudWatch Alarms" — still plausibly untested
- "### Untested: Live job logs" — the `aws logs tail` command is a standard CLI call; unclear what makes it untested
- "## Untested: Estimated Costs" — the cost table is an estimate, not a workflow; labelling it "untested" adds no information
- "## Untested: Importing an Existing Workdir Bucket" — the drift-recovery section already covers preserving the workdir bucket via `--retain-resources`; this section may be redundant

**Fix:** Replace the single blanket separator with per-section context. At minimum:
- Remove the "# Untested from here down" banner.
- On the CloudWatch Dashboard subsection, remove the "Untested" qualifier (or confirm it belongs there).
- On the Estimated Costs table, remove the "Untested" qualifier — estimates are not procedures that get tested; use "Estimated Costs" as the heading and add a note that figures are approximate 2025 Graviton spot pricing.
- For alarms, budgets, and live-log tail, add a brief parenthetical explaining *why* they are untested (e.g., "CloudWatch alarms were provisioned by the template but not triggered in testing") so operators know what to expect.
- Assess whether "Importing an Existing Workdir Bucket" is still needed given the `--retain-resources` drift-recovery path already in the file; remove it if redundant, or add a cross-reference if it covers a distinct scenario.

---

### 7. Architecture diagram — vCPU range mismatch

**Location:** Lines 82–84, inside the "### Architecture" ASCII diagram:

```
├─ Order 1: Spot Compute Environment  (SPOT_CAPACITY_OPTIMIZED)
│    └─ r8g/m8g/c8g (G4) + r7g/m7g (G3) + r6g/m6g (G2)  →  0–256 vCPU
└─ Order 2: On-Demand Compute Environment (automatic fallback)
     └─ r8g/m8g/r7g (Graviton)                            →  0–64 vCPU
```

**Problem:** The actual deploy command (lines 318–319) and the troubleshooting redeploy commands (lines 528–529, 668–669) all pass:

```
MaxvCPUsSpot=16
MaxvCPUsOnDemand=8
```

The diagram shows `0–256 vCPU` and `0–64 vCPU`, which were likely the CloudFormation parameter *defaults* or an earlier configuration, not the values actively in use.

**Fix:** Update the diagram to reflect the current deployed values:

```
├─ Order 1: Spot Compute Environment  (SPOT_CAPACITY_OPTIMIZED)
│    └─ r8g/m8g/c8g (G4) + r7g/m7g (G3) + r6g/m6g (G2)  →  0–16 vCPU (MaxvCPUsSpot)
└─ Order 2: On-Demand Compute Environment (automatic fallback)
     └─ r8g/m8g/r7g (Graviton)                            →  0–8 vCPU (MaxvCPUsOnDemand)
```

Adding the parameter name in parentheses makes it clear these are configurable values set at deploy time, not hard limits.

---

## Verification checklist

- [ ] Render `infra/readme.md` in GitHub (or a local Markdown previewer) and read through Part 0, Part 1, and Part 2 end-to-end
- [ ] Confirm EFS commands no longer appear in the active setup flow
- [ ] Confirm "dashboard" and "deletion" are spelled correctly in context
- [ ] Confirm `maxRetries` value cited in the alarms section matches `conf/aws_batch.config`
- [ ] Confirm the DB-path TODO is gone and the replacement text accurately describes the S3-sync approach
- [ ] Confirm "Untested from here down" banner is replaced with per-section context
- [ ] Confirm vCPU ranges in the architecture diagram match the `MaxvCPUsSpot=16` / `MaxvCPUsOnDemand=8` values used in all deploy commands
