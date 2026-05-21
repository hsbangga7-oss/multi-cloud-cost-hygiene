# Multi-Cloud Cost Hygiene & Automation Challenge

A DevOps project demonstrating infrastructure provisioning, cost hygiene automation,
and CI/CD workflows using Terraform, Bash, AWS CLI, and GitHub Actions — running locally
on LocalStack.

## Prerequisites

- [Docker](https://www.docker.com/) (for LocalStack)
- [LocalStack](https://localstack.cloud/) (`localstack/localstack:3.0`)
- [Terraform](https://www.terraform.io/) >= 1.5
- [AWS CLI](https://aws.amazon.com/cli/) >= 2.x
- [jq](https://stedolan.github.io/jq/)

## Quick Start

### 1. Start LocalStack
```bash
docker run --rm -d -p 4566:4566 localstack/localstack:3.0
```

### 2. Provision Infrastructure
```bash
cd terraform
terraform init
terraform apply
```

### 3. Run Cost Janitor (dry run)
```bash
DRY_RUN=true bash scripts/cost-janitor.sh
```

### 4. Run Cost Janitor (real cleanup)
```bash
DRY_RUN=false bash scripts/cost-janitor.sh
```

## Project Structure
multi-cloud-cost-hygiene/
├── terraform/
│   ├── main.tf              # Core resources (EC2, S3, EBS, SG)
│   ├── provider.tf          # AWS + LocalStack provider config
│   ├── variables.tf         # Input variables
│   ├── outputs.tf           # Resource outputs
│   ├── locals.tf            # Common tags and locals
│   └── modules/
│       └── network/         # VPC, subnets, IGW, route tables
├── scripts/
│   ├── cost-janitor.sh      # Cost cleanup automation
│   └── lib/                 # Helper libraries
├── .github/workflows/
│   └── validate.yml         # CI/CD: Terraform validate + ShellCheck
├── DESIGN.md
├── SUBMISSION.md
└── README.md
## CI/CD

GitHub Actions runs on every push to `main`:
- Terraform format check (`terraform fmt`)
- Terraform validation (`terraform validate`)
- Shell script linting (`shellcheck`)