terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  # bucket: resumora-terraform-state-<project_id>
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  labels = {
    app         = "resumora-marketing-intel"
    product     = "resumora"
    domain      = "resumora-net"
    environment = var.environment
  }
}

resource "google_billing_budget" "marketing_budget" {
  count = var.enable_budget_alert && var.billing_account_id != "" ? 1 : 0

  billing_account = var.billing_account_id
  display_name    = "Resumora Marketing Intelligence Budget"

  budget_filter {
    projects = ["projects/${var.project_id}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(floor(var.budget_amount_usd))
    }
  }

  threshold_rules { threshold_percent = 0.9 }
  threshold_rules { threshold_percent = 1.0 }
}

module "storage" {
  source                         = "./modules/storage"
  project_id                     = var.project_id
  region                         = var.region
  environment                    = var.environment
  bucket_name                    = coalesce(var.storage_bucket_name, "${var.project_id}-mkt-intel-data")
  labels                         = local.labels
  runtime_service_account_email  = var.runtime_service_account_email
}

module "bigquery" {
  source                        = "./modules/bigquery"
  project_id                    = var.project_id
  region                        = var.region
  dataset_name                  = var.bigquery_dataset_name
  table_expiration_days         = var.bigquery_table_expiration_days
  labels                        = local.labels
  runtime_service_account_email = var.runtime_service_account_email
}

module "vertex_ai" {
  source      = "./modules/vertex-ai"
  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  labels      = local.labels
}

module "cloud_run" {
  source                = "./modules/cloud-run"
  project_id            = var.project_id
  region                = var.region
  environment           = var.environment
  service_name          = var.cloud_run_service_name
  image                 = var.cloud_run_image
  dataset_name          = var.bigquery_dataset_name
  service_account_email = module.storage.service_account_email
  enable_public_access  = var.enable_public_dashboard
  labels                = local.labels
}

module "scheduler" {
  source                = "./modules/scheduler"
  project_id            = var.project_id
  region                = var.region
  timezone              = var.scheduler_timezone
  cloud_run_base_url    = module.cloud_run.service_uri
  service_account_email = module.storage.service_account_email
  enable_scheduler      = var.enable_scheduler
}
