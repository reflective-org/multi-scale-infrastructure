# Unit tests for the purchase stack. Every run is `command = plan` against a
# mocked AWS provider: no credentials, no API calls, no money. NEVER add an
# apply run here — creating aws_ec2_capacity_block_reservation spends real,
# non-refundable money.
#
# There is deliberately no destroy-attempt test: the test framework cannot
# express destroy, and prevent_destroy would wedge apply-mode cleanup.
# prevent_destroy is verified by a manual runbook check instead.

mock_provider "aws" {}

variables {
  region                  = "us-east-1"
  instance_type           = "p5.48xlarge"
  instance_count          = 1
  capacity_duration_hours = 24
}

# Scenario 1 — search-only: with no confirmation variables, the search runs
# free and nothing purchasable is planned (R1).
run "search_only_plans_zero_reservations" {
  command = plan

  assert {
    condition     = length(data.aws_ec2_capacity_block_offering.search) == 1
    error_message = "Search should be active by default (search_enabled = true)."
  }

  assert {
    condition     = length(aws_ec2_capacity_block_reservation.this) == 0
    error_message = "No reservation may be planned without both confirmation variables set."
  }
}

# Scenario 2 — confirmation pairing: offering ID without the expected fee is
# rejected by cross-variable validation (R2).
run "confirmation_vars_must_be_set_together" {
  command = plan

  variables {
    capacity_block_offering_id = "cbo-0123456789abcdef0"
  }

  expect_failures = [
    var.capacity_block_offering_id,
  ]
}

# Scenario 3 — drift guard (the red-proof for the money gate): the fresh
# lookup returns a different fee than the operator reviewed, so the purchase
# precondition must fail (R2/R10).
run "fee_drift_blocks_purchase" {
  command = plan

  variables {
    capacity_block_offering_id = "cbo-0123456789abcdef0"
    expected_upfront_fee       = "28800.00"
  }

  override_data {
    target = data.aws_ec2_capacity_block_offering.search
    values = {
      capacity_block_offering_id = "cbo-fresh0000000000000"
      upfront_fee                = "31200.00"
      availability_zone          = "us-east-1a"
      currency_code              = "USD"
    }
  }

  expect_failures = [
    aws_ec2_capacity_block_reservation.this,
    check.search_enabled_after_purchase,
  ]
}

# Scenario 4 — fee match: confirmation pinned to the reviewed fee (and AZ),
# fresh lookup agrees → exactly one reservation is planned. The offering ID in
# the fresh lookup deliberately differs from the confirmed one: IDs are
# ephemeral quotes and must NOT be part of the gate. The check block still
# warns (reservation configured while search_enabled = true), which the test
# framework surfaces as an expected failure.
run "fee_match_purchases_one_reservation" {
  command = plan

  variables {
    capacity_block_offering_id = "cbo-0123456789abcdef0"
    expected_upfront_fee       = "28800.00"
    expected_availability_zone = "us-east-1a"
  }

  override_data {
    target = data.aws_ec2_capacity_block_offering.search
    values = {
      capacity_block_offering_id = "cbo-fresh0000000000000"
      upfront_fee                = "28800.00"
      availability_zone          = "us-east-1a"
      currency_code              = "USD"
    }
  }

  expect_failures = [
    check.search_enabled_after_purchase,
  ]

  assert {
    condition     = length(aws_ec2_capacity_block_reservation.this) == 1
    error_message = "Exactly one reservation must be planned when both confirmations match the fresh lookup."
  }
}

# Scenario 5 — instance type allowlist: anything but the two supported types
# is rejected (KTD2).
run "invalid_instance_type_rejected" {
  command = plan

  variables {
    instance_type = "p5n.48xlarge"
  }

  expect_failures = [
    var.instance_type,
  ]
}

# Scenario 6 — post-purchase state: search off, no confirmations. The plan
# must succeed with zero data source instances and null-safe outputs, so an
# existing reservation is never disturbed by a disabled search.
run "search_disabled_short_circuits" {
  command = plan

  variables {
    search_enabled = false
  }

  assert {
    condition     = length(data.aws_ec2_capacity_block_offering.search) == 0
    error_message = "search_enabled = false must gate off the offering lookup."
  }

  assert {
    condition     = length(aws_ec2_capacity_block_reservation.this) == 0
    error_message = "No reservation may be planned without confirmation variables."
  }

  assert {
    condition     = output.offering_id == null && output.offering_upfront_fee == null
    error_message = "Offering outputs must resolve to null, not error, when search is disabled."
  }

  assert {
    condition     = output.reservation_id == null && output.reservation_end_date == null
    error_message = "Reservation outputs must resolve to null, not error, when nothing is purchased."
  }
}
