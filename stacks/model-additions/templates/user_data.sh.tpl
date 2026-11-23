#!/usr/bin/env bash
# Rendered by templatefile() from stacks/model-additions/instance.tf. Runs once
# at first boot via cloud-init and does sections 1-2 of the comparison repo's
# docs/automation/RUNBOOK.md up to, not including, registering the runners.
# Every step is idempotent: re-running it by hand after debugging is safe.
set -euo pipefail
exec > >(tee -a /var/log/model-additions-bootstrap.log) 2>&1
echo "bootstrap start: $(date -u +%FT%TZ)"

export DEBIAN_FRONTEND=noninteractive
ADDITIONS_USER=additions
ADDITION_ROOT=/srv/model-additions
RUNNER_VERSION="${runner_version}"
RUNNER_SHA256="${runner_sha256}"
DATA_DEVICE="/dev/disk/by-id/${data_device_id}"

# --- base packages ------------------------------------------------------------
apt-get update -y
apt-get install -y ca-certificates curl gnupg git jq unzip python3.12 python3.12-venv

# --- Docker Engine from Docker's own repository --------------------------------
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
# shellcheck source=/dev/null
. /etc/os-release
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list

# --- GitHub CLI from GitHub's repository ----------------------------------------
if [ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
fi
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gh
systemctl enable --now docker

# The egress isolation was verified on Docker Engine 29.8.2 (RUNBOOK section 1).
DOCKER_VERSION="$(docker version --format '{{.Server.Version}}')"
if [ "$(printf '%s\n' 29.8.2 "$DOCKER_VERSION" | sort -V | head -n1)" != "29.8.2" ]; then
  echo "Docker Engine $DOCKER_VERSION is older than 29.8.2; stopping" >&2
  exit 1
fi

# --- the runners' user ------------------------------------------------------------
if ! id "$ADDITIONS_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$ADDITIONS_USER"
fi
usermod -aG docker "$ADDITIONS_USER"

# --- the data volume at /srv/model-additions ---------------------------------------
# The volume is attached after the instance starts, so wait for it.
for _ in $(seq 1 60); do
  [ -e "$DATA_DEVICE" ] && break
  sleep 5
done
if [ ! -e "$DATA_DEVICE" ]; then
  echo "data volume $DATA_DEVICE did not appear; stopping" >&2
  exit 1
fi
if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
  mkfs.ext4 -L model-additions "$DATA_DEVICE"
fi
install -d "$ADDITION_ROOT"
if ! grep -q " $ADDITION_ROOT " /etc/fstab; then
  echo "$DATA_DEVICE $ADDITION_ROOT ext4 defaults,nofail 0 2" >> /etc/fstab
fi
mountpoint -q "$ADDITION_ROOT" || mount "$ADDITION_ROOT"
chown "$ADDITIONS_USER:$ADDITIONS_USER" "$ADDITION_ROOT"
chmod 0750 "$ADDITION_ROOT"

# --- GitHub Actions runner software, one copy per runner (not registered yet) -------
RUNNER_TARBALL="/tmp/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
if [ ! -f "$RUNNER_TARBALL" ]; then
  curl -fsSL -o "$RUNNER_TARBALL" \
    "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz"
fi
echo "$RUNNER_SHA256  $RUNNER_TARBALL" | sha256sum -c -
for runner in control stage; do
  dir="/opt/actions-runner/$runner"
  if [ ! -x "$dir/config.sh" ]; then
    install -d -o "$ADDITIONS_USER" -g "$ADDITIONS_USER" "$dir"
    tar -xzf "$RUNNER_TARBALL" -C "$dir"
    chown -R "$ADDITIONS_USER:$ADDITIONS_USER" "$dir"
  fi
done
/opt/actions-runner/control/bin/installdependencies.sh

install -d /var/lib/model-additions
date -u +%FT%TZ > /var/lib/model-additions/bootstrap-done
echo "bootstrap done: $(date -u +%FT%TZ)"
