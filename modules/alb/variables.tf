variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet id for alb"
  type        = list(string)
}

variable "environment" {
  description = "env name"
  type        = string
}
