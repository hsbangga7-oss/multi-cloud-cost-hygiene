# Submission Report

**Candidate:** Harshpreet Singh Bangga
**Assignment:** Multi-Cloud Cost Hygiene & Automation Challenge
**Date:** May 2026
**Repo:** https://github.com/YOUR_USERNAME/multi-cloud-cost-hygiene

---

## Checklist

- [x] Terraform provisions all required resources against LocalStack
- [x] VPC CIDR set to `10.20.0.0/16` with two public subnets
- [x] Security group allows ports 22, 80, 443
- [x] S3 bucket with versioning enabled
- [x] Orphan EBS volume provisioned for janitor to detect
- [x] Cost Janitor script with `--dry-run` and `--delete` flags
- [x] Janitor detects: unattached EBS, unused Elastic IPs, stopped EC2 (> N days), missing tags
- [x] `report.json` output with correct schema
- [x] `report.md` Markdown summary
- [x] `Protected=true` tag respected — tagged resources never deleted
- [x] Non-zero exit code when orphans found in `--dry-run` (CI fails correctly)
- [x] GitHub Actions workflow spins up LocalStack, applies Terraform, runs janitor
- [x] `report.json` and `report.md` uploaded as CI artifacts
- [x] `samples/report.example.json` committed to repo
- [x] `README.md` with all required sections including AI usage disclosure
- [x] `DESIGN.md` with module boundaries, IAM policy, failure modes, metrics
- [ ] Walkthrough video (5 min screen recording) — see note below

---

## What I Built

### 1. Terraform Infrastructure (`terraform/`)

Provisions a baseline AWS environment on LocalStack:

- VPC `10.20.0.0/16` with two public subnets across `us-east-1a` and `us-east-1b`
- Internet Gateway + public route table
- Security group with ingress on ports 22 (SSH), 80 (HTTP), 443 (HTTPS)
- Two EC2 instances: one running, one stopped
- One unattached 8 GB EBS volume (deliberate orphan for janitor to detect)
- S3 bucket with versioning enabled
- S3 lifecycle configuration conditionally disabled via `enable_s3_lifecycle = false` (LocalStack limitation)

Network resources are isolated in `modules/network/` for reusability.

### 2. Cost Janitor (`janitor/janitor.sh`)

A Bash script (`set -euo pipefail`) that scans for four orphan types:

| Check | Resource | Action |
|-------|----------|--------|
| Unattached EBS volumes | `status=available` | Delete or report |
| Unused Elastic IPs | `AssociationId=null` | Release or report |
| Stopped EC2 > N days | `state=stopped`, age threshold configurable via `STOPPED_DAYS` | Report only |
| Missing required tags | `Project`, `Environment`, `Owner`, `ManagedBy` | Report only |

Outputs `report.json` (machine-readable) and `report.md` (human-readable summary).
Exits with code 1 in `--dry-run` mode if any orphans are found, so CI fails as a gate.
Respects `Protected=true` tag — tagged resources are never deleted regardless of mode.

### 3. GitHub Actions CI/CD (`.github/workflows/cost-janitor.yml`)

On every push and pull request:

1. Starts LocalStack `3.0` as a service container
2. Runs `terraform apply -auto-approve` to provision infrastructure
3. Runs `janitor.sh --dry-run`
4. Uploads `report.json` and `report.md` as downloadable artifacts
5. Posts `report.md` as a PR comment if orphans are found (PR events only)
6. Fails the workflow if `total_orphans > 0`

---

## How to Run

```bash
# 1. Start LocalStack
docker run --rm -d -p 4566:4566 --name localstack localstack/localstack:3.0

# 2. Set environment
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL=http://localhost:4566

# 3. Provision infrastructure
cd terraform && terraform init && terraform apply -auto-approve && cd ..

# 4. Run janitor (dry-run)
bash janitor/janitor.sh --dry-run

# 5. Run janitor (delete mode)
bash janitor/janitor.sh --delete

# 6. View reports
cat janitor/report.json
cat janitor/report.md
```

---

## Key Design Decisions

- **`--dry-run` as default** — the script requires an explicit `--delete` flag to make any changes. Safe by default, opt-in for destructive operations.
- **Temp files instead of subshells** — Bash `| while read` runs in a subshell and loses variable state. The janitor uses `mktemp` files for `FINDINGS` and `WASTE` accumulators to avoid this classic Bash scoping bug.
- **`awk` instead of `bc`** — Git Bash on Windows does not ship `bc`. All floating-point arithmetic uses `awk BEGIN` blocks for cross-platform compatibility.
- **Index-loop instead of pipe-loop** — `jq -c '.[]' | while read` creates a subshell. The janitor iterates with `while [[ $i -lt $count ]]` and accesses items via `jq ".[$i]"` to keep state in the parent shell.
- **S3 lifecycle feature flag** — LocalStack free tier does not support `aws_s3_bucket_lifecycle_configuration`. Wrapped in `count = var.enable_s3_lifecycle ? 1 : 0` so flipping one variable enables it on real AWS.
- **Bash over Python** — assignment allows either; Bash was chosen to minimise CI dependencies (no `pip install`, no virtualenv) and keep the service container startup fast.

---

## What I'd Add With More Time

- **Scheduled cron** — daily `0 9 * * 1-5` GitHub Actions trigger for continuous hygiene rather than PR-only gating
- **SNS alerting** — publish a message to an SNS topic when `--delete` removes a resource, with email/Slack subscription
- **Terraform remote state** — S3 backend + DynamoDB lock table so state is not local
- **`infracost` integration** — show estimated monthly cost diff on every PR alongside the janitor report
- **`bats` unit tests** — mock `aws` CLI calls and test each janitor scan function in isolation
- **Multi-account support** — iterate over AWS Organization accounts, assume cross-account roles, and aggregate findings into a single report
- **GCP/Azure modules** — true multi-cloud coverage with `modules/gcp-network` and `modules/azure-network`

---

## Known Limitations

- Stopped EC2 age always shows 0 days on LocalStack — LocalStack does not persist real launch timestamps. The age-check logic is correct and would work on real AWS.
- Unused EIP detected by janitor is a LocalStack leftover, not a Terraform-provisioned resource. On real AWS you would `aws_eip` in Terraform and intentionally leave it unassociated.
- `terraform.tfvars` is excluded from the repo (`.gitignore`) — it contains LocalStack-specific endpoint overrides.

---

## AI Usage Disclosure

Claude (claude.ai) was used throughout this project for Terraform boilerplate, debugging LocalStack errors, writing the janitor script, and fixing GitHub Actions workflow issues.

**One thing AI got wrong:** Claude initially suggested using a `DRY_RUN=true` environment variable instead of `--dry-run` / `--delete` CLI flags as required by the assignment spec. I caught this by re-reading the brief and corrected it.

**One section written without AI:** The Key Design Decisions section above was written manually. These reflect genuine choices I made while working through the project — the subshell scoping bug, the `awk` vs `bc` issue on Windows, the index-loop pattern — and I wanted them to represent my own understanding rather than generated text.