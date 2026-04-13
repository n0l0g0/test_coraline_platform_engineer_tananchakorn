variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project_name" {
  type    = string
  default = "coraline-metabase"
}

variable "environment" {
  type    = string
  default = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["ap-southeast-1a", "ap-southeast-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "private_db_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "metabase_image" {
  type    = string
  default = "metabase/metabase:v0.50.0"
}

variable "metabase_cpu" {
  type    = number
  default = 1024
}

variable "metabase_memory" {
  type    = number
  default = 2048
}

variable "metabase_desired_count" {
  type    = number
  default = 1
}

variable "metabase_port" {
  type    = number
  default = 3000
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.small"
}

variable "db_name" {
  type    = string
  default = "metabase"
}

variable "db_username" {
  type      = string
  default   = "metabase_admin"
  sensitive = true
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_max_allocated_storage" {
  type    = number
  default = 100
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "certificate_arn" {
  type    = string
  default = ""
}

variable "allowed_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}
