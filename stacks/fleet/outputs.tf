output "instance_ids" {
  description = "IDs of the fleet instances, keyed by node index. Empty while instance_count = 0 (paused)."
  value       = { for i, inst in aws_instance.fleet : i => inst.id }
}

output "instance_public_ips" {
  description = "Public IPv4 addresses of the fleet instances, keyed by node index."
  value       = { for i, inst in aws_instance.fleet : i => inst.public_ip }
}

output "instance_public_dns" {
  description = "Public DNS names of the fleet instances, keyed by node index."
  value       = { for i, inst in aws_instance.fleet : i => inst.public_dns }
}

output "connect_commands_eic" {
  description = "Ready-to-paste EC2 Instance Connect commands, keyed by node index (see docs/admin-access.md)."
  value       = { for i, inst in aws_instance.fleet : i => "aws ec2-instance-connect ssh --instance-id ${inst.id} --os-user ec2-user" }
}

output "connect_commands_ssh" {
  description = "Ready-to-paste plain ssh commands, keyed by node index (your IP must be in admin_cidr_blocks)."
  value       = { for i, inst in aws_instance.fleet : i => "ssh ec2-user@${inst.public_dns}" }
}

output "container_log_group" {
  description = "CloudWatch log group the containers write to (one stream per node index). Null while enable_container_logs = false."
  value       = var.enable_container_logs ? local.log_group_name : null
}

output "resolved_ami_id" {
  description = "The AMI the fleet is (or would be) launched from. Copy into ami_id to pin it for the duration of a batch — the SSM `latest` pointer moving is otherwise a full-fleet replacement trigger (docs/runbooks.md, 10.1)."
  value       = local.ami_id
}
