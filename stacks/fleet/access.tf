# Key pair handling (R10, house pattern): only public material ever reaches
# AWS or OpenTofu state. tls_private_key is prohibited here — it would store
# the private key unencrypted in state. Generate a key locally with
# scripts/generate-key.sh and pass the .pub contents as public_key, or reuse
# an already-registered key pair via existing_key_pair_name.

resource "aws_key_pair" "this" {
  count = var.existing_key_pair_name == null ? 1 : 0

  # KTD10: key_name_prefix (not key_name) so the fleet's key pair — default
  # prefix multi-scale-fleet — can never collide on the region-unique key
  # pair name, neither with the runtime stack's multi-scale-gpu key nor with
  # a second fleet deployment in the same region.
  key_name_prefix = "${var.key_pair_name}-"
  public_key      = var.public_key

  tags = local.tags
}

locals {
  # Effective key pair name, consumed by the instance unit (house pattern —
  # same derivation as the runtime stack's access.tf).
  key_pair_name = coalesce(var.existing_key_pair_name, one(aws_key_pair.this[*].key_name))
}
