variable "project_id" { type = string }
variable "region" { type = string }
variable "environment" { type = string }
variable "service_name" { type = string }
variable "image" { type = string }
variable "dataset_name" { type = string }
variable "service_account_email" { type = string }
variable "enable_public_access" { type = bool }
variable "labels" { type = map(string) }

locals { create = var.image != "" }

resource "google_cloud_run_v2_service" "dashboard" {
  count    = local.create ? 1 : 0
  name     = var.service_name
  location = var.region
  project  = var.project_id
  ingress  = "INGRESS_TRAFFIC_ALL"
  labels   = merge(var.labels, { service = "dashboard" })

  template {
    # Omit service_account when blank → default Compute SA (avoids needing actAs on custom SA)
    service_account = var.service_account_email != "" ? var.service_account_email : null
    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }
    containers {
      image = var.image
      ports { container_port = 8080 }
      resources {
        limits = { cpu = "1", memory = "2Gi" }
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GCP_PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "BIGQUERY_DATASET"
        value = var.dataset_name
      }
      env {
        name  = "AD_PLATFORM_WRITE_ENABLED"
        value = "false"
      }
      env {
        name  = "AUTO_APPLY_PRICE_CHANGES"
        value = "false"
      }
      env {
        name  = "GEMINI_MODEL"
        value = "gemini-2.0-flash-lite"
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = local.create && var.enable_public_access ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.dashboard[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "service_uri" { value = local.create ? google_cloud_run_v2_service.dashboard[0].uri : "" }
output "service_name" { value = local.create ? google_cloud_run_v2_service.dashboard[0].name : "" }
