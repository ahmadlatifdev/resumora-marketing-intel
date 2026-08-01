variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "billing_account_id" {
  type    = string
  default = ""
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "budget_amount_usd" {
  type    = number
  default = 50
}

variable "enable_budget_alert" {
  type    = bool
  default = false
}

variable "bigquery_dataset_name" {
  type    = string
  default = "marketing_intelligence"
}

variable "bigquery_table_expiration_days" {
  type    = number
  default = 90
}

variable "storage_bucket_name" {
  type    = string
  default = ""
}

variable "cloud_run_service_name" {
  type    = string
  default = "marketing-dashboard"
}

variable "cloud_run_image" {
  type        = string
  description = "Empty skips Cloud Run + Scheduler"
  default     = ""
}

variable "enable_public_dashboard" {
  type    = bool
  default = false
}

variable "enable_scheduler" {
  type    = bool
  default = true
}

variable "scheduler_timezone" {
  type    = string
  default = "America/Toronto"
}

variable "runtime_service_account_email" {
  type        = string
  description = "Existing SA email for Cloud Run (e.g. github-deployer@PROJECT.iam.gserviceaccount.com)"
  default     = ""
}
