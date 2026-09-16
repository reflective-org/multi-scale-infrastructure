#!/usr/bin/env bash
# Rendered by templatefile() from stacks/fleet/instance.tf, once per node
# with that node's index baked in. Runs once at first boot via cloud-init.
# Keep every step idempotent: a manual re-run after debugging must be safe —
# the docker rm -f guard and the stale-marker cleanup below are part of that
# contract (KTD3).
set -euo pipefail

# --- loud-failure contract (R7, KTD8) ----------------------------------------
# Mirrors stacks/runtime/fsx.tf's mount fragment: any boot/pull/run failure
# leaves all three of
#   1. a nonzero cloud-init exit (set -e plus the explicit exit 1 here),
#   2. a FATAL line in the console log (/var/log/cloud-init-output.log),
#   3. a login-visible marker every SSH session prints — a silent node that
#      never joined the shard math must not look healthy from a shell.
# The success path at the bottom removes a stale marker so a node fixed by a
# manual re-run stops warning. user_data runs as root: /etc/profile.d is
# writable directly, no sudo.
marker=/etc/profile.d/00-fleet-broken.sh

fail() {
  echo 'echo "WARNING: the fleet container is NOT running on this node - shard ${node_index}/${node_count} is doing no work; see cloud-init logs (/var/log/cloud-init-output.log)"' >"$marker"
  chmod 0644 "$marker"
  echo "FATAL: $1" >&2
  exit 1
}

# --- EC2 Instance Connect (insurance install) --------------------------------
# It is unverified whether the Deep Learning AMIs bundle ec2-instance-connect,
# so install it as cheap insurance; skip cleanly when it is already present.
if ! rpm -q ec2-instance-connect >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y ec2-instance-connect
  else
    yum install -y ec2-instance-connect
  fi
fi

# --- Docker daemon guard ------------------------------------------------------
# The DLAMI ships docker installed and enabled, but user_data racing the
# daemon's first start is a classic flake. Cheap check, loud failure.
systemctl is-active --quiet docker \
  || systemctl start docker \
  || fail "docker daemon is not active and could not be started"

%{ if is_ecr ~}
# --- ECR login (R6, KTD7) -----------------------------------------------------
# Rendered ONLY because the image URI is private ECR. The region is the one
# PARSED FROM THE URI, never the fleet's own var.region — cross-region pulls
# must authenticate against the registry's region. AWS CLI v2 is preinstalled
# on the DLAMI; credentials come from the instance role via IMDS.
aws ecr get-login-password --region ${ecr_region} \
  | docker login --username AWS --password-stdin ${ecr_registry_host} \
  || fail "ECR login to ${ecr_registry_host} (region ${ecr_region}) failed"

%{ endif ~}
# --- shard identity + operator env (R4, KTD3) ---------------------------------
# Env vars pass via an ENV FILE, not interpolated -e flags: docker's env-file
# format has no quoting semantics, so spaces and quotes in operator values
# pass through literally, and the rendered script stays shell-safe and
# byte-identical across nodes except for the two shard lines. The quoted
# heredoc delimiter keeps bash from expanding anything in the values.
# NEVER put secrets in this file's inputs (R12) — see var.container_env.
mkdir -p /etc/fleet
cat >/etc/fleet/container.env <<'ENV_EOF'
NODE_INDEX=${node_index}
NODE_COUNT=${node_count}
%{ for k, v in container_env ~}
${k}=${v}
%{ endfor ~}
ENV_EOF
chmod 0600 /etc/fleet/container.env

# --- pull + run exactly one container (R4, R5, R8) ----------------------------
docker pull ${docker_image} \
  || fail "image pull failed: ${docker_image}"

# Manual re-run guard (KTD3): a leftover container under the fixed name would
# otherwise make docker run fail with a name conflict.
docker rm -f ${container_name} >/dev/null 2>&1 || true

# --gpus all is EXPLICIT — never rely on the DLAMI's default docker runtime
# to expose the GPUs (KTD3).
docker run -d \
  --name ${container_name} \
  --gpus all \
  --env-file /etc/fleet/container.env \
  --restart ${restart_spec} \
%{ if enable_container_logs ~}
  --log-driver awslogs \
  --log-opt awslogs-group=${log_group_name} \
  --log-opt awslogs-region=${region} \
  --log-opt awslogs-stream=${log_stream} \
%{ endif ~}
  ${run_tail} \
  || fail "container start failed: ${docker_image}"

# Boot reached the success path — clear any stale marker left by a previously
# failed attempt on this node.
rm -f "$marker"
