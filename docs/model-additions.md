# Model-additions host

`stacks/model-additions/` builds the machine that runs the aerosol model-addition
automation: two self-hosted GitHub Actions runners that add a scientist's model to the
aerosol microphysics intercomparison, with an agent working inside Docker containers.
The automation itself, its workflows and its operating guide live in the comparison
repository (`docs/automation/RUNBOOK.md` there); this stack is only the machine.

## What it creates

| Resource | Notes |
|---|---|
| VPC, public subnet, internet gateway, route | Self-contained; no dependency on any other stack |
| Security group | **No inbound rules.** Outbound HTTPS and HTTP only |
| IAM role and instance profile | `AmazonSSMManagedInstanceCore` only: shells go through SSM Session Manager |
| EC2 instance | Ubuntu 24.04, `m7i.2xlarge` by default, CPU only. IMDSv2 with hop limit 1, so containers can't reach the instance role |
| Data volume | gp3, 200 GiB by default, mounted at `/srv/model-additions`; holds each addition's state and working folder |
| Instance state | `running = true/false` starts or stops the instance |

The first-boot script (`templates/user_data.sh.tpl`) installs Docker Engine (and checks
it is 29.8.2 or newer), the GitHub CLI, Python 3.12, the `additions` user, the data
volume's mount, and two copies of the Actions runner (checksum-verified), unregistered.

No GPU: the models run in float64 on CPU, and the host runs untrusted model code. The
`instance_type` validation rejects GPU and accelerator families.

## Cost

On while an addition is open, stopped between additions. While stopped, only the two
volumes are billed (about 260 GiB of gp3 by default). While running, add the
instance-hours and its public IPv4 address. Check current EC2 pricing for the region;
an `m7i.2xlarge` on demand in us-east-1 is roughly $0.40 an hour.

## First deployment

1. Install the AWS CLI's [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
2. Apply:

   ```bash
   cd stacks/model-additions
   cp terraform.tfvars.example terraform.tfvars
   tofu init
   tofu apply
   ```

3. Wait a few minutes for the first boot, then check it finished:

   ```bash
   $(tofu output -raw ssm_session_command)
   # on the host:
   sudo cat /var/lib/model-additions/bootstrap-done
   sudo tail -n 20 /var/log/model-additions-bootstrap.log
   ```

4. Register the runners, from your laptop, with `gh` logged in as an admin of the
   comparison repository the automation runs in:

   ```bash
   scripts/register-model-additions-runners.sh <owner/repo> "$(tofu output -raw instance_id)" us-east-1
   gh api repos/<owner/repo>/actions/runners --jq '.runners[] | .name + " " + .status'
   ```

   Both runners, `model-additions-control` and `model-additions-stage`, should be
   `online`. The registration token lasts an hour and is passed through SSM Run
   Command, so it appears in that command's history; it is useless once used or
   expired.

The agent image and the egress proxy are built from the comparison repository by its
stage workflow, not here.

## Switching on and off

```bash
tofu apply -var running=false   # stop
tofu apply -var running=true    # start
```

(Or set `running` in `terraform.tfvars`.) Before stopping, check that no stage is
running, from an SSM shell:

```bash
grep -l '"status": "running"' /srv/model-additions/*/ADDITION_STATE.md
```

No output means it is safe. The comparison repository's runbook (section 12) covers
the rest: labels applied while the host is off, and runners GitHub removes after about
two weeks offline (re-run the registration script; `--replace` re-registers them).

## Replacing the host

A new AMI release or an edited boot script never touches a running host
(`ignore_changes = [ami, user_data]`). To rebuild it from current config, with the host
idle:

```bash
tofu apply -replace=aws_instance.host
```

The data volume is detached and reattached, so open additions keep their state. Then
re-run the registration script.

`tofu destroy` deletes the data volume and every open addition's state with it.

## Tests

```bash
cd stacks/model-additions
tofu init -backend=false
tofu test
```

The tests are plan-only against a mocked AWS provider: no credentials, no spend.
