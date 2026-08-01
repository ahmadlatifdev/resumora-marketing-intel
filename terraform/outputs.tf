output "bigquery_dataset_id" {
  value = module.bigquery.dataset_id
}

output "storage_bucket_name" {
  value = module.storage.bucket_name
}

output "service_account_email" {
  value     = module.storage.service_account_email
  sensitive = true
}

output "vertex_ai_endpoint_name" {
  value = module.vertex_ai.endpoint_name
}

output "cloud_run_url" {
  value       = module.cloud_run.service_uri
  description = "Live Cloud Run URL (empty until cloud_run_image is set)"
}

output "safety_note" {
  value = "No Meta/TikTok/Google Ads campaign APIs. SA-key auth only."
}
