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

# Resolve the repo root so we can refuse to ever touch key material inside
# the working tree, regardless of what path the caller passes in.
resolve_repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  git -C "${script_dir}/.." rev-parse --show-toplevel 2>/dev/null || (cd "${script_dir}/.." && pwd)
}

# Best-effort absolute-path resolution that works even when the target (or
# its parent directory) doesn't exist yet, so it's safe to call before the
# key is generated.
resolve_abs_path() {
  local target="$1" target_dir target_base
  if [ -d "${target}" ]; then
    (cd "${target}" && pwd)
    return
  fi
  target_dir="$(dirname "${target}")"
  target_base="$(basename "${target}")"
  if [ -d "${target_dir}" ]; then
    printf '%s/%s\n' "$(cd "${target_dir}" && pwd)" "${target_base}"
  else
    case "${target}" in
      /*) printf '%s\n' "${target}" ;;
      *) printf '%s/%s\n' "$(pwd)" "${target}" ;;
    esac
  fi
}

repo_root="$(resolve_repo_root)"
abs_key_path="$(resolve_abs_path "${key_path}")"

case "${abs_key_path}" in
  "${repo_root}"/*|"${repo_root}")
    echo "error: refusing to generate a key inside the repository (${abs_key_path})." >&2
    echo "Generate it outside the repo instead, e.g. the default ~/.ssh/multi-scale-gpu path." >&2
    exit 1
    ;;
esac

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
echo "Private key: ${key_path} (must stay outside the repo — this script now refuses to generate one inside it)"
echo "Public key:  ${pub_path}"
echo
echo "Add this line to stacks/runtime/terraform.tfvars:"
echo
printf 'public_key = "%s"\n' "$(cat "${pub_path}")"
