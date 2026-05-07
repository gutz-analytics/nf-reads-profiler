# I15 — Remove `DbSourceBucket` parameter from the Batch stack

## Status

**SCOPE-NARROWED — 2026-04-28.** The bucket `cjb-gutz-s3-demo` is needed
in two distinct places, and its content footprint shrinks after I21
lands. Updated mapping:

| Where bucket is referenced | Status | Action |
|---|---|---|
| `infra/packer/worker-ami.pkr.hcl` (s3 sync of HUMAnN DBs at AMI build time) | **STILL REQUIRED** — chocophlan, full_mapping, uniref90 still come from this bucket | KEEP. Out of scope for I15. |
| `infra/batch-stack.yaml` `DbSourceBucket` parameter + `EcsInstanceRole.S3Access` IAM grant | **UNUSED at runtime** after I14 baked DBs into AMI; only theoretical MEDI use remains, and MEDI on AWS is broken regardless | **REMOVE** — this is what I15 does. |
| `infra/readme.md`, `issues/I10-production-playbook.md`, `.claude/agents/batch-doctor.md` | Documentation referencing the runtime parameter | UPDATE. |

So I15 reduces to: **drop the runtime IAM grant and stack parameter.
Leave Packer alone.**

### Bucket content shrinks too (after I21)

I21 switches MetaPhlAn DBs to the official biobakery source via
`metaphlan --install`, removing them from the Packer s3 sync. After
that lands, `s3://cjb-gutz-s3-demo/metaphlan_databases/` (~54 GB) is
orphaned and can be deleted from the bucket — saves storage cost and
removes our copy of canonical data we don't need to maintain.

| Bucket prefix | Used at AMI build time? | Used at runtime? | Action |
|---|---|---|---|
| `chocophlan_v4_alpha/` | yes (Packer) | no | Keep in bucket |
| `full_mapping_v4_alpha/` | yes (Packer) | no | Keep in bucket |
| `uniref90_..._filtered/` | yes (Packer) | no | Keep in bucket |
| `metaphlan_databases/` | **no** (after I21) | no | **Delete after I21 lands** |
| `referencedata/medi_db/` | no (not currently baked) | no (MEDI broken) | Keep until MEDI strategy decided |

(Bucket cleanup is mechanical — `aws s3 rm s3://cjb-gutz-s3-demo/metaphlan_databases/ --recursive`
once I21 is verified working.)

### After I21 lands, runtime bucket access is gone

The `metaphlan --install` flow only runs at AMI bake time, not at
worker runtime. Once that's locked in, the runtime stack has zero
reason to access this bucket — workers boot with prepared DBs already
on disk.

**Status: ready to land** once I21 is built into a new AMI and we've
confirmed `profile_taxa` no longer triggers S3 access at runtime.

Originally proposed 2026-04-27. Depends on I14 (custom AMI migration)
being live, which it is. Now also depends on I21 (DB prep in AMI) so
that the runtime path is genuinely bucket-free.

## MEDI storage decision required

Three options (must pick before I15 can proceed):

| Option | Description | Impact on I15 | Trade-off |
|---|---|---|---|
| A | Bake MEDI DB into the AMI (add `--include 'referencedata/medi_db/*'` to Packer) | I15 unblocks — workers no longer need bucket access at all | AMI grows from ~65 GB to ~510 GB; slower bake; larger snapshots |
| B | Lazy-pull MEDI DB at task runtime | I15 stays blocked — workers still need IAM grant | First MEDI task pays ~447 GB download (~30 min on r8g.2xlarge) |
| C | Permanently disable MEDI on AWS Batch (test profile only) | I15 unblocks if commitment is durable | Loses food-microbiome quantification on production runs |

Recommended: A if MEDI is part of the I10 production plan; B if MEDI is
occasional; C if MEDI is exploratory and might get cut.

## Background

`DbSourceBucket` was added to `infra/batch-stack.yaml` in I01 to parameterise
the `s3://cjb-gutz-s3-demo` reference that workers used at boot to populate
`/mnt/dbs/` via `aws s3 sync`. Two consumers in the stack:

1. **UserData** — workers ran `aws s3 sync s3://${DbSourceBucket} /mnt/dbs/`
   before starting ECS.
2. **`EcsInstanceRole` IAM policy** — granted workers `s3:Get/Put/Delete/List`
   on the bucket so the sync could succeed.

After I14 (custom AMI), consumer #1 is gone — UserData v12 is a health-check
probe that verifies `/mnt/dbs/{...}` exist on the baked AMI and exits. Workers
no longer touch the bucket at runtime. Only consumer #2 remains, and it grants
permissions that nothing in the runtime path uses.

The bucket itself still exists and is the canonical DB source for **Packer
builds** (`infra/packer/build-ami.sh`, `worker-ami.pkr.hcl`), but Packer runs
outside the stack with its own builder credentials — it does not use
`EcsInstanceRole`.

## Decision

Remove `DbSourceBucket` from `infra/batch-stack.yaml` entirely:

- Drop the parameter declaration (lines 89-97).
- Drop the IAM grant in `EcsInstanceRole.Policies.S3Access` (lines 188-190).

Update operator-facing docs to stop passing `DbSourceBucket=...` in
`--parameter-overrides`.

The bucket name lives on in `infra/packer/` where it is actually needed.

## Why this is safe

1. **No runtime use.** Confirmed by decoding LT v12 UserData (no `s3 sync`,
   no reference to the bucket). Workers boot, probe `/mnt/dbs/`, accept jobs.
2. **No drift risk.** The bucket itself has `DeletionPolicy` semantics outside
   the stack — the stack template explicitly says "This bucket is NOT created
   or deleted by this stack" (line 97). Removing the parameter does not delete
   the bucket.
3. **Reversible.** If a future change reintroduces a runtime DB-bucket
   dependency, the parameter and IAM grant can be added back in one commit.
4. **Narrows blast radius.** Workers currently have read/write/delete on the
   DB bucket they don't use. Post-change, workers only have access to
   `S3WorkDirBucket` (workdir, stack-managed) and `RunsBucketName` (results).
   This is a small but real defence-in-depth improvement.
5. **Existing workers unaffected.** The IAM policy update happens in place
   on `EcsInstanceRole`; CloudFormation does not replace the role. Active
   workers retain their cached credentials until next refresh, then pick up
   the narrowed policy. Either way, neither version of the policy is exercised
   at runtime — nothing in the worker code path calls `s3://cjb-gutz-s3-demo`.

## Files to change

| File | Change |
|------|--------|
| `infra/batch-stack.yaml` | Delete `DbSourceBucket` parameter (89-97). Delete `!Sub "arn:aws:s3:::${DbSourceBucket}"` and `${DbSourceBucket}/*` from `EcsInstanceRole.Policies.S3Access.Resource` (188-190). |
| `infra/readme.md` | Remove `DbSourceBucket=cjb-gutz-s3-demo \` from every `--parameter-overrides` block (lines 186, 388, 551). Remove the `aws s3 ls s3://cjb-gutz-s3-demo/` reachability check (lines 280-281) — replace with a note that DB source reachability is now a Packer-time concern, see `infra/packer/`. |
| `issues/I10-production-playbook.md` | Same `--parameter-overrides` cleanup (lines 64, 281). |
| `.claude/agents/batch-doctor.md` | Line 36: drop "Is the DB source bucket (`DbSourceBucket` parameter) reachable?" from the S3 buckets check, OR rephrase to point at the Packer-build concern. The agent should not flag worker-runtime issues for a bucket workers no longer use. |

Out of scope (historical artifacts, leave alone):

- `issues/I01-parameterize-db-bucket.md` — original I01 issue, supersede note only.
- `issues/I07-db-placement-adr.md` — superseded by I14 already.
- `infra/adr-001-db-placement.md` — superseded; add a one-line note pointing at I15.
- `pull_requests/I00-fix-containerOptions-batch/*.json` — historical monkey-paw artifacts.

## Deployment plan

```bash
# 1. Edit infra/batch-stack.yaml and the docs files.
# 2. Validate the template:
aws cloudformation validate-template \
  --template-body file://infra/batch-stack.yaml \
  --region us-east-2

# 3. Deploy (note: NO DbSourceBucket override anymore).
aws cloudformation deploy \
  --stack-name nf-reads-profiler-batch \
  --template-file infra/batch-stack.yaml \
  --parameter-overrides \
    EcsAmiId=$(aws ssm get-parameter --name /nf-reads-profiler/ami-id \
                 --region us-east-2 --query 'Parameter.Value' --output text) \
    # ...other existing params...
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-2

# 4. Verify the IAM policy was narrowed:
aws iam get-role-policy \
  --role-name nf-reads-profiler-ecs-instance-role \
  --policy-name S3Access \
  --region us-east-2 \
  --query 'PolicyDocument.Statement[0].Resource' --output table
# Expect 4 ARNs (workdir bucket + workdir/*, runs bucket + runs/*).
# cjb-gutz-s3-demo ARNs should be absent.

# 5. Run a smoke-test to confirm workers still come up healthy.
#    UserData v12 already has no DB-bucket dependency, so this is
#    only a sanity check.
bash infra/smoke-test.sh
```

## Rollback

If anything breaks (it shouldn't), `git revert` the change and redeploy.
The IAM policy will widen back to include the DB bucket. No data is at risk.

## Open questions

- Should `cjb-gutz-s3-demo` itself be renamed / moved into a project-owned
  account? Out of scope here — track separately if desired.
- The `batch-doctor` agent currently checks DB-bucket reachability as part
  of its health check. After I15 lands, that check is misleading because
  workers don't use the bucket. Either drop it or move it to a Packer-side
  prebuild check. (Listed above under files to change.)

## Acceptance criteria

- [ ] `grep -rn "DbSourceBucket\|cjb-gutz-s3-demo" infra/` returns hits
      only in `infra/packer/` (Packer-build territory) and possibly a
      one-line breadcrumb in `infra/adr-001-db-placement.md`.
- [ ] `aws cloudformation validate-template` passes.
- [ ] Stack deploy succeeds without `DbSourceBucket` in parameter overrides.
- [ ] `EcsInstanceRole` `S3Access` policy resource list has 4 ARNs (workdir
      + runs only), no DB-bucket ARNs.
- [ ] A post-deploy smoke-test passes end-to-end.
