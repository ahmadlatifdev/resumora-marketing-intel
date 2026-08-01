variable "project_id" { type = string }
variable "region" { type = string }
variable "environment" { type = string }
variable "bucket_name" { type = string }
variable "labels" { type = map(string) }
variable "runtime_service_account_email" {
  type        = string
  description = "Existing SA for Cloud Run/Scheduler (avoids needing Project IAM Admin)"
  default     = ""
}

resource "google_storage_bucket" "data" {
  name                        = var.bucket_name
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false
  labels                      = var.labels
  versioning { enabled = true }

  lifecycle_rule {
    condition { age = 30 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }
  lifecycle_rule {
    condition { age = 365 }
    action { type = "Delete" }
  }
}

# Optional dedicated SA — created only when runtime_service_account_email is blank.
# Project-level IAM bindings removed: deployer often lacks roles/resourcemanager.projectIamAdmin.
resource "google_service_account" "marketing_sa" {
  count        = var.runtime_service_account_email == "" ? 1 : 0
  account_id   = "resumora-mkt-intel"
  display_name = "Resumora Marketing Intelligence SA"
  project      = var.project_id
}

# Bucket-level IAM (does not require project IAM policy update)
resource "google_storage_bucket_iam_member" "runtime_object_admin" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${coalesce(var.runtime_service_account_email, try(google_service_account.marketing_sa[0].email, ""))}"
}

output "bucket_name" { value = google_storage_bucket.data.name }
output "service_account_email" {
  value = coalesce(var.runtime_service_account_email, try(google_service_account.marketing_sa[0].email, ""))
}
