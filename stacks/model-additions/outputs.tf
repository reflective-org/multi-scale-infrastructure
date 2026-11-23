output "instance_id" {
  description = "ID of the runner host."
  value       = aws_instance.host.id
}

output "instance_state" {
  description = "The state this apply left the host in (running or stopped)."
  value       = aws_ec2_instance_state.host.state
}

output "availability_zone" {
  description = "AZ of the host and its data volume."
  value       = local.availability_zone
}

output "data_volume_id" {
  description = "ID of the data volume mounted at /srv/model-additions."
  value       = aws_ebs_volume.data.id
}

output "security_group_id" {
  description = "Security group of the host (no inbound rules)."
  value       = aws_security_group.host.id
}

output "ssm_session_command" {
  description = "Ready-to-paste command for a shell on the host (needs the Session Manager plugin for the AWS CLI)."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.host.id}"
}

output "bootstrap_check_command" {
  description = "Run on the host to confirm the first-boot setup finished."
  value       = "sudo cat /var/lib/model-additions/bootstrap-done && sudo tail -n 20 /var/log/model-additions-bootstrap.log"
}

output "register_runners_command" {
  description = "Run from your laptop once the bootstrap is done, with gh logged in as a repository admin (scripts/register-model-additions-runners.sh)."
  value       = "scripts/register-model-additions-runners.sh <owner/repo> ${aws_instance.host.id} ${var.region}"
}
