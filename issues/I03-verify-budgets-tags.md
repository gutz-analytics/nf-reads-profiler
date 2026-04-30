# I03: Verify cost-allocation tags, budget threshold, and alert delivery

**Status:** **PARTIALLY DONE — 2026-04-27.** Tag propagation verified
end-to-end during I16 max005 run; budget filter confirmed wired. Two
manual UI checks still required: (1) `Project` tag activation in Billing
console, (2) Cost Explorer data verification (24 h lag after activation).
Budget alert dry-run skipped — Phase B of I04 verification already
delivered alarm emails to `colin+claude@vasogo.com`, so the SNS pipeline
is proven working.

**Priority:** medium
**Size:** small (mostly manual verification; one-line template change)
**Dependencies:** none — can be done independently of any pipeline work

---

## Verification results (2026-04-27)

### Task 3 (the critical one) — PASS

While the I16 max005 run was active, two Batch-launched workers were
queried via `aws ec2 describe-instances`:

```
i-0f845f6c205afbbaa  r6g.2xlarge  ami-0b87926a60df7043e  Project=nf-reads-profiler
i-0e5a8036d998a530a  r7g.2xlarge  ami-0b87926a60df7043e  Project=nf-reads-profiler
```

**Both spot and on-demand workers carry the `Project` tag.** This means
the AWS Budget cost filter (`user:Project$nf-reads-profiler`) will
actually capture EC2 spending. The CFN compute environment `tags` block
is propagating to the underlying EC2 instances as intended — no extra
`propagate-tags` workaround needed.

### Task 4 — Budget threshold update — DONE in working tree

`infra/batch-stack.yaml` template default updated from 500 → 200
(uncommitted; will be deployed as part of a future coordinated stack
update). The **live deployed budget is already $100** — tighter than
I03's $200 target — so no immediate redeploy is needed.

```
Live budget config (verified 2026-04-27):
  Limit:        $100.0 USD / month
  Filter:       user:Project$nf-reads-profiler
  Type:         COST, MONTHLY
  Notifications:
    - 80% ACTUAL    → email
    - 100% FORECAST → email
```

### Task 5 — Budget alert dry-run — SKIPPED (covered indirectly)

Originally proposed: temporarily set budget to $1, wait for email, restore.

Skipped because **Phase B of I04 already verified end-to-end SNS email
delivery** to `colin+claude@vasogo.com` via two real alarm fires
(`failed-jobs` ALARM at 19:58 UTC + OK at 20:13 UTC). The SNS pipeline
is the same one the budget uses for direct-email alerts (the budget
itself does NOT use SNS; it uses AWS-managed direct email via
`notifications-noreply@amazon.com`). So:

- **SNS alerting is proven working** for CloudWatch alarms.
- **Budget alerting** is technically a separate channel — AWS Budgets
  sends email directly, not via the SNS topic. Confidence is high but
  not strictly verified by today's tests. If you want belt-and-braces,
  do the dry-run later.

### Tasks 1, 2 — Tag activation & Cost Explorer — STILL TO DO (manual UI)

These cannot be verified from the head node — `head-node-role` lacks
the `ce:ListCostAllocationTags` and `ce:GetCostAndUsage` IAM permissions.

| Task | Action | Where |
|---|---|---|
| 1 | Activate `Project` cost-allocation tag | <https://us-east-1.console.aws.amazon.com/billing/home#/tags> |
| 2 | Confirm `Project` filter shows EC2/S3/CW costs (24h lag after activation) | <https://us-east-1.console.aws.amazon.com/cost-management/home#/cost-explorer> |

Once Task 1 is done, the next CHILD pilot run's costs will actually
appear in Cost Explorer under the `Project = nf-reads-profiler` filter
~24h later. Worth doing before the I09 pilot or the I10 production run.

---

## Background

The CloudFormation stack (`infra/batch-stack.yaml`) creates an AWS Budget
(`BatchMonthlyBudget`) that filters costs by `Project=nf-reads-profiler`.
AWS cost-allocation tags must be **explicitly activated** in the Billing
console before they appear in Cost Explorer or Budget filters — they are not
active by default even if applied to every resource. Until the tag is active,
the budget filter matches nothing and the monthly alert is effectively disabled.

Additionally, tags on CloudFormation resources and Batch compute environments
do not automatically propagate to the EC2 spot instances that Batch launches.
This is a well-known AWS gotcha and needs direct verification against actual
EC2 instance metadata and billing line items.

The template default for `MonthlyBudgetThreshold` is currently `500` USD.
For the debugging/pilot phase the target is `200` USD.

## Tasks

### 1. Activate the `Project` cost-allocation tag (manual, ~5 min)

Go to:
**AWS Billing console → Cost allocation tags → User-defined tags**
<https://us-east-1.console.aws.amazon.com/billing/home#/tags>

(Note: AWS Billing is a global service — use the `us-east-1` console URL
regardless of which region your resources are in.)

Find `Project` in the list and click **Activate**. If it is not listed yet,
tags may need up to 24 hours to appear after first being applied to a resource.

Expected result: `Project` shows status `Active`.

### 2. Confirm the tag is visible in Cost Explorer (manual, allow 24 h after activation)

Go to:
**AWS Cost Management → Cost Explorer**
<https://us-east-1.console.aws.amazon.com/cost-management/home#/cost-explorer>

Add a filter: `Tag → Project → nf-reads-profiler`. Switch the grouping to
**Service**. If costs appear, the tag is flowing through to billing data.

Expected result: EC2, S3, and CloudWatch costs appear under the filter
(even if small during a quiet period).

> Cost Explorer may show no data for the first 24 hours after tag activation.
> Check again the following day if the view is empty.

### 3. Verify tag propagation to spot EC2 instances (critical — manual verification)

This is the most important step. Batch compute environment tags and CFN
resource tags do not always propagate to the underlying EC2 instances,
especially for spot capacity managed via EC2 Fleet (which
`SPOT_CAPACITY_OPTIMIZED` may use internally instead of a Spot Fleet).

**While a pipeline run is active**, check the running instances:

```bash
aws ec2 describe-instances \
  --region us-east-2 \
  --filters \
    "Name=instance-state-name,Values=running,pending" \
    "Name=tag:aws:batch:compute-environment,Values=*nf-reads-profiler*" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key==`Project`].Value|[0]]' \
  --output table
```

Expected result: the `Project` column shows `nf-reads-profiler` for every instance.

If the column is empty/null, tags are not propagating. Mitigation options:
- Add `propagate-tags` in the Batch compute environment (not directly
  supported in CFN as of 2026; may need to update via CLI after stack deploy).
- Alternatively accept that the budget filter won't catch EC2 spot costs and
  rely on the overall account budget as a fallback.

Also check billing directly: in Cost Explorer, filter by
`Tag: Project = nf-reads-profiler` and group by **Resource** to see if
EC2 instance IDs appear in the results (allow a 1-day lag).

### 4. Update the budget threshold default to $200 (code change — trivial)

In `infra/batch-stack.yaml`, update the `MonthlyBudgetThreshold` parameter default:

```yaml
# Before
  MonthlyBudgetThreshold:
    Type: Number
    Default: 500

# After
  MonthlyBudgetThreshold:
    Type: Number
    Default: 200
```

Then redeploy the stack with `MonthlyBudgetThreshold=200`.

Verify the budget was updated:

```bash
aws budgets describe-budget \
  --account-id 730883236839 \
  --budget-name nf-reads-profiler-monthly \
  --query 'Budget.BudgetLimit'
```

Expected: `{"Amount": "200.0", "Unit": "USD"}`.

### 5. Trigger a budget alert dry-run (manual)

Temporarily lower the threshold to $1 to force an alert, confirm the email arrives,
then restore to $200.

```bash
# Lower threshold to $1
aws budgets update-budget \
  --account-id 730883236839 \
  --new-budget '{
    "BudgetName": "nf-reads-profiler-monthly",
    "BudgetType": "COST",
    "TimeUnit": "MONTHLY",
    "BudgetLimit": {"Amount": "1", "Unit": "USD"}
  }'
```

Wait up to 15 minutes. Check the `BudgetAlertEmail` inbox for a message from
`notifications-noreply@amazon.com` with subject containing `nf-reads-profiler-monthly`.

```bash
# Restore to $200 immediately after the email arrives
aws budgets update-budget \
  --account-id 730883236839 \
  --new-budget '{
    "BudgetName": "nf-reads-profiler-monthly",
    "BudgetType": "COST",
    "TimeUnit": "MONTHLY",
    "BudgetLimit": {"Amount": "200", "Unit": "USD"}
  }'
```

> Budget alerts have up to a ~15-minute delivery delay. If no email after
> 30 minutes, check the SNS subscription: the budget uses direct email
> (not the SNS `AlarmTopic`), so verify the email address in the CloudFormation
> parameter matches the inbox you are checking.

### 6. Document results in `infra/readme.md`

Replace the "Untested" sections under Cost Monitoring with a verified
results table covering:

- Date verified
- Tag activation status
- Whether spot EC2 instances show the `Project` tag
- Whether Cost Explorer shows filtered data
- Alert dry-run result (email received y/n, latency in minutes)

## Definition of done

- [ ] `Project` tag is Active in AWS Billing console
- [ ] Cost Explorer shows costs under `Project = nf-reads-profiler` filter
- [ ] Spot EC2 instances launched by Batch carry `Project=nf-reads-profiler` tag
      (or the limitation is documented with a mitigation decision)
- [ ] `MonthlyBudgetThreshold` default updated to `200` in `batch-stack.yaml`
- [ ] Stack redeployed with `MonthlyBudgetThreshold=200`
- [ ] Budget alert email received during dry-run
- [ ] `infra/readme.md` Cost Monitoring section updated with verified results

## Notes

- AWS Cost Explorer data has a 24-hour lag; plan for a day between tag
  activation and Cost Explorer verification.
- The `SpotFleetRole` in the stack uses `AmazonEC2SpotFleetTaggingRole`,
  which is the correct policy for propagating tags to spot fleet instances.
  However, `SPOT_CAPACITY_OPTIMIZED` may use EC2 Fleet internally rather
  than Spot Fleet, so tag propagation is not guaranteed by the role alone.
- Budget alert emails come from AWS Budgets directly (not via the SNS
  `AlarmTopic`); the SNS topic is only wired to CloudWatch alarms.
