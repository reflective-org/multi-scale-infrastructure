provider "aws" {
  region = var.region
}

locals {
  # Purchase happens only when the operator explicitly pins BOTH the reviewed
  # offering and its exact fee (R2/R10). Variable validation enforces the pair.
  purchase_confirmed = var.capacity_block_offering_id != null && var.expected_upfront_fee != null

  # Fresh-lookup values consumed by the money gate below (null when search is
  # disabled or returns nothing).
  fresh_upfront_fee       = one(data.aws_ec2_capacity_block_offering.search[*].upfront_fee)
  fresh_availability_zone = one(data.aws_ec2_capacity_block_offering.search[*].availability_zone)
}

# Free search (R1). Count-gated so the operator can turn it off after purchase:
# offerings are ephemeral quotes, and a drifted or empty search must never
# disturb an existing reservation.
data "aws_ec2_capacity_block_offering" "search" {
  count = var.search_enabled ? 1 : 0

  instance_type           = var.instance_type
  instance_count          = var.instance_count
  capacity_duration_hours = var.capacity_duration_hours
  start_date_range        = var.start_date_range
  end_date_range          = var.end_date_range
}

# Purchasing a capacity block is an immediate, upfront, NON-REFUNDABLE charge.
# Deleting this resource only forgets it from state; it does not refund.
resource "aws_ec2_capacity_block_reservation" "this" {
  count = local.purchase_confirmed ? 1 : 0

  capacity_block_offering_id = var.capacity_block_offering_id
  instance_platform          = "Linux/UNIX"
  tags                       = var.tags

  lifecycle {
    prevent_destroy = true

    # Offering IDs are ephemeral quotes; a later search would otherwise plan a
    # replacement of a live, non-refundable reservation.
    ignore_changes = [capacity_block_offering_id]

    precondition {
      # Money gate (R2/R10): verify the operator-confirmed fee (and AZ, when
      # pinned) against a FRESH offering lookup. Offering-ID equality is
      # deliberately NOT checked — IDs change between lookups, so ID-equality
      # could never pass; AWS itself rejects a stale offering ID at purchase,
      # which is the backstop. When search_enabled = false (post-purchase)
      # this short-circuits to pass: an existing reservation must never be
      # blocked by a disabled or drifted search.
      condition = (
        !var.search_enabled
        || (
          local.fresh_upfront_fee == var.expected_upfront_fee
          && (
            var.expected_availability_zone == null
            || local.fresh_availability_zone == var.expected_availability_zone
          )
        )
      )
      error_message = format(
        "Purchase blocked: the fresh offering lookup no longer matches the reviewed values. expected_upfront_fee=%q vs fresh upfront_fee=%q; expected_availability_zone=%q vs fresh availability_zone=%q. Re-run the search, review the new offering (fee, AZ, dates), and update capacity_block_offering_id + expected_upfront_fee before applying again.",
        coalesce(var.expected_upfront_fee, "null"),
        coalesce(local.fresh_upfront_fee, "unknown"),
        coalesce(var.expected_availability_zone, "any"),
        coalesce(local.fresh_availability_zone, "unknown"),
      )
    }
  }
}

check "search_enabled_after_purchase" {
  assert {
    condition     = !(local.purchase_confirmed && var.search_enabled)
    error_message = "A capacity block reservation is configured while search_enabled is still true. After the purchase completes, set search_enabled = false so future plans cannot be disturbed by drifted or empty offering lookups."
  }
}
