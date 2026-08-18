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
