variable "project_id" { type = string }
variable "region" { type = string }
variable "environment" { type = string }
variable "labels" { type = map(string) }

resource "google_vertex_ai_endpoint" "batch" {
  name         = "resumora-mkt-batch-endpoint-${var.environment}"
  display_name = "Resumora Marketing Batch Endpoint"
  location     = var.region
  project      = var.project_id
  labels       = var.labels
  description  = "Batch / on-demand only — no always-on compute."
}

output "endpoint_name" { value = google_vertex_ai_endpoint.batch.name }
output "endpoint_id" { value = google_vertex_ai_endpoint.batch.id }
