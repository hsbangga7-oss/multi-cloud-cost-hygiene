# Multi-Cloud Cost Hygiene & Automation Challenge

## Overview

This project implements a cost hygiene automation system for a fictional e-commerce client (NimbusKart) whose AWS bill grew from ~$400/month to ~$2,100/month due to orphaned resources. It provisions a baseline AWS infrastructure using Terraform against LocalStack, runs a Bash-based Cost Janitor that detects wasteful resources, and wires everything into a GitHub Actions CI/CD pipeline that enforces cost hygiene on every pull request.The stack uses Terraform, Bash, AWS CLI, jq, LocalStack, and GitHub Actions — no real cloud credentials or spending required.

## How to run locally

**Prerequisites:** Docker, Terraform >= 1.5, AWS CLI >= 2.x, jq

```bash
# 1. Clone the repo
git clone https://github.com/hsbangga7-oss/multi-cloud-cost-hygiene.git
cd multi-cloud-cost-hygiene

# 2. Start LocalStack
docker run --rm -d -p 4566:4566 --name localstack localstack/localstack:3.0

# 3. Configure AWS CLI to point at LocalStack
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL=http://localhost:4566

# 4. Provision infrastructure
cd terraform
terraform init
terraform apply -auto-approve
cd ..

# 5. Run Cost Janitor (dry-run — safe, no deletions)
cd janitor
bash janitor.sh --dry-run

# 6. Run Cost Janitor (delete mode — WARNING: deletes real resources if run against real AWS))
bash janitor.sh --delete

# 7. View the report
cat report.json | jq .
cat report.md
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  LocalStack (Docker · localhost:4566)                        │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  VPC  10.20.0.0/16                                    │  │
│  │                                                        │  │
│  │  ┌─────────────────────┐  ┌─────────────────────┐    │  │
│  │  │  Subnet 1           │  │  Subnet 2           │    │  │
│  │  │  us-east-1a         │  │  us-east-1b         │    │  │
│  │  │  10.20.1.0/24       │  │  10.20.2.0/24       │    │  │
│  │  └──────────┬──────────┘  └──────────┬──────────┘    │  │
│  │             └──────────┬─────────────┘               │  │
│  │                        │                              │  │
│  │             ┌──────────▼──────────┐                  │  │
│  │             │   Route table       │                   │  │
│  │             │   (public)          │                   │  │
│  │             └──────────┬──────────┘                  │  │
│  │                        │                              │  │
│  │             ┌──────────▼──────────┐                  │  │
│  │             │  Internet gateway   │                   │  │
│  │             └─────────────────────┘                  │  │
│  │                                                        │  │
│  │  ┌─────────────────┐  ┌─────────────────┐            │  │
│  │  │  EC2 (running)  │  │  EC2 (stopped)  │            │  │
│  │  │  web tier       │  │  web tier       │            │  │
│  │  └─────────────────┘  └─────────────────┘            │  │
│  │                                                        │  │
│  │  ┌─────────────────┐  ┌─────────────────┐            │  │
│  │  │  S3 bucket      │  │  EBS volume     │            │  │
│  │  │  logs · versioned│  │  ⚠ orphan      │            │  │
│  │  └─────────────────┘  └─────────────────┘            │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘


CI/CD Pipeline (GitHub Actions)
────────────────────────────────────────────────────────────────

  Push / PR
      │
      ▼
  ┌───────────────────────────┐
  │  LocalStack               │  service container · port 4566
  │  spins up                 │
  └─────────────┬─────────────┘
                │
                ▼
  ┌───────────────────────────┐
  │  terraform apply          │  provisions VPC, EC2, S3, EBS
  └─────────────┬─────────────┘
                │
                ▼
  ┌───────────────────────────┐
  │  janitor.sh --dry-run     │  scans for orphaned resources
  └──────┬────────────────────┘
         │
         ├──────────────────────────────────────────┐
         ▼                                          ▼
  ┌─────────────────────┐              ┌────────────────────────┐
  │  report.json        │              │  PR comment posted     │
  │  report.md          │              │  (if orphans found)    │
  │  (uploaded as        │              └────────────────────────┘
  │  artifacts)          │
  └─────────────────────┘
```
## Decisions & deviations

- **Port 22 open to 0.0.0.0/0** — spec requires this as default but it is unsafe; in production this should be restricted to a bastion CIDR or VPN range. Flagged here as a known bad practice.
- **S3 lifecycle disabled on LocalStack** — LocalStack free tier does not support `aws_s3_bucket_lifecycle_configuration`; wrapped in `enable_s3_lifecycle = false` feature flag so it works on real AWS without code changes.
- **Bash chosen over Python** — assignment allows either; Bash was chosen to minimise dependencies (no pip, no virtualenv) and keep the CI container lightweight.
- **Stopped EC2 age check returns 0 days on LocalStack** — LocalStack does not persist real launch timestamps; instances always appear as age 0. The logic is correct and would work on real AWS.
- **EBS volume deleted in earlier testing** — the orphan EBS volume was accidentally deleted during development; re-created via `terraform apply`. CI provisions a fresh one on every run.
- **SSH CIDR defaults to 0.0.0.0/0** — the spec explicitly sets this as the default but flags it as unsafe. I kept it as the default for LocalStack compatibility but added a `ssh_allowed_cidr` variable so any real deployment can restrict it to a specific IP range without touching the code.

## Trade-offs

With one more week I would add:

- **Elastic IP allocation in Terraform** so the janitor always has a real unused EIP to detect in CI, rather than relying on a leftover one
- **Scheduled GitHub Actions cron** (`0 9 * * *`) so the janitor runs daily without a PR trigger
- **SNS/email alert** when the janitor deletes resources in `--delete` mode
- **Terraform remote state** using an S3 backend so state is not local
- **`infracost`** integration to show estimated cost diff on every PR
- **Unit tests** for the janitor using `bats` (Bash Automated Testing System)
- **Multi-account support** via AWS Organizations and assumed roles

## AI usage disclosure

- **Tools used:** Claude (claude.ai) was used throughout — for Terraform boilerplate, debugging LocalStack errors, writing the janitor script, and fixing GitHub Actions workflow issues.
- **One thing AI got wrong:** Claude initially suggested using `DRY_RUN=true` as an environment variable flag instead of `--dry-run` / `--delete` CLI flags as required by the assignment spec. I caught this by re-reading the brief and corrected it.
- **One section written without AI:** The `Decisions & deviations` section above was written manually — these are genuine judgment calls I made while working through the assignment, and I wanted them to reflect my own reasoning rather than generated text.
