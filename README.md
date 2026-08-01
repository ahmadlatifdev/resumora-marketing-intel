# Resumora Marketing Intelligence

Standalone GCP stack for resumora.net. **No ad-platform APIs.** Auth via SA JSON only.

## Secrets
- `GCP_PROJECT_ID` = `key-journal-378204`
- `GCP_SA_KEY` = deployer SA JSON
- `SLACK_WEBHOOK_URL` = optional

## Layout
`terraform/`, `modules/`, `dashboard/`, `api/`, `.github/workflows/terraform-ci-cd.yml`
