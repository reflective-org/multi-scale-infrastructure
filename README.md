# multi-scale-infrastructure

AWS infrastructure for the Multi-Scale project: OpenTofu configuration to purchase EC2 Capacity Blocks for ML (p5.48xlarge / p5en.48xlarge), launch GPU instances into them, and optionally attach an S3-linked FSx for Lustre file system at `/data`.

> [!CAUTION]
> **This repository can spend real money — a lot of it.**
> Purchasing a capacity block is an **upfront, non-refundable** charge (typically tens of thousands of dollars). It **cannot be cancelled**, and `tofu destroy` does **not** refund it. FSx for Lustre bills continuously from the moment it is created, even before your capacity block starts. Read the runbooks in `docs/` before running any apply.

_Full documentation, workflow walkthroughs, and runbooks are completed in `docs/runbooks.md` and `docs/admin-access.md`._

## Repository layout

- `stacks/purchase/` — search capacity block offerings and (deliberately, double-confirmed) purchase one. Isolated state.
- `stacks/runtime/` — VPC, security, key pair, GPU instance(s), optional FSx for Lustre. Isolated state.
- `scripts/` — helper scripts (local SSH key generation).
- `docs/` — plans, runbooks, and admin access guide.

## Requirements

- OpenTofu >= 1.10 (S3-native state locking; this repo is developed against 1.11)
- AWS provider >= 6.53, < 7.0
- AWS credentials with EC2 capacity-block, VPC, FSx, and key-pair permissions

## State storage

State never lives in this repository (`.gitignore` excludes it). Local state is fine for a solo operator; for anything shared, use the commented S3 backend block in each stack's `versions.tf` (S3-native locking via `use_lockfile`, no DynamoDB needed). The commented `encryption` block adds OpenTofu client-side state encryption with an AWS KMS key as defense in depth.

## Contributing

Run `pre-commit install` after cloning. The `tofu_trivy` and `tofu_docs` hooks are shipped commented out — enable them if you have `trivy` / `terraform-docs` installed.
