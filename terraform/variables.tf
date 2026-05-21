# variables.tf
variable "enable_s3_lifecycle" {
  description = "Set to false for LocalStack (unsupported)"
  type        = bool
  default     = false
}