output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "public_subnet_1_id" {
  description = "Public Subnet 1 ID"
  value       = module.network.public_subnet_1_id
}

output "public_subnet_2_id" {
  description = "Public Subnet 2 ID"
  value       = module.network.public_subnet_2_id
}

output "igw_id" {
  description = "Internet Gateway ID"
  value       = module.network.igw_id
}

output "running_instance_id" {
  description = "Running EC2 Instance ID"
  value       = aws_instance.running_instance.id
}

output "stopped_instance_id" {
  description = "Stopped EC2 Instance ID"
  value       = aws_instance.stopped_instance.id
}

output "logs_bucket_name" {
  description = "S3 Logs Bucket Name"
  value       = aws_s3_bucket.logs_bucket.id
}