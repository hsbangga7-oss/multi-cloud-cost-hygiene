# Submission — DevOps Engineer Assignment

**Candidate name:** Harshpreet Singh Bangga
**Email:** your@email.com
**Date submitted:** May 2026
**Hours spent (approximate):** 8

## Deliverables checklist

- [x] Part A: Terraform code under /terraform applies cleanly on LocalStack
- [x] Part A: `terraform validate` and `terraform fmt -check` both pass
- [x] Part B: Janitor script runs in --dry-run mode and produces report.json
- [x] Part B: GitHub Actions workflow runs green on a fresh PR
- [x] Part B: --delete mode respects Protected=true tag
- [x] Part C: DESIGN.md is present and within 2 pages
- [ ] Walkthrough video link below is accessible (unlisted is fine)

## Walkthrough video

Link (Loom / YouTube unlisted / Google Drive): _TODO after recording_
Length: max 5 minutes

## Sample report

Path to a sample report.json produced by your script: `samples/report.example.json`

## Known limitations

- Stopped EC2 age always shows 0 days on LocalStack — LocalStack does not persist real launch timestamps; the age-check logic is correct and would work on real AWS
- Unused EIP detected by janitor is a LocalStack leftover, not a Terraform-provisioned resource
- S3 lifecycle configuration disabled via feature flag due to LocalStack free-tier limitation; flipping `enable_s3_lifecycle = true` enables it on real AWS
- `terraform.tfvars` excluded from repo — contains LocalStack endpoint overrides

## AI usage disclosure

Claude (claude.ai) was used throughout — for Terraform boilerplate, debugging LocalStack errors, writing the janitor script, and fixing GitHub Actions workflow issues.

One thing AI got wrong: Claude initially suggested a `DRY_RUN=true` environment variable instead of `--dry-run` / `--delete` CLI flags as required by the spec. I caught this by re-reading the brief and corrected it.

One section written without AI: The Decisions & deviations section in README.md — these reflect genuine judgment calls made while working through the project and were written to represent my own understanding.