# Key pair handling (R5, KTD6): only public material ever reaches AWS or
# OpenTofu state. tls_private_key is prohibited here — it would store the
# private key unencrypted in state (R8). Generate a key locally with
# scripts/generate-key.sh and pass the .pub contents as public_key, or reuse
# an already-registered key pair via existing_key_pair_name.

resource "aws_key_pair" "this" {
  count = var.existing_key_pair_name == null ? 1 : 0

  key_name   = var.key_pair_name
  public_key = var.public_key

  tags = local.tags
}

locals {
  # Effective key pair name, consumed by the instance unit and outputs.
  key_pair_name = coalesce(var.existing_key_pair_name, one(aws_key_pair.this[*].key_name))
}
