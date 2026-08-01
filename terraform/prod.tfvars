# Non-secret production values for CI
project_id          = "key-journal-378204"
billing_account_id  = ""
region              = "us-central1"
environment         = "prod"
budget_amount_usd   = 50
enable_budget_alert = false

bigquery_dataset_name          = "marketing_intelligence"
bigquery_table_expiration_days = 90

cloud_run_service_name  = "marketing-dashboard"
cloud_run_image          = ""
# Public IAM requires run.services.setIamPolicy — leave false if deployer lacks it
enable_public_dashboard  = false
enable_scheduler         = true
scheduler_timezone       = "America/Toronto"

# Leave blank so Cloud Run uses the default Compute SA (no actAs / Project IAM Admin needed)
runtime_service_account_email = ""
