variable "project_id" { type = string }
variable "region" { type = string }
variable "timezone" { type = string }
variable "cloud_run_base_url" { type = string }
variable "service_account_email" { type = string }
variable "enable_scheduler" { type = bool }

locals {
  # count must be known at plan time — do NOT depend on Cloud Run URI (unknown until apply).
  # Root module should set enable_scheduler=false on first apply, then true once URL exists.
  active = var.enable_scheduler
  base   = trimsuffix(var.cloud_run_base_url, "/")
}

resource "google_cloud_scheduler_job" "brand_analysis" {
  count            = local.active ? 1 : 0
  name             = "resumora-mkt-brand-analysis-daily"
  schedule         = "0 6 * * *"
  time_zone        = var.timezone
  project          = var.project_id
  region           = var.region
  attempt_deadline = "320s"
  http_target {
    http_method = "POST"
    uri         = "${local.base}/api/brand-analysis"
    dynamic "oidc_token" {
      for_each = var.service_account_email != "" ? [1] : []
      content { service_account_email = var.service_account_email }
    }
  }
  retry_config { retry_count = 3 }
}

resource "google_cloud_scheduler_job" "competitor_scrape" {
  count            = local.active ? 1 : 0
  name             = "resumora-mkt-competitor-scrape-weekly"
  schedule         = "0 8 * * 1"
  time_zone        = var.timezone
  project          = var.project_id
  region           = var.region
  attempt_deadline = "540s"
  http_target {
    http_method = "POST"
    uri         = "${local.base}/api/competitor-scrape"
    dynamic "oidc_token" {
      for_each = var.service_account_email != "" ? [1] : []
      content { service_account_email = var.service_account_email }
    }
  }
  retry_config { retry_count = 3 }
}

resource "google_cloud_scheduler_job" "model_retrain" {
  count            = local.active ? 1 : 0
  name             = "resumora-mkt-pricing-retrain-monthly"
  schedule         = "0 10 1 * *"
  time_zone        = var.timezone
  project          = var.project_id
  region           = var.region
  attempt_deadline = "1800s"
  http_target {
    http_method = "POST"
    uri         = "${local.base}/api/model-retrain"
    dynamic "oidc_token" {
      for_each = var.service_account_email != "" ? [1] : []
      content { service_account_email = var.service_account_email }
    }
  }
  retry_config { retry_count = 2 }
}
