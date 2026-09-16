# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region to run the fleet in. Check g6e availability first — see docs/runbooks.md."
  type        = string
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the stack's self-contained VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_azs" {
  description = "Availability zone SUFFIXES (e.g. [\"a\", \"b\"]) appended to var.region; one public subnet is created per entry and instances spread across them round-robin (R2, KTD9). Steer this list when an AZ lacks g6e capacity — see docs/runbooks.md."
  type        = list(string)
  default     = ["a", "b"]

  validation {
    condition     = length(var.subnet_azs) > 0
    error_message = "subnet_azs must list at least one AZ suffix (e.g. [\"a\", \"b\"]) — the fleet needs a subnet to launch into."
  }
}

# ---------------------------------------------------------------------------
# Admin access
# ---------------------------------------------------------------------------

variable "admin_cidr_blocks" {
  description = "Admin source CIDRs allowed to SSH. Required for CLI-initiated `aws ec2-instance-connect ssh` (it connects from your own IP) and for plain ssh; browser-console EC2 Instance Connect needs no entry here. IPv4 only. See docs/admin-access.md."
  type        = list(string)
  default     = []

  # IPv4 shape check on top of CIDR validity: the SSH rules are cidr_ipv4,
  # so an IPv6 entry that slipped past cidrhost() would only fail later,
  # inside the provider.
  validation {
    condition = alltrue([
      for c in var.admin_cidr_blocks :
      can(cidrhost(c, 0)) && can(regex("^(\\d{1,3}\\.){3}\\d{1,3}/\\d{1,2}$", c))
    ])
    error_message = "Every admin_cidr_blocks entry must be a valid IPv4 CIDR, e.g. \"203.0.113.7/32\"."
  }

  validation {
    condition     = !contains(var.admin_cidr_blocks, "0.0.0.0/0") && !contains(var.admin_cidr_blocks, "::/0")
    error_message = "admin_cidr_blocks must not open SSH to the world (0.0.0.0/0 or ::/0). Use your own IP as a /32 — see docs/admin-access.md."
  }
}

variable "existing_key_pair_name" {
  description = "Name of an EC2 key pair that already exists in this region. Set exactly one of existing_key_pair_name or public_key."
  type        = string
  default     = null
}

variable "public_key" {
  description = "SSH public key material (contents of the .pub file, e.g. from scripts/generate-key.sh) to register as a new key pair. Set exactly one of existing_key_pair_name or public_key."
  type        = string
  default     = null

  validation {
    condition     = (var.public_key == null) != (var.existing_key_pair_name == null)
    error_message = "Set exactly one of public_key or existing_key_pair_name: pass a public key (scripts/generate-key.sh prints one) to register a new key pair, or name an existing key pair to reuse it."
  }
}

variable "key_pair_name" {
  description = "Name PREFIX for the key pair registered from public_key (a random suffix is appended so region-unique key names never collide — KTD10). Ignored when existing_key_pair_name is set."
  type        = string
  default     = "multi-scale-fleet"
}
