#!/usr/bin/env bash
# Generate a local ed25519 SSH key for the runtime stack and print the
# tfvars line to set. Only the public key is ever registered with AWS; the
# private key never leaves this machine and must never enter the repo.
#
# Usage: scripts/generate-key.sh [key-path]
#   key-path defaults to ~/.ssh/multi-scale-gpu (outside the repo on purpose).
#
# Idempotent: an existing key is never overwritten — the script just prints
# its info again and exits 0.
set -euo pipefail

key_path="${1:-${HOME}/.ssh/multi-scale-gpu}"
pub_path="${key_path}.pub"

if [ -e "${key_path}" ] || [ -e "${pub_path}" ]; then
  echo "Key already exists at ${key_path} — leaving it untouched." >&2
else
  mkdir -p "$(dirname "${key_path}")"
  # No passphrase so scripted use stays non-interactive; add one later with
  # `ssh-keygen -p -f <key-path>` if you prefer.
  ssh-keygen -t ed25519 -f "${key_path}" -N "" -C "multi-scale-gpu"
fi

if [ ! -f "${pub_path}" ]; then
  echo "error: ${key_path} exists but ${pub_path} is missing." >&2
  echo "Recover the public key with: ssh-keygen -y -f '${key_path}' > '${pub_path}'" >&2
  exit 1
fi

echo
echo "Private key: ${key_path} (keep it out of the repo — .gitignore blocks key material, but don't tempt it)"
echo "Public key:  ${pub_path}"
echo
echo "Add this line to stacks/runtime/terraform.tfvars:"
echo
printf 'public_key = "%s"\n' "$(cat "${pub_path}")"
