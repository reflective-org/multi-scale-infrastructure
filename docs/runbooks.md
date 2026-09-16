# Operational runbooks

The procedures that spend money or destroy data, in the order you will meet them. Every step here names the actual variables, outputs, and error messages of the stacks — if the code and this document ever disagree, the code wins and this file has a bug.

Runbooks 1–8 cover the capacity-block stacks (`stacks/purchase/` + `stacks/runtime/`); runbooks 9–14 cover the on-demand GPU fleet (`stacks/fleet/`).

1. [Purchase a capacity block](#1-purchase-a-capacity-block)
2. [Pre-activation provisioning (`launch_instance = false`)](#2-pre-activation-provisioning-launch_instance--false)
3. [Launch instances](#3-launch-instances)
4. [Block expiry and data safety](#4-block-expiry-and-data-safety)
5. [Teardown — the exact order](#5-teardown--the-exact-order)
6. [Next block and overlapping blocks](#6-next-block-and-overlapping-blocks)
7. [Toggling FSx on a live deployment](#7-toggling-fsx-on-a-live-deployment)
8. [Credentials hygiene on the instances](#8-credentials-hygiene-on-the-instances)
9. [Fleet launch](#9-fleet-launch)
10. [Fleet updates and scaling](#10-fleet-updates-and-scaling)
11. [Fleet partial capacity](#11-fleet-partial-capacity)
12. [Fleet status and debugging](#12-fleet-status-and-debugging)
13. [Fleet completion and teardown](#13-fleet-completion-and-teardown)
14. [Fleet credentials stance](#14-fleet-credentials-stance)

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

- `instance_count` **must not exceed** the block's total size — a precondition blocks the plan if it does. (The total, not the remaining capacity: your own running instances shrink the remaining counter, and comparing against it would fail every plan after a full launch. A true launch-time capacity race is rejected by AWS itself.)
- **Under-subscription only warns** (the `capacity_block_under_subscribed` check): launching fewer instances than the block holds is legal and sometimes deliberate, but the unused capacity is already paid for and cannot be refunded. Read the warning; make it a decision, not an accident.

The instance type is taken from the reservation itself — you are never asked for it twice.

### 3.3 First connect

Use the `connect_commands_eic` output — one ready-to-paste command per instance:

```bash
aws ec2-instance-connect ssh --instance-id i-... --os-user ec2-user
```

The CLI path connects **from your own IP**, which must be in `admin_cidr_blocks` (see [docs/admin-access.md](admin-access.md) — set it before applying). The **browser-console** EC2 Instance Connect path needs nothing: the AWS service ranges are always admitted.

If FSx is enabled, verify `/data` really is the Lustre mount **before writing anything to it**:

```bash
findmnt /data    # expect FSTYPE lustre, source <fs-id>@tcp:/<mount_name>
```

If it is missing, first-boot mounting failed: `user_data` leaves a marker at `/etc/profile.d/00-fsx-broken.sh` that prints a loud warning on every login, and `/data` is left **immutable** (`chattr +i`) so stray checkpoint writes fail with `EPERM` instead of quietly landing on the root volume. Check `/var/log/cloud-init-output.log` for the install/mount error, fix it, and re-run the mount (runbook 7.2 has the manual commands) — a successful re-run of the fragment clears the marker.

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

`user_data` runs once at first boot, and the instances **ignore `user_data` changes after creation** (lifecycle `ignore_changes`, deliberate: without it, the changed `user_data` would apply as an in-place update that stops and starts every running capacity-block instance mid-block — without ever re-running cloud-init). So enabling FSx later changes **nothing** on the running instances: no stop/start, no replacement, and `/data` stays unmounted on them. Only an instance created *after* the flip (an `instance_count` increase or a replacement) renders the current configuration and mounts `/data` at first boot. On the existing instances, mount manually on each one:

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

If a workload genuinely must call AWS APIs from the instance, that is a deliberate infrastructure change (an instance profile with a scoped role) — not an `aws configure` on the box. The fleet stack is exactly that deliberate change — runbook 14 explains its role and the enumerated grants.

---

## 9. Fleet launch

**Money:** on-demand billing starts the moment the instances launch and **the meter runs until you act** — `instance_count` × ~$2/hour for the default `g6e.xlarge`, plus the gp3 root volumes. Pausing (`instance_count = 0`) or destroying stops it; nothing stops it for you.

### 9.1 Pre-check the vCPU quota (the most likely first-apply failure)

The fleet's `g6e` instances draw from the **"Running On-Demand G and VT instances" vCPU quota (`L-DB2E81BA`), which defaults to 0 on new accounts** — so the most likely first-apply failure is quota, not capacity. A `g6e.xlarge` has 4 vCPUs: a fleet of X nodes needs at least 4·X vCPUs of quota. Check before applying:

```bash
aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA
```

If `Quota.Value` is below 4·X, request an increase (approval is not instant — do this ahead of the day you need the fleet):

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-DB2E81BA --desired-value 32   # e.g. 8 × g6e.xlarge
```

### 9.2 Pre-check AZ offerings

`g6e` is offered in roughly a dozen regions (see the README's fleet section), and within a region **not every AZ offers it**. List the AZs that do:

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=instance-type,Values=g6e.xlarge --region <region>
```

Set `subnet_azs` to suffixes of AZs that appear in the output (e.g. `["a", "b"]` for `us-east-2a`/`us-east-2b`). Instances spread across the listed AZs round-robin.

### 9.3 The tfvars walk-through

In `stacks/fleet/`, copy `terraform.tfvars.example` to `terraform.tfvars`. A minimal working file:

```hcl
region            = "us-east-2"
subnet_azs        = ["a", "b"]                       # from the 9.2 offering check
admin_cidr_blocks = ["203.0.113.7/32"]               # your IP: curl -s ifconfig.me
public_key        = "ssh-ed25519 AAAA... you@host"   # scripts/generate-key.sh prints this line

docker_image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/train@sha256:<digest>"
s3_bucket    = "my-training-data"

instance_count = 4
```

- `docker_image` — the container every node runs. A private-ECR URI is detected by shape and gets automatic login at boot plus a pull grant scoped to exactly that repository (registry region parsed from the URI, so cross-region pulls work); any other registry (`ghcr.io`, `public.ecr.aws`, `docker.io`, ...) gets no ECR grant. **Digest-pin (`@sha256:...`)** — see runbook 10.
- `s3_bucket` — bare bucket name, not an `s3://` URI; the bucket is yours, not managed by this stack. The role reads the whole bucket and writes only under `s3_output_prefix` (default `"outputs"`). **Keep input data outside that prefix** — runbook 14.
- Key material — set exactly one of `public_key` (registered under the `key_pair_name` prefix; AWS appends a random suffix) or `existing_key_pair_name`.
- `admin_cidr_blocks` — required for CLI-initiated `aws ec2-instance-connect ssh` and plain ssh; the browser-console EIC path needs no entry ([docs/admin-access.md](admin-access.md)).
- Optional: `container_env` (never secrets — runbook 14), `container_run_args` (e.g. `"--shm-size=8g"` for PyTorch dataloaders), `restart_policy` / `restart_max_retries`.

### 9.4 Apply

```bash
tofu init
tofu apply
```

Each node boots, logs into ECR if needed, pulls the image, and runs exactly one container named `fleet-job` with `NODE_INDEX` in [0, X) and `NODE_COUNT = X` injected. Expect occasional benign plan diffs on the `ssh_eic` security-group rules later — the EC2 Instance Connect service ranges drift over time; just apply them.

### 9.5 Verify every shard is running

```bash
tofu output connect_commands_eic    # one ready-to-paste command per node index
aws ec2-instance-connect ssh --instance-id i-... --os-user ec2-user
```

On each node:

```bash
docker inspect -f '{{.State.Status}}' fleet-job   # expect: running
docker logs fleet-job --tail 50
```

A node whose boot failed prints a loud warning on every login (the `/etc/profile.d/00-fleet-broken.sh` marker — runbook 12.3). For the whole-fleet status one-liner, see runbook 12.2. **N running containers out of X is not a healthy fleet** — runbook 11.3.

---

## 10. Fleet updates and scaling

### 10.1 Replacement IS the deployment mechanism

**Any change to `docker_image`, `container_env`, `container_run_args`, `restart_policy` / `restart_max_retries`, `enable_container_logs`, or `instance_count` replaces every instance in the fleet.** The shard math, the image, and every env var are baked into `user_data`, and cloud-init runs once per instance — so the stack sets `user_data_replace_on_change = true` and a fresh boot is the only deployment path. This is the exact inverse of the runtime stack (which ignores `user_data` changes to protect prepaid capacity-block instances — runbook 7.2); the fleet is stateless, cheap capacity, and the plan will honestly say `must be replaced`. That is the mechanism working, not breakage.

There is deliberately no `create_before_destroy`: an overlap would run two live nodes with the same `NODE_INDEX`, double-processing (and double-writing) that shard.

### 10.2 Digest-pin the image

Use `@sha256:...` URIs, not mutable tags:

```hcl
docker_image = "123456789012.dkr.ecr.us-east-2.amazonaws.com/team/train@sha256:4f5c..."
```

With a `:latest`-style tag, a partial replacement (say, after a capacity failure — runbook 11) re-pulls whatever the tag points at *now*, and the fleet goes version-heterogeneous without any diff in the plan. The ECR URI parser handles digest pins and nested repository paths (`team/train@sha256:...`); deploying a new version = changing the digest and applying.

### 10.3 A replacement re-runs EVERY index from scratch

Replaced nodes restart their shards from zero — the stack has no memory of partial progress. **Make the container idempotent per shard**: check for a completion marker (or the output object itself) under `s3://<s3_bucket>/<s3_output_prefix>/` at startup and exit 0 if the shard is already done. Then a fleet-wide replacement after 90% completion re-does only the missing 10%.

### 10.4 Scaling, and why count changes are two-phase

Scale-down removes tail indices (`instance_count` 8 → 6 destroys nodes 6 and 7) — but any count change also rewrites `NODE_COUNT` in every survivor's `user_data`, so **all** nodes are replaced, not just the tail. Because new tail indices are created in parallel with the old nodes' destroy, a direct count change briefly runs old-count and new-count nodes side by side **with conflicting `NODE_COUNT`** — two different shard partitions of the same input, writing to the same prefix. The safe sequence is two-phase:

```bash
# 1. instance_count = 0 in terraform.tfvars
tofu apply
tofu output instance_ids    # confirm: {} — the fleet is empty

# 2. instance_count = <new X> in terraform.tfvars
tofu apply
```

Image/env-only changes (count unchanged) do not shift the shard math and need no pause — every replacement node computes the same partition as its predecessor.

---

## 11. Fleet partial capacity

### 11.1 Quota and capacity failures look different — read the error

An apply can fail on some indices and succeed on others. The two failure shapes:

**Quota** (fix: runbook 9.1 — retrying or steering AZs will not help):

> Error: creating EC2 Instance: ... VcpuLimitExceeded: You have requested more vCPU capacity than your current vCPU limit of 0 allows for the instance bucket that the specified instance type belongs to.

**Insufficient capacity — "ICE"** (AWS is genuinely out of `g6e` in that AZ right now):

> Error: creating EC2 Instance: ... InsufficientInstanceCapacity: We currently do not have sufficient g6e.xlarge capacity in the Availability Zone you requested (us-east-2a).

### 11.2 Recovering from ICE: steer `subnet_azs`

Instances spread across the `subnet_azs` subnets by `element()` — index 0 → first AZ, index 1 → second, wrapping round-robin. A plain re-apply therefore **re-targets the same failing AZ for the same indices** every time. Instead, steer: re-run the offering check (runbook 9.2), then drop or replace the failing AZ's suffix in `subnet_azs`.

**Changing `subnet_azs` reorders the `element()` spread and replaces instances** — the surviving nodes' subnets shift. Steer it while the fleet is down (during a failed launch, or after `instance_count = 0` — runbook 10.4), or expect the plan to replace running nodes.

### 11.3 A partial fleet means an incomplete batch

Sharding is static: node i processes shard i of X, and nothing rebalances. If only N of X instances launched, the running containers are healthy, busy, and **the batch can never complete** — the missing indices' shards are simply never processed. Always compare:

```bash
tofu output instance_ids    # keyed by node index — every index in [0, X) must be present
```

against `instance_count` after any apply that reported errors, before trusting the fleet to finish.

---

## 12. Fleet status and debugging

### 12.1 The outputs

`instance_ids`, `instance_public_ips`, and `instance_public_dns` are maps keyed by node index; `connect_commands_eic` and `connect_commands_ssh` print one ready-to-paste command per index; `container_log_group` names the CloudWatch log group (null when `enable_container_logs = false`).

### 12.2 Whole-fleet container status in one loop

Plain ssh over the public DNS names (your IP must be in `admin_cidr_blocks`, and the fleet's private key loaded, e.g. via `ssh-add`):

```bash
tofu output -json instance_public_dns \
  | jq -r 'to_entries[] | "\(.key) \(.value)"' \
  | while read -r idx host; do
      printf 'node %s: ' "$idx"
      ssh -o BatchMode=yes -o ConnectTimeout=5 "ec2-user@$host" \
        "docker inspect -f '{{.State.Status}}' fleet-job" 2>/dev/null || echo unreachable
    done
```

Expect `running` on every index. `exited` means the shard finished (exit 0, never re-run under the default `restart_policy = "on-failure"`) or exhausted its retries — `docker inspect -f '{{.State.ExitCode}}' fleet-job` distinguishes them.

### 12.3 A broken node announces itself

Any boot failure (docker not up, ECR login, pull, or `docker run`) leaves three loud traces on the node:

- a warning printed by **every** SSH login, via the marker file `/etc/profile.d/00-fleet-broken.sh`;
- a `FATAL:` line in `/var/log/cloud-init-output.log` saying which step failed;
- a nonzero cloud-init exit.

The boot script is idempotent by design — after fixing the cause (a bad image reference, a missing ECR grant), re-run it in place:

```bash
sudo bash /var/lib/cloud/instance/scripts/part-001
```

A successful re-run removes the marker. Alternatively, `tofu apply -replace='aws_instance.fleet[<index>]'` recycles just that node.

### 12.4 Container logs in CloudWatch

With `enable_container_logs = true` (the default), every container's stdout/stderr ships to the log group `/multi-scale-fleet/containers`, one stream per node named `multi-scale-fleet-<index>` — container restarts keep appending to the same stream:

```bash
aws logs tail /multi-scale-fleet/containers --follow                                  # whole fleet
aws logs tail /multi-scale-fleet/containers --log-stream-names multi-scale-fleet-3    # one node
```

**This log group is Terraform-managed: `tofu destroy` deletes it and every log event in it** — runbook 13.3.

---

## 13. Fleet completion and teardown

### 13.1 Verify the outputs before touching anything

The batch's results live under the output prefix — confirm every shard delivered before pausing or destroying:

```bash
aws s3 ls s3://<s3_bucket>/<s3_output_prefix>/ --recursive
```

Count against what X shards should have produced (per-shard completion markers — runbook 10.3 — make this a one-glance check). The instances hold nothing durable: root volumes die with them (`delete_on_termination`), and **only what reached S3 survives**.

### 13.2 Pause vs destroy

- **Pause:** set `instance_count = 0` and apply. The GPU meter stops; the VPC, security group, key pair, IAM role, and log group persist at near-zero cost, and the next batch is one `instance_count` change away. This is the right resting state between runs.
- **Destroy:** `tofu destroy` removes everything, including the networking, role — and the log group.

### 13.3 What destroy kills

**Destroy is SIGKILL for the containers.** Terminating an instance gives a running container no meaningful chance to finish an S3 upload, and an interrupted multipart upload leaves **invisible abandoned parts that bill forever** (they never appear in `aws s3 ls`). Since the bucket is operator-owned (this stack never touches it), add a lifecycle rule once per bucket:

```bash
aws s3api put-bucket-lifecycle-configuration --bucket <s3_bucket> \
  --lifecycle-configuration '{"Rules": [{"ID": "abort-incomplete-mpu", "Status": "Enabled",
    "Filter": {}, "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}}]}'
```

**Destroy also deletes the CloudWatch log group `/multi-scale-fleet/containers` and every log in it** — the group is Terraform-managed, not driver-created. Read or export anything you still need **before** the destroy:

```bash
aws logs tail /multi-scale-fleet/containers --since 72h > fleet-logs.txt
```

---

## 14. Fleet credentials stance

### 14.1 Why this stack has an instance role when runbook 8 refuses one

The runtime stack's instances carry no AWS identity because FSx's S3 link moves their data without credentials. The fleet has no FSx: its containers must pull an image and move data through S3 themselves, and the alternative to a role is pasting static keys onto boxes — exactly what runbook 8 forbids. So the fleet role exists, and it grants **exactly** this and nothing else:

- `ecr:GetAuthorizationToken` on `*` — an API constraint: the action cannot be resource-scoped — plus `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, and `ecr:BatchGetImage` on the **one** repository ARN parsed from `docker_image`; the whole ECR grant exists **only** when the image URI is private ECR.
- `s3:ListBucket` on `s3_bucket`, and `s3:GetObject` bucket-wide.
- `s3:PutObject`, `s3:AbortMultipartUpload`, and `s3:ListMultipartUploadParts` **only** under `<s3_bucket>/<s3_output_prefix>/*`.
- `logs:CreateLogStream` and `logs:PutLogEvents` on the fleet log group only — and only while `enable_container_logs = true`.

### 14.2 The no-secrets rule

**Never put secrets in `container_env` or `container_run_args`.** Both are baked into `user_data`, so every value lands in **plaintext OpenTofu state** and is readable by anyone with `ec2:DescribeInstanceAttribute`:

```bash
aws ec2 describe-instance-attribute --instance-id i-... --attribute userData   # base64 of the whole boot script
```

Fetch secrets **at runtime, inside the container**, using the instance role as the credential. The role above has no Secrets Manager or SSM grant — adding a scoped read for the one secret the workload needs is the deliberate infrastructure change runbook 8 describes, not a reason to widen `container_env`.

### 14.3 Shell access inherits the role

Anyone who can SSH to a node (any CIDR in `admin_cidr_blocks`, any admin with EIC push rights) can read the role's credentials from IMDS — including the **bucket-wide `s3:GetObject`**. Treat node shell access as read access to the entire `s3_bucket`, and do not co-locate unrelated sensitive data in it.

### 14.4 Keep inputs OUTSIDE the output prefix

The write grant is scoped to `<s3_output_prefix>/*`, which is what keeps input data read-only to the fleet. An input object stored **under** the prefix loses that guarantee: any node (or anything that compromises a node) can overwrite it. Inputs anywhere else in the bucket; outputs under the prefix; never mix.

### 14.5 IMDSv2 hop limit is 2 — leave it

The instances enforce IMDSv2 with `http_put_response_hop_limit = 2` so the **container** can reach the role credentials through docker's NAT hop — both the `awslogs` log driver and any AWS SDK inside the container depend on it. "Hardening" it to 1 breaks the fleet's entire credential path.
