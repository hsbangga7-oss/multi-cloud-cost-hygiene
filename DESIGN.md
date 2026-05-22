# Design Document — Multi-Cloud Cost Hygiene & Automation Challenge

## Overview

This project builds a cost hygiene automation system for a fictional e-commerce client (NimbusKart) whose AWS bill grew unexpectedly due to orphaned resources. The system provisions baseline infrastructure on LocalStack using Terraform, detects wasteful resources with a Bash-based Cost Janitor, and enforces hygiene on every pull request via GitHub Actions CI/CD.

---

## Module Boundaries

The codebase is split into three independent layers, each with a single responsibility:

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1: Infrastructure (terraform/)                           │
│  Owns: VPC, subnets, IGW, EC2, SG, EBS, S3                    │
│  Interface: outputs.tf exposes IDs to consumers                │
│  Multi-cloud boundary: modules/network/ is cloud-agnostic in   │
│  naming — a GCP equivalent would replace aws_vpc with          │
│  google_compute_network and aws_subnet with                     │
│  google_compute_subnetwork, leaving root module unchanged.     │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2: Automation (janitor/)                                 │
│  Owns: orphan detection, report generation, deletion logic     │
│  Interface: --dry-run / --delete flags; report.json output     │
│  Cloud boundary: aws_cmd() wraps all AWS CLI calls — swapping  │
│  to Azure CLI or gcloud would require changing only that       │
│  function, not the detection or reporting logic.               │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3: CI/CD (.github/workflows/)                           │
│  Owns: pipeline orchestration, artifact upload, PR comments    │
│  Interface: consumes report.json produced by Layer 2           │
│  Cloud boundary: LocalStack runs as a service container;       │
│  switching to a real AWS account requires only changing        │
│  AWS_ENDPOINT_URL — no workflow logic changes.                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    LocalStack                        │
│                                                      │
│   ┌─────────────────────────────────────────────┐   │
│   │  VPC (10.20.0.0/16)                         │   │
│   │                                             │   │
│   │  ┌──────────────┐  ┌──────────────┐        │   │
│   │  │  Subnet 1    │  │  Subnet 2    │        │   │
│   │  │  us-east-1a  │  │  us-east-1b  │        │   │
│   │  │  10.20.1.0/24│  │  10.20.2.0/24│        │   │
│   │  └──────┬───────┘  └──────┬───────┘        │   │
│   │         └────────┬────────┘                 │   │
│   │  ┌──────────────▼─────────────────┐        │   │
│   │  │     Route Table → IGW          │        │   │
│   │  └────────────────────────────────┘        │   │
│   │                                             │   │
│   │  EC2 (running)   EC2 (stopped)             │   │
│   │  Security Group: 22, 80, 443               │   │
│   │                                             │   │
│   │  S3 (logs, versioning enabled)             │   │
│   │  EBS (8GB, unattached — orphan target)     │   │
│   └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

---

## Minimal IAM Policy for Read-Only Mode

When running the janitor with `--dry-run`, it only reads AWS state and requires no write permissions. The minimal IAM policy for a read-only service account is:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CostJanitorReadOnly",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeVolumes",
        "ec2:DescribeInstances",
        "ec2:DescribeAddresses",
        "s3:ListAllMyBuckets",
        "s3:ListBucket",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

For `--delete` mode, these additional write permissions are required:

```json
{
  "Sid": "CostJanitorDelete",
  "Effect": "Allow",
  "Action": [
    "ec2:DeleteVolume",
    "ec2:ReleaseAddress"
  ],
  "Resource": "*",
  "Condition": {
    "StringNotEquals": {
      "aws:ResourceTag/Protected": "true"
    }
  }
}
```

The `Condition` block enforces the `Protected=true` guardrail at the IAM level, providing a second layer of protection beyond the tag-check in the script itself.

---

## Failure Modes & Guardrails

### Failure Mode 1: Accidental deletion of a Protected resource

**Scenario:** An operator runs `--delete` in production and a Protected EBS volume matches the orphan query.

**Guardrails in place:**
- Script reads the `Protected` tag before any delete call and skips the resource with a `SKIP` log line
- IAM Condition (above) blocks the API call even if the tag-check logic has a bug
- `--dry-run` is the default mode; `--delete` requires an explicit flag

**Mitigation:** Before running `--delete` in production, always run `--dry-run` first and review `report.json`. The CI pipeline enforces this by only ever running `--dry-run`.

---

### Failure Mode 2: LocalStack divergence from real AWS behaviour

**Scenario:** The janitor passes CI against LocalStack but silently fails on real AWS because an API response schema differs.

**Guardrails in place:**
- All AWS CLI calls use `--output json` and parse with `jq` — structured output reduces fragility vs. text parsing
- `set -euo pipefail` ensures any unexpected `jq` parse failure aborts the script immediately rather than silently continuing
- `report.json` is always written before the exit-code check, so artifacts are available for debugging even when the run fails

**Mitigation:** The `aws_cmd()` wrapper makes it trivial to point the script at a real AWS account by changing `AWS_ENDPOINT_URL`. Integration tests against real AWS (even a sandbox account) would catch divergence before production use.

---

## Observability Metrics

If this system were running in production, the following metrics would be tracked with these thresholds:

| Metric | Collection Method | Warning Threshold | Critical Threshold |
|--------|------------------|-------------------|--------------------|
| `janitor.orphans.total` | `report.json → summary.total_orphans` | > 5 | > 20 |
| `janitor.waste.monthly_usd` | `report.json → summary.estimated_monthly_waste_usd` | > $50 | > $200 |
| `janitor.ebs.unattached_count` | findings filter by `resource_type=ebs_volume` | > 3 | > 10 |
| `janitor.eip.unused_count` | findings filter by `resource_type=elastic_ip` | > 2 | > 5 |
| `janitor.run.exit_code` | CI step exit code | non-zero = alert | — |

These would be pushed to CloudWatch custom metrics or a Prometheus pushgateway at the end of each janitor run.

---

## Tagging Strategy

All Terraform resources use `common_tags` from `locals.tf`:

```hcl
locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
```

The janitor enforces four required tags: `Project`, `Environment`, `Owner`, `ManagedBy`. Resources missing any of these are flagged with `reason: missing_tags:...` in the report. The `Protected=true` tag opts a resource out of deletion entirely.

---

## Cost Hygiene Logic

| Resource | Condition | Action |
|----------|-----------|--------|
| EBS Volume | `status=available` AND `Protected!=true` | Delete (or report in dry-run) |
| Elastic IP | `AssociationId=null` AND `Protected!=true` | Release (or report in dry-run) |
| EC2 Instance | `state=stopped` AND `age > STOPPED_DAYS` | Report only (never auto-delete) |
| Any EC2 | Missing required tags | Report only |

Stopped EC2 instances are intentionally never auto-deleted — a stopped instance may be intentional (maintenance window, cost saving). The janitor surfaces them for human review.

---

## What I Did Not Build

- **Elastic IP Terraform resource** — the unused EIP detected by the janitor is a leftover from LocalStack state, not a deliberately provisioned resource. In production, you would provision an EIP in Terraform and immediately see the janitor detect it as orphaned unless associated.
- **Scheduled cron trigger** — the GitHub Actions workflow only runs on push/PR. A daily cron (`0 9 * * 1-5`) would make this a continuous hygiene system rather than a gate.
- **Alerting** — no SNS topic, no Slack webhook. The janitor logs to stdout and writes `report.json`; alerts would require an additional step that calls an alerting API.
- **Multi-account support** — the janitor targets a single account/region. Real cost hygiene at scale requires iterating over accounts via AWS Organizations and assuming cross-account roles.
- **GCP/Azure modules** — the assignment is titled "multi-cloud" but the infrastructure is AWS-only. True multi-cloud would require a `modules/gcp-network` and `modules/azure-network` with equivalent resources and a provider-agnostic interface.
- **Unit tests for the janitor** — the script has no automated tests. A `bats` (Bash Automated Testing System) test suite would mock `aws` CLI calls and verify correct behaviour for each scan function.