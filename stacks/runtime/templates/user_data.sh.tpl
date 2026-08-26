#!/usr/bin/env bash
# Rendered by templatefile() from stacks/runtime/instance.tf. Runs once at
# first boot via cloud-init. Keep every step idempotent: a manual re-run
# after debugging must be safe.
set -euo pipefail

# --- EC2 Instance Connect (R6, package half) -------------------------------
# It is unverified whether the Deep Learning AMIs bundle ec2-instance-connect,
# so install it as cheap insurance; skip cleanly when it is already present.
if ! rpm -q ec2-instance-connect >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y ec2-instance-connect
  else
    yum install -y ec2-instance-connect
  fi
fi

# --- optional /data storage seam (rendered by stacks/runtime/fsx.tf) --------
${fsx_mount_snippet}
