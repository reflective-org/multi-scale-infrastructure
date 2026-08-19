# All outputs are null-safe via one(): both the data source and the resource
# are count-gated, so each may have zero instances.

# --- Offering (review surface before purchase) ---

output "offering_id" {
  description = "Offering ID from the search. Ephemeral quote — copy into capacity_block_offering_id to confirm purchase."
  value       = one(data.aws_ec2_capacity_block_offering.search[*].capacity_block_offering_id)
}

output "offering_upfront_fee" {
  description = "Total upfront fee of the offering. Copy into expected_upfront_fee to confirm purchase."
  value       = one(data.aws_ec2_capacity_block_offering.search[*].upfront_fee)
}

output "offering_currency_code" {
  description = "Currency of the upfront fee."
  value       = one(data.aws_ec2_capacity_block_offering.search[*].currency_code)
}

output "offering_availability_zone" {
  description = "Availability zone of the offering. Optionally copy into expected_availability_zone."
  value       = one(data.aws_ec2_capacity_block_offering.search[*].availability_zone)
}

output "requested_start_date_range" {
  description = "Echo of the operator's start_date_range search input (null when unset) — NOT the offering's actual start date. Get real dates from `aws ec2 describe-capacity-block-offerings` before confirming."
  value       = one(data.aws_ec2_capacity_block_offering.search[*].start_date_range)
}

output "requested_end_date_range" {
  description = "Echo of the operator's end_date_range search input (null when unset) — NOT the offering's actual end date. Get real dates from `aws ec2 describe-capacity-block-offerings` before confirming."
  value       = one(data.aws_ec2_capacity_block_offering.search[*].end_date_range)
}

# --- Reservation (handoff to the runtime stack) ---

output "reservation_id" {
  description = "Capacity block reservation ID — feed this to the runtime stack's capacity_reservation_id."
  value       = one(aws_ec2_capacity_block_reservation.this[*].id)
}

output "reservation_arn" {
  description = "ARN of the capacity block reservation."
  value       = one(aws_ec2_capacity_block_reservation.this[*].arn)
}

output "reservation_availability_zone" {
  description = "Availability zone of the reservation — the runtime stack's network must be placed here."
  value       = one(aws_ec2_capacity_block_reservation.this[*].availability_zone)
}

output "reservation_start_date" {
  description = "When the reserved capacity becomes usable."
  value       = one(aws_ec2_capacity_block_reservation.this[*].start_date)
}

output "reservation_end_date" {
  description = "When the reservation ends. Instances terminate before this — checkpoint work well ahead of it."
  value       = one(aws_ec2_capacity_block_reservation.this[*].end_date)
}
