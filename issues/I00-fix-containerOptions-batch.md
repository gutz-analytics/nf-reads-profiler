# I00: Fix unescaped `containerOptions` shell expansion in `community_characterisation.nf`

**Priority:** BLOCKER — must be resolved before any AWS Batch run succeeds
**Size:** Small (two-line fix; optional follow-on refactor is slightly larger)
**Dependencies:** None — this blocks every downstream issue

---

## Problem

Two processes in `modules/community_characterisation.nf` set:

```groovy
containerOptions '-u $(id -u):$(id -g)'
```

AWS Batch does **not** evaluate shell variable expansions inside
`containerOptions`. The string is forwarded verbatim to the ECS container
override, so Batch receives the literal token `$(id` as the user value. The
Batch API rejects it because it does not match the required regex
`^([a-z0-9_][a-z0-9_-]{0,30})$`.

The run fails immediately at job submission with an error resembling:

```
ClientException: Error executing request, Exception : User '$(id' does not match regex
```

Reference: https://github.com/nextflow-io/nextflow/discussions/2900

### Affected lines

| Process | File | Line |
|---|---|---|
| `profile_function` | `modules/community_characterisation.nf` | 67 |
| `combine_humann_tables` | `modules/community_characterisation.nf` | 117 |

Both lines read:

```groovy
containerOptions '-u $(id -u):$(id -g)'
```

### What is already correct

Three other processes in the same file already use the escaped form and work
correctly on AWS Batch:

| Process | Line |
|---|---|
| `convert_tables_to_biom` | 235 |
| `split_stratified_tables` | 272 |
| `regroup_genefamilies` | 305 |

All three use:

```groovy
containerOptions '-u \$(id -u):\$(id -g)'
```

The backslash causes Nextflow to pass the `$` character through to the Docker
CLI rather than expanding it as a Groovy/shell expression before the string
reaches AWS Batch.

---

## Fix

### Option A — Escape `$` (minimal, mirrors existing pattern)

Change lines 67 and 117 from:

```groovy
containerOptions '-u $(id -u):$(id -g)'
```

to:

```groovy
containerOptions '-u \$(id -u):\$(id -g)'
```

This is a two-character change per line and is consistent with the three
processes that are already correct.

### Option B — Gate on container engine (recommended follow-on)

The `-u $(id -u):$(id -g)` flag exists so that files written inside the
container on a local Linux host are owned by the calling user rather than
`root`. On AWS Batch, ECS task roles and the Batch-managed ECS agent handle
permissions differently; the flag is not needed and actively breaks submission.

A cleaner solution removes the Batch-specific failure mode and documents the
intent:

```groovy
// Local Docker: match host UID/GID so output files are not owned by root.
// AWS Batch / ECS: omit — task role permissions are managed by IAM; passing
// a host UID is meaningless and rejected by the Batch API.
containerOptions workflow.containerEngine == 'docker' ? '-u $(id -u):$(id -g)' : ''
```

If Option B is adopted, apply it consistently to all five `containerOptions`
lines in the file (lines 67, 117, 235, 272, 305) so the behaviour is uniform.

---

## Files to change

```
modules/community_characterisation.nf
  line  67  – process profile_function
  line 117  – process combine_humann_tables
```

If adopting Option B, also update:

```
modules/community_characterisation.nf
  line 235  – process convert_tables_to_biom
  line 272  – process split_stratified_tables
  line 305  – process regroup_genefamilies
```

---

## Verification

1. Apply the fix (Option A or B).
2. Submit a test run to AWS Batch using a small samplesheet:

   ```bash
   nextflow run main.nf -profile aws \
     --input s3://gutz-nf-reads-profilers-runs/samplesheets/<test>.csv \
     --project test-I00
   ```

3. Confirm that the `profile_function` and `combine_humann_tables` jobs reach
   `RUNNING` state in the Batch console without a `ClientException` on user
   validation.
4. Check that output TSVs appear under
   `outdir/<project>/<run>/function/` as expected.

---

## Background

The `-u $(id -u):$(id -g)` pattern is a common local-Docker convenience. When
Nextflow evaluates a `containerOptions` string it passes it as a Groovy GString.
With unescaped `$`, the expression is evaluated at workflow startup (returning
the Nextflow runner's UID/GID on the local machine). On local Docker this
works because the runner and the worker share the same host. On AWS Batch the
resulting numeric string is compared against the Batch user-name regex before
the job ever starts, and any value that does not look like a Unix username
causes an immediate `ClientException`.

Escaping `$` to `\$` defers evaluation to the Docker CLI layer, which handles
`$(id -u)` correctly inside a Docker `--user` flag when run locally, and on
Batch the escaped form is passed through as-is — but the correct fix for Batch
is to omit the flag entirely (Option B), since ECS/Batch manages user context
through the task definition and IAM role.
