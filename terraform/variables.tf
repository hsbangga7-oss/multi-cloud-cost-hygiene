variable "enable_s3_lifecycle" {
  description = "Set to false for LocalStack (unsupported)"
  type        = bool
  default     = false
}
variable "ssh_allowed_cidr" {
  description = "CIDR block allowed to SSH into EC2 instances. Default is open — restrict in production."
  type        = string
  default     = "0.0.0.0/0"
}