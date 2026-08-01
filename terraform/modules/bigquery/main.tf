variable "project_id" { type = string }
variable "region" { type = string }
variable "dataset_name" { type = string }
variable "table_expiration_days" { type = number }
variable "labels" { type = map(string) }
variable "runtime_service_account_email" {
  type    = string
  default = ""
}

locals {
  partition_expiration_ms = var.table_expiration_days > 0 ? var.table_expiration_days * 24 * 60 * 60 * 1000 : null
}

resource "google_bigquery_dataset" "this" {
  dataset_id                      = var.dataset_name
  project                         = var.project_id
  location                        = var.region
  friendly_name                   = "Resumora Marketing Intelligence"
  description                     = "Read-only marketing intel — no ad-platform writes."
  delete_contents_on_destroy      = false
  default_partition_expiration_ms = local.partition_expiration_ms
  labels                          = var.labels
}

resource "google_bigquery_table" "user_behavior" {
  dataset_id = google_bigquery_dataset.this.dataset_id
  project    = var.project_id
  table_id   = "user_behavior"
  time_partitioning {
    type  = "DAY"
    field = "event_date"
  }
  clustering = ["user_segment", "user_id"]
  schema = jsonencode([
    { name = "user_id", type = "STRING", mode = "REQUIRED" },
    { name = "event_date", type = "DATE", mode = "REQUIRED" },
    { name = "user_segment", type = "STRING", mode = "NULLABLE" },
    { name = "price_paid", type = "FLOAT", mode = "NULLABLE" },
    { name = "conversion_flag", type = "BOOL", mode = "NULLABLE" },
    { name = "plan_tier", type = "STRING", mode = "NULLABLE" },
    { name = "source_channel", type = "STRING", mode = "NULLABLE" }
  ])
}

resource "google_bigquery_table" "competitor_pricing" {
  dataset_id = google_bigquery_dataset.this.dataset_id
  project    = var.project_id
  table_id   = "competitor_pricing"
  time_partitioning {
    type  = "DAY"
    field = "scrape_date"
  }
  clustering = ["competitor_name", "product_tier"]
  schema = jsonencode([
    { name = "competitor_name", type = "STRING", mode = "REQUIRED" },
    { name = "scrape_date", type = "DATE", mode = "REQUIRED" },
    { name = "price", type = "FLOAT", mode = "REQUIRED" },
    { name = "product_tier", type = "STRING", mode = "NULLABLE" },
    { name = "prev_price", type = "FLOAT", mode = "NULLABLE" },
    { name = "url", type = "STRING", mode = "NULLABLE" },
    { name = "notes", type = "STRING", mode = "NULLABLE" }
  ])
}

resource "google_bigquery_table" "brand_analysis" {
  dataset_id = google_bigquery_dataset.this.dataset_id
  project    = var.project_id
  table_id   = "brand_analysis"
  time_partitioning {
    type  = "DAY"
    field = "analysis_date"
  }
  clustering = ["competitor_name"]
  schema = jsonencode([
    { name = "analysis_date", type = "DATE", mode = "REQUIRED" },
    { name = "competitor_name", type = "STRING", mode = "REQUIRED" },
    { name = "sentiment_score", type = "FLOAT", mode = "NULLABLE" },
    { name = "key_themes", type = "STRING", mode = "REPEATED" },
    { name = "gap_summary", type = "STRING", mode = "NULLABLE" },
    { name = "raw_analysis", type = "STRING", mode = "NULLABLE" },
    { name = "model_id", type = "STRING", mode = "NULLABLE" }
  ])
}

resource "google_bigquery_dataset_iam_member" "runtime_editor" {
  count      = var.runtime_service_account_email != "" ? 1 : 0
  dataset_id = google_bigquery_dataset.this.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${var.runtime_service_account_email}"
}

resource "google_bigquery_dataset_iam_member" "runtime_viewer" {
  count      = var.runtime_service_account_email != "" ? 1 : 0
  dataset_id = google_bigquery_dataset.this.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${var.runtime_service_account_email}"
}

output "dataset_id" { value = google_bigquery_dataset.this.dataset_id }
