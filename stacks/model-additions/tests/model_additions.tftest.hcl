# Model-additions stack tests — plan-only against a fully mocked AWS provider.
# No run here ever touches a real AWS account.

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b"]
    }
  }

  override_data {
    target = data.aws_ssm_parameter.ubuntu
    values = {
      value = "ami-0123456789abcdef0"
    }
  }

  override_data {
    target = data.aws_iam_policy_document.assume_ec2
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  override_resource {
    target = aws_ebs_volume.data
    values = {
      id = "vol-0123456789abcdef0"
    }
  }

  override_resource {
    target = aws_instance.host
    values = {
      id = "i-0123456789abcdef0"
    }
  }
}

run "defaults_build_a_cpu_host_that_is_on" {
  command = plan

  assert {
    condition     = aws_instance.host.instance_type == "m7i.2xlarge"
    error_message = "The default instance type should be m7i.2xlarge."
  }

  assert {
    condition     = aws_ec2_instance_state.host.state == "running"
    error_message = "running defaults to true, so the host should be started."
  }

  assert {
    condition     = aws_instance.host.ami == "ami-0123456789abcdef0"
    error_message = "With no ami_id, the AMI should come from Canonical's SSM parameter."
  }

  assert {
    condition     = aws_subnet.public.availability_zone == "us-east-1a" && aws_ebs_volume.data.availability_zone == "us-east-1a"
    error_message = "The subnet and the data volume should share the first available AZ."
  }
}

run "host_is_hardened" {
  command = plan

  assert {
    condition     = aws_instance.host.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }

  assert {
    condition     = aws_instance.host.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "The metadata hop limit must be 1 so containers cannot reach the instance role."
  }

  assert {
    condition     = aws_instance.host.root_block_device[0].encrypted && aws_ebs_volume.data.encrypted
    error_message = "Both volumes must be encrypted."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ssm_core.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "The instance role should carry only the SSM core policy."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.https.from_port == 443 && aws_vpc_security_group_egress_rule.http.from_port == 80
    error_message = "The host should have HTTPS and HTTP egress only."
  }
}

run "boot_script_gets_the_runner_and_the_data_volume" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.host.user_data, "RUNNER_VERSION=\"2.338.2\"")
    error_message = "The boot script should install the pinned runner version."
  }

  assert {
    condition     = strcontains(aws_instance.host.user_data, "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40")
    error_message = "The boot script should verify the runner tarball's SHA-256."
  }

  assert {
    condition     = strcontains(aws_instance.host.user_data, "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0123456789abcdef0")
    error_message = "The boot script should find the data volume by its NVMe serial."
  }
}

run "running_false_stops_the_host" {
  command = plan

  variables {
    running = false
  }

  assert {
    condition     = aws_ec2_instance_state.host.state == "stopped"
    error_message = "running = false should stop the host."
  }
}

run "explicit_ami_bypasses_ssm" {
  command = plan

  variables {
    ami_id = "ami-0fedcba9876543210"
  }

  assert {
    condition     = aws_instance.host.ami == "ami-0fedcba9876543210" && length(data.aws_ssm_parameter.ubuntu) == 0
    error_message = "An explicit ami_id should be used as is, with no SSM lookup."
  }
}

run "availability_zone_can_be_pinned" {
  command = plan

  variables {
    availability_zone = "us-east-1b"
  }

  assert {
    condition     = aws_subnet.public.availability_zone == "us-east-1b" && aws_ebs_volume.data.availability_zone == "us-east-1b"
    error_message = "A pinned availability_zone should apply to the subnet and the data volume."
  }
}

run "gpu_instance_types_are_rejected" {
  command = plan

  variables {
    instance_type = "p5.48xlarge"
  }

  expect_failures = [var.instance_type]
}

run "bad_runner_checksum_is_rejected" {
  command = plan

  variables {
    runner_sha256 = "not-a-checksum"
  }

  expect_failures = [var.runner_sha256]
}

run "small_data_volume_is_rejected" {
  command = plan

  variables {
    data_volume_size_gib = 10
  }

  expect_failures = [var.data_volume_size_gib]
}
