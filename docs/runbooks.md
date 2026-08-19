# Operational runbooks

The procedures that spend money or destroy data, in the order you will meet them. Every step here names the actual variables, outputs, and error messages of the two stacks — if the code and this document ever disagree, the code wins and this file has a bug.

1. [Purchase a capacity block](#1-purchase-a-capacity-block)
2. [Pre-activation provisioning (`launch_instance = false`)](#2-pre-activation-provisioning-launch_instance--false)
3. [Launch instances](#3-launch-instances)
4. [Block expiry and data safety](#4-block-expiry-and-data-safety)
5. [Teardown — the exact order](#5-teardown--the-exact-order)
6. [Next block and overlapping blocks](#6-next-block-and-overlapping-blocks)
7. [Toggling FSx on a live deployment](#7-toggling-fsx-on-a-live-deployment)
8. [Credentials hygiene on the instances](#8-credentials-hygiene-on-the-instances)

---

## 1. Purchase a capacity block

**Money:** the confirm step charges the full block fee upfront, immediately, non-refundably.

### 1.1 Search (free)

In `stacks/purchase/`, copy `terraform.tfvars.example` to `terraform.tfvars` and set the search inputs: `region`, `instance_type` (`p5.48xlarge` or `p5en.48xlarge`), `instance_count`, `capacity_duration_hours` (whole days, in hours), and optionally `start_date_range` / `end_date_range`. Then:

```bash
tofu init
tofu apply    # search only — creates nothing, costs nothing
```

An empty result can mean the wrong region for the chosen type — check the region table in the README before concluding there is no capacity.

### 1.2 Review the offering

```bash
tofu output
```

Pre-purchase review checklist:

- [ ] `offering_upfront_fee` (and `offering_currency_code`) — is this the money you intend to spend?
- [ ] `offering_availability_zone` — everything in the runtime stack will live in this AZ.
- [ ] The offering's **actual start/end dates** — is the window right? Instances terminate before the end date (runbook 4). The stack cannot show these before purchase (`requested_start_date_range` / `requested_end_date_range` only echo your own search inputs): get them from `aws ec2 describe-capacity-block-offerings` before confirming. After purchase, `reservation_start_date` / `reservation_end_date` show the real dates.
- [ ] **If FSx is planned:** the S3 bucket you will link at `/data` must live in the block's region. Check the bucket's region now, next to the fee and AZ — a wrong-region bucket fails only at DRA creation, after both the block and FSx are already billing.

### 1.3 Confirm — in the SAME session

In `terraform.tfvars`, pin the reviewed values:

```hcl
capacity_block_offering_id = "cbo-..."      # from offering_id
expected_upfront_fee       = "28800.00"     # from offering_upfront_fee — the exact string
# expected_availability_zone = "us-east-1a" # optional extra pin, also re-verified
```

```bash
tofu apply
```

The purchase is blocked with a readable error unless a **fresh** offering lookup still shows exactly the fee (and AZ, if pinned) you confirmed.

**Why same-session, and why never a saved plan file:** offering IDs are ephemeral quotes, and the fee-verification precondition evaluates at **plan** time. `tofu plan -out=purchase.plan` followed by a later `tofu apply purchase.plan` gets **no re-check at apply** — the only remaining backstop is AWS rejecting the stale offering ID at purchase, which surfaces as a raw API error rather than a friendly message. Search, review, and confirm in one sitting; if anything drifted, re-run the search and re-review.

### 1.4 After success: lock the stack

In `terraform.tfvars`, set `search_enabled = false` **and, at the same moment, overwrite the offering ID with a sentinel**:

```hcl
search_enabled             = false
capacity_block_offering_id = "cbo-PURCHASED-see-state"
```

Why the sentinel: with search off, the fee-verification precondition short-circuits — so these locked tfvars replayed against a **fresh state** (new workspace, re-clone) would purchase a new block with zero verification. The live reservation ignores the change (`ignore_changes`), while any accidental fresh-state purchase dies at the AWS API on the guaranteed-invalid offering ID.

Until you set `search_enabled = false`, every plan warns:

> A capacity block reservation is configured while search_enabled is still true. …

This matters: offering searches can error on zero results, and a drifted or empty lookup must never be able to disturb an existing, non-refundable reservation. With search disabled, the money gate deliberately short-circuits to pass for the reservation already in state.

Record the handoff values: `reservation_id` (feeds the runtime stack's `capacity_reservation_id`), `reservation_availability_zone`, `reservation_start_date`, `reservation_end_date`.

### 1.5 The stack is write-once

**One purchase per state.** The reservation carries `prevent_destroy` and `ignore_changes` on its offering ID; the stack has no notion of "replace the block". A second block means a fresh state — a new workspace (`tofu workspace new block-2`) or a separate backend key — never editing this one.

### Manual alternative

You can skip this stack entirely: buy the block in the AWS console or with `aws ec2 purchase-capacity-block`, and feed the reservation ID straight into the runtime stack. Fully supported; see the README.

---

## 2. Pre-activation provisioning (`launch_instance = false`)

**Money:** FSx bills from the moment it is created — before the block starts. That is the point (the block's ~$100/hour clock is not running yet), but it is real spend.

Between purchase and the block's start date, apply the runtime stack with `launch_instance = false`: it creates the VPC, subnet (in the reservation's AZ, derived automatically), security group, key pair — and FSx plus its S3 link, if `enable_fsx = true`. The instance resources stay at zero.

### 2.1 Pre-creating FSx does NOT preload your data

The data repository association imports **metadata only** (`batch_import_meta_data_on_create = true` — `/data` lists the whole bucket immediately). File **contents hydrate lazily on first read** from a mounted client. An FSx file system sitting unmounted before the block starts has warmed nothing.

To actually stage the data, launch a cheap temporary non-GPU instance (any small type) in the **same subnet and security group**, mount `/data` on it (Lustre client install + the `fsx_manual_mount_command` output — see runbook 7 for the exact commands), and run a restore sweep:

```bash
nohup sudo lfs hsm_restore $(sudo lfs find /data -type f) &
```

That command is **illustrative** — for large trees, prefer a batched parallel form such as `sudo lfs find /data -type f -print0 | xargs -0 -n 64 -P 8 sudo lfs hsm_restore`. Verify with spot reads, then terminate the temporary instance. The hydrated data stays in FSx.

This window is also the time to **pre-pull container images** onto a plan: the Base DLAMI has Docker and the NVIDIA container toolkit but no frameworks — pull your training images in the first minutes of the block (or bake an AMI) instead of mid-run.

### 2.2 p5en + the frozen AL2 AMI: verify before committing

The default `ami_flavor = "al2"` resolves the AL2 Deep Learning Base AMI, **frozen since June 2026**. p5en's newer NIC/driver stack may want drivers newer than that freeze. Before committing a block to the AL2 AMI on p5en, verify the combination works for your workload — and if in doubt, set `ami_flavor = "al2023"` (patched, current drivers) or pin an explicit `ami_id`.

---

## 3. Launch instances

### 3.1 Wait for the reservation to be `active`

```bash
aws ec2 describe-capacity-reservations \
  --capacity-reservation-ids cr-... \
  --query 'CapacityReservations[0].State' --output text
```

While the block is still `scheduled`, an apply with `launch_instance = true` fails with a precondition message of this shape — **by design**, not breakage:

> Capacity block cr-... is "scheduled", not "active" — instances can only launch after the block's start time. Wait for the start time, or set launch_instance = false to pre-provision networking and FSx now.

### 3.2 Apply

Set `launch_instance = true` (and `instance_count`) and apply. Two capacity rules are enforced:

- `instance_count` **must not exceed** the reservation's available capacity — a precondition blocks the plan if it does.
- **Under-subscription only warns** (the `capacity_block_under_subscribed` check): launching fewer instances than the block holds is legal and sometimes deliberate, but the unused capacity is already paid for and cannot be refunded. Read the warning; make it a decision, not an accident.

The instance type is taken from the reservation itself — you are never asked for it twice.

### 3.3 First connect

Use the `connect_commands_eic` output — one ready-to-paste command per instance:

```bash
aws ec2-instance-connect ssh --instance-id i-... --os-user ec2-user
```

The CLI path connects **from your own IP**, which must be in `admin_cidr_blocks` (see [docs/admin-access.md](admin-access.md) — set it before applying). The **browser-console** EC2 Instance Connect path needs nothing: the AWS service ranges are always admitted.

---

## 4. Block expiry and data safety

### 4.1 The real deadline is 11:00 UTC, not 11:30

On the block's final day, **AWS begins terminating instances at 11:00 UTC**; the block itself ends at 11:30 UTC. Plan around 11:00. The `reservation_end_date` output (purchase stack) tells you the day.

### 4.2 What dies, what survives

- **Root volumes are deleted with the instances** (`delete_on_termination = true`, deliberate). Anything on the root disk — home directories, `/tmp`, unpushed containers — is gone.
- **Only `/data` (FSx) and S3 survive.** Checkpoint to `/data` and let auto-export carry it to S3, or write to S3 directly.

### 4.3 Auto-export is asynchronous — verify before trusting S3

FSx→S3 auto-export lags writes. Before you rely on S3 having a file, check its HSM state on a mounted instance:

```bash
sudo lfs hsm_state /data/checkpoints/latest.pt
# exported files show: ... (archived) ...
```

A file that does not show `archived` has not been exported yet. Alternatively spot-check object timestamps in the bucket (`aws s3 ls s3://<bucket>/checkpoints/`).

**Checkpoint early, not at 10:55.** A final checkpoint written minutes before termination may never finish exporting before the instance — and, at teardown, the file system — disappears.

---

## 5. Teardown — the exact order

Order matters. Data safety first, then the runtime stack, then the purchase-stack ledger entry.

### 5.1 Verify FSx→S3 export is complete

Runbook 4.3: `sudo lfs hsm_state` on everything you care about (all `archived`), or timestamp spot-checks in S3. If nothing is mounted anymore, spot-check S3 against what you expect to exist.

### 5.2 Destroy the runtime stack

```bash
cd stacks/runtime
tofu destroy
```

This **destroys the FSx file system — any data not yet exported to S3 is lost permanently.** The interactive confirmation prompt is your last chance; do not script `-auto-approve` around it here.

### 5.3 The purchase stack: `state rm`, never `destroy`

```bash
cd stacks/purchase
tofu destroy    # BLOCKED by prevent_destroy — this is BY DESIGN
```

A capacity block reservation cannot be cancelled or refunded; it simply expires on its own at the end of its window. There is nothing in AWS to destroy — only a state entry to retire.

**First**, remove `capacity_block_offering_id` / `expected_upfront_fee` from `terraform.tfvars` (or confirm the offering ID is still the `"cbo-PURCHASED-see-state"` sentinel from runbook 1.4). Do this **before** touching state: with the reservation removed from state but confirmation variables still set, the very next plan would plan a fresh, unverified purchase.

**Then** retire the state entry:

```bash
tofu state rm 'aws_ec2_capacity_block_reservation.this[0]'
```

The stack then plans clean. **Never edit the `lifecycle` block just to make `destroy` work** — the guard exists precisely so that no plausible-looking command sequence can appear to "undo" a non-refundable purchase.

---

## 6. Next block and overlapping blocks

### 6.1 One runtime deployment per block

The runtime stack serves exactly one reservation at a time. For the next block: tear down (runbook 5, steps 1–2), then apply again with the new `capacity_reservation_id`.

**In-place retargeting is unsupported.** A new block in a different AZ cascades: the subnet is AZ-pinned, so it gets replaced, which replaces the FSx file system (destroying its contents) and the instances with it. Destroy-then-apply makes that explicit instead of letting a routine-looking plan eat the file system.

### 6.2 Overlapping blocks

If the next block is purchased before the current one ends, run a **separate runtime state or workspace per reservation** — mirroring the purchase stack's one-per-state rule:

```bash
cd stacks/runtime
tofu workspace new block-2
tofu apply    # with the new reservation's capacity_reservation_id in its own tfvars
```

Each workspace gets its own VPC, FSx, and instances; neither deployment can disturb the other.

---

## 7. Toggling FSx on a live deployment

### 7.1 Disabling `enable_fsx` DESTROYS the file system

Flipping `enable_fsx = false` on a live deployment plans the destruction of the FSx file system and its S3 link. **Verify export first** (runbook 4.3) — unexported data is unrecoverable.

### 7.2 Enabling FSx after instances are running does NOT mount it

`user_data` runs once at first boot, and `user_data_replace_on_change = false` is deliberate — toggling FSx must never silently stop or replace a running capacity-block instance mid-block. So enabling FSx later creates the file system but leaves `/data` unmounted on the existing instances. Mount manually on each one:

```bash
# 1. Install the Lustre client for the OS generation:
sudo amazon-linux-extras install -y lustre     # AL2
sudo dnf install -y lustre-client              # AL2023

# 2. Run the exact mount command from the stack output:
tofu output fsx_manual_mount_command
# -> sudo mkdir -p /data && sudo mount -t lustre -o relatime,flock <dns>@tcp:/<mount_name> /data
```

The manual mount does not persist across reboots (no fstab entry) — remount after any reboot, or prefer the clean path: **launch FSx before the instances** (runbook 2), so first-boot `user_data` installs the client and writes the fstab entry itself.

---

## 8. Credentials hygiene on the instances

The instances launch with **no IAM instance profile** — they have no AWS identity, on purpose. Two rules follow:

- **Never paste long-lived AWS keys onto a box.** The instances are SSH-reachable, short-lived, and terminated by AWS on a schedule; a leaked key outlives all of that.
- **Route S3 checkpointing through `/data` auto-export.** Writing checkpoints to `/data` and letting the DRA export them (runbook 4.3 to verify) gives you S3 durability with zero credentials on the instance.

If a workload genuinely must call AWS APIs from the instance, that is a deliberate infrastructure change (an instance profile with a scoped role) — not an `aws configure` on the box.
