output "availability_zone" {
  description = "AZ derived from the capacity reservation; every resource in this stack lives here."
  value       = local.availability_zone
}

output "vpc_id" {
  description = "ID of the stack's self-contained VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_id" {
  description = "ID of the public subnet in the reservation's AZ."
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "Security group attached to the GPU instances (and later FSx)."
  value       = aws_security_group.gpu.id
}

output "key_pair_name" {
  description = "Effective key pair name the instances will use."
  value       = local.key_pair_name
}

output "instance_ids" {
  description = "IDs of the launched GPU instances. Empty while launch_instance = false."
  value       = aws_instance.gpu[*].id
}

output "instance_public_ips" {
  description = "Public IPv4 addresses of the launched GPU instances."
  value       = aws_instance.gpu[*].public_ip
}

output "instance_public_dns" {
  description = "Public DNS names of the launched GPU instances."
  value       = aws_instance.gpu[*].public_dns
}

output "connect_commands_eic" {
  description = "Ready-to-paste EC2 Instance Connect commands, one per instance (see docs/admin-access.md)."
  value       = [for i in aws_instance.gpu : "aws ec2-instance-connect ssh --instance-id ${i.id} --os-user ec2-user"]
}

output "connect_commands_ssh" {
  description = "Ready-to-paste plain ssh commands, one per instance (your IP must be in admin_cidr_blocks)."
  value       = [for i in aws_instance.gpu : "ssh ec2-user@${i.public_dns}"]
}

output "fsx_file_system_id" {
  description = "ID of the FSx for Lustre file system. Null while enable_fsx = false."
  value       = one(aws_fsx_lustre_file_system.data[*].id)
}

output "fsx_dns_name" {
  description = "DNS name of the FSx for Lustre file system. Null while enable_fsx = false."
  value       = one(aws_fsx_lustre_file_system.data[*].dns_name)
}

output "fsx_mount_name" {
  description = "AWS-generated Lustre mount name of the file system. Null while enable_fsx = false."
  value       = one(aws_fsx_lustre_file_system.data[*].mount_name)
}

output "fsx_manual_mount_command" {
  description = "Exact command to mount /data on an instance that was already running when FSx was enabled (user_data runs once — see docs/runbooks.md; install the Lustre client first). Null while enable_fsx = false."
  value       = var.enable_fsx ? "sudo mkdir -p /data && sudo mount -t lustre -o relatime,flock ${local.fsx_dns_name}@tcp:/${local.fsx_mount_name} /data" : null
}
