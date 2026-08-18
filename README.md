# multi-scale-infrastructure

AWS infrastructure for the Multi-Scale project: OpenTofu configuration to purchase EC2 Capacity Blocks for ML (p5.48xlarge / p5en.48xlarge), launch GPU instances into them, and optionally attach an S3-linked FSx for Lustre file system at `/data`.

> [!CAUTION]
> **This repository can spend real money — a lot of it.**
> Purchasing a capacity block is an **upfront, non-refundable** charge (typically tens of thousands of dollars). It **cannot be cancelled**, `tofu destroy` does **not** refund it, and there is no trial window. FSx for Lustre bills continuously from the moment it is created — **even before your capacity block starts**. When the block ends, AWS terminates the instances and their root volumes are deleted: only `/data` (FSx) and S3 survive. Read [docs/runbooks.md](docs/runbooks.md) before running any apply.

Operational documentation:

- [docs/runbooks.md](docs/runbooks.md) — purchase, pre-activation provisioning, launch, block expiry and data safety, teardown order, next block, FSx toggling, credentials hygiene.
- [docs/admin-access.md](docs/admin-access.md) — connecting via EC2 Instance Connect, plus the sample admin IAM policy.

## What each apply creates — and spends

| Apply | Creates | Spends |
|---|---|---|
| **purchase** stack, search only (confirmation variables unset) | Nothing — a data-source lookup with review outputs | Free |
| **purchase** stack with `capacity_block_offering_id` + `expected_upfront_fee` set | The capacity block reservation | The **full upfront fee, immediately, non-refundable** — typically five figures |
| **runtime** stack with `launch_instance = false` | VPC, public subnet, IGW, security group, key pair; FSx for Lustre + S3 link if `enable_fsx = true` | VPC pieces are effectively free; **FSx bills hourly from creation**, block active or not |
| **runtime** stack with `launch_instance = true` | The GPU instance(s) in the block | Block compute is already paid; adds the gp3 root EBS volume(s) and data transfer |

## Repository layout

- `stacks/purchase/` — search capacity block offerings and (deliberately, double-confirmed) purchase one. Isolated state; **write-once** — one purchase per state.
- `stacks/runtime/` — VPC, security, key pair, GPU instance(s), optional FSx for Lustre. Isolated state; one deployment per block.
- `scripts/` — helper scripts ([scripts/generate-key.sh](scripts/generate-key.sh) for local SSH key generation).
- `docs/` — plans, runbooks, and the admin access guide.

The two stacks keep separate state on purpose: nothing you do in the runtime stack — including `tofu destroy` — can ever touch the non-refundable reservation.

## Requirements

- OpenTofu >= 1.10 (S3-native state locking; this repo is developed against 1.11)
- AWS provider >= 6.53, < 7.0
- AWS credentials with EC2 capacity-block, VPC, FSx, and key-pair permissions

## Quickstart: the two-stack workflow

The full ceremony, in order. Each step is expanded in [docs/runbooks.md](docs/runbooks.md).

### 1. Search for an offering (free)

```bash
cd stacks/purchase
cp terraform.tfvars.example terraform.tfvars
# edit: region, instance_type, instance_count, capacity_duration_hours,
#       optionally start_date_range / end_date_range
tofu init
tofu apply    # creates nothing — search only
```

An empty result can mean the wrong region for the chosen instance type, not "no capacity" — see [Region availability](#region-availability).

### 2. Review the offering

```bash
tofu output
# offering_id, offering_upfront_fee, offering_currency_code,
# offering_availability_zone, offering_start_date, offering_end_date
```

Check the fee, the AZ, the dates — and, if you plan to use FSx, that your S3 bucket lives in the same region as the block.

### 3. Confirm the purchase — in the same session (spends money)

Offerings are ephemeral quotes, and the fee re-verification runs at plan time — do this immediately after the review, never from a saved plan file. In `terraform.tfvars`:

```hcl
capacity_block_offering_id = "cbo-..."      # from offering_id
expected_upfront_fee       = "28800.00"     # from offering_upfront_fee, exact string
# expected_availability_zone = "us-east-1a" # optional extra pin
```

```bash
tofu apply    # charges the full fee upfront; blocked if a fresh lookup shows a different fee
tofu output reservation_id    # feed this to the runtime stack
```

### 4. Lock the purchase stack

In `terraform.tfvars`, set `search_enabled = false` (a check warns on every plan until you do). The stack is now write-once — a second block needs a fresh state or workspace ([runbook 1](docs/runbooks.md#1-purchase-a-capacity-block)).

### 5. Optional: pre-provision before the block starts

```bash
cd ../runtime
cp terraform.tfvars.example terraform.tfvars
# set: capacity_reservation_id (from step 3), admin_cidr_blocks,
#      one of public_key (scripts/generate-key.sh prints it) or existing_key_pair_name,
#      and optionally enable_fsx + fsx_s3_bucket
tofu init
tofu apply    # with launch_instance = false: VPC + FSx now, instances later
```

This is the window to stage training data and pre-pull container images — see [runbook 2](docs/runbooks.md#2-pre-activation-provisioning-launch_instance--false). FSx starts billing here.

### 6. Launch when the block is active

```bash
aws ec2 describe-capacity-reservations \
  --capacity-reservation-ids cr-... \
  --query 'CapacityReservations[0].State' --output text   # wait for "active"
```

Set `launch_instance = true` and apply. While the block is still `scheduled`, the apply fails with a readable precondition message — that is by design, not breakage. Then connect using the `connect_commands_eic` output ([docs/admin-access.md](docs/admin-access.md)).

## Alternative: buy the block manually

Purchase-as-code is optional. Buying the capacity block in the AWS console (EC2 → Capacity Reservations → Capacity Blocks for ML) or with `aws ec2 purchase-capacity-block` and feeding the resulting reservation ID straight into the runtime stack's `capacity_reservation_id` is **fully supported** — and simpler when you don't need the purchase itself under version control. The runtime stack does not care where the reservation came from; it derives the AZ, instance type, and capacity from the reservation ID either way. In that case you never touch `stacks/purchase/` at all.

## Region availability

Capacity block availability differs by region **and** instance type (as of 2026-08 — AWS expands this over time, so treat the table as a hint, not validation; it is kept in sync with `stacks/purchase/terraform.tfvars.example`). An **empty search result can mean the wrong region for the chosen type**, not "no capacity".

| Region | p5.48xlarge | p5en.48xlarge |
|---|---|---|
| us-east-1 | yes | yes |
| us-east-2 | yes | yes |
| us-west-1 | yes | yes |
| us-west-2 | yes | yes |
| eu-north-1 | yes | yes |
| eu-west-2 | yes | yes |
| ap-northeast-1 | yes | yes |
| ap-south-1 | yes | yes |
| ap-southeast-2 | yes | yes |
| ap-southeast-3 | yes | yes |
| sa-east-1 | yes | — |
| eu-south-2 | — | yes |
| ap-northeast-2 | — | yes |

## AMI: Deep Learning Base — and what it does not include

The default AMI is the **Deep Learning Base OSS NVIDIA Driver AMI (Amazon Linux 2)**, resolved via SSM at plan time. Two things to know:

- **The AL2 flavor is frozen.** Amazon Linux 2 reached end of life on June 30, 2026; the AL2 DLAMI is frozen at its final release and receives **no further security patches**. It still resolves and works, but `ami_flavor = "al2023"` is the patched alternative — same Base DLAMI, current OS. An explicit `ami_id` bypasses SSM resolution entirely.
- **"Base" means base.** The Base DLAMI ships NVIDIA drivers, Docker, and the NVIDIA container toolkit — **no PyTorch, no frameworks**. Bring your frameworks as containers, and pre-pull the images during the pre-activation window ([runbook 2](docs/runbooks.md#2-pre-activation-provisioning-launch_instance--false)) rather than burning roughly $100/hour of block time on `docker pull`.

## State storage

State never lives in this repository (`.gitignore` excludes it). Local state is fine for a solo operator; for anything shared, use the commented S3 backend block in each stack's `versions.tf` (S3-native locking via `use_lockfile`, no DynamoDB needed). The commented `encryption` block adds OpenTofu client-side state encryption with an AWS KMS key as defense in depth: no secrets are ever written to state by this configuration (key pairs register public material only), and encrypting the state file keeps that posture even if the backend bucket's controls slip.

## Verification and contributing

Run `pre-commit install` after cloning. The gates:

- `tofu fmt` / `tofu validate` — style and schema correctness, per stack.
- `tflint` — provider-aware argument linting.
- `tofu test` — 6 purchase-stack and 26 runtime-stack tests, all mocked and plan-only: they prove the purchase gating, preconditions, and validations **without AWS credentials and without spending anything**. Run them from each stack directory.
- The `tofu_trivy` and `tofu_docs` hooks ship commented out in `.pre-commit-config.yaml` — enable them once `trivy` / `terraform-docs` are installed locally.

No gate performs a real AWS apply. Real-account smoke checks (connecting, mounting `/data`) are operator steps documented in [docs/runbooks.md](docs/runbooks.md).
