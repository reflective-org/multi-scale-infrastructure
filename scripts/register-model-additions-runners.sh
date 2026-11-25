#!/usr/bin/env bash
# Register the model-addition host's two GitHub Actions runners and start them
# as services. Run from your laptop after the host's first-boot setup is done
# (the stack's bootstrap_check_command), with:
#   - gh logged in as an admin of the target repository;
#   - AWS credentials allowed to use SSM Run Command on the instance.
#
# Usage: scripts/register-model-additions-runners.sh <owner/repo> <instance-id> [region]
#
# The registration token is short-lived (one hour) and single-purpose. It is
# passed to the instance through SSM Run Command, so it appears in that
# command's history in the account; it is useless once the runners are
# registered or the hour is up.
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <owner/repo> <instance-id> [region]" >&2
  exit 2
fi
repo="$1"
instance_id="$2"
region="${3:-us-east-1}"

if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "repository must look like owner/name, got: $repo" >&2
  exit 2
fi
if ! [[ "$instance_id" =~ ^i-[0-9a-f]+$ ]]; then
  echo "instance id must look like i-0123..., got: $instance_id" >&2
  exit 2
fi

token="$(gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token)"

# Each runner: configure as the additions user, then install and start it as a
# systemd service running as that user. --replace re-registers a runner of the
# same name (after a host replacement, or one GitHub removed while stopped).
script=$(cat <<SCRIPT
set -euo pipefail
test -f /var/lib/model-additions/bootstrap-done
for pair in control:aerosol-dev-control stage:aerosol-dev-stage; do
  name="\${pair%%:*}"; label="\${pair#*:}"
  cd "/opt/actions-runner/\$name"
  if [ -f .runner ]; then
    ./svc.sh stop || true
    ./svc.sh uninstall || true
  fi
  sudo -u additions ./config.sh --unattended --replace \
    --url "https://github.com/$repo" --token "$token" \
    --name "model-additions-\$name" --labels "\$label" --work _work
  ./svc.sh install additions
  ./svc.sh start
done
SCRIPT
)

# AWS-RunShellScript runs commands with /bin/sh (dash on Ubuntu), which has no
# `pipefail`, so hand the script to bash.
encoded="$(printf '%s\n' "$script" | base64 | tr -d '\n')"
params="$(jq -n --arg s "echo $encoded | base64 -d | bash" '{commands: [$s]}')"
command_id="$(aws ssm send-command --region "$region" \
  --instance-ids "$instance_id" \
  --document-name AWS-RunShellScript \
  --comment "Register model-addition runners for $repo" \
  --parameters "$params" \
  --query Command.CommandId --output text)"

echo "SSM command $command_id sent; waiting for it to finish..."
aws ssm wait command-executed --region "$region" --command-id "$command_id" --instance-id "$instance_id" || true
aws ssm get-command-invocation --region "$region" --command-id "$command_id" --instance-id "$instance_id" \
  --query '{status: Status, stdout: StandardOutputContent, stderr: StandardErrorContent}' --output json

echo "Check: gh api repos/$repo/actions/runners --jq '.runners[] | .name + \" \" + .status'"
