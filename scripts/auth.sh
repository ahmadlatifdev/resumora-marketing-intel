#!/usr/bin/env bash
# Hands-free GCP auth using a Service Account JSON key only.
# NEVER runs interactive "gcloud auth login".
set -euo pipefail

SA_KEY_PATH="${SA_KEY_PATH:-}"
PROJECT_ID="${GCP_PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-resumora-live}}"

if [[ -z "$SA_KEY_PATH" ]]; then
  read -r -p "Path to Service Account JSON key (SA_KEY_PATH): " SA_KEY_PATH
fi

if [[ ! -f "$SA_KEY_PATH" ]]; then
  echo "SA key file not found: $SA_KEY_PATH" >&2
  exit 1
fi

SA_KEY_PATH="$(cd "$(dirname "$SA_KEY_PATH")" && pwd)/$(basename "$SA_KEY_PATH")"

echo "==> Activating service account (no browser login)..."
gcloud auth activate-service-account --key-file="$SA_KEY_PATH" --quiet

export GOOGLE_APPLICATION_CREDENTIALS="$SA_KEY_PATH"
export SA_KEY_PATH
export GCP_PROJECT_ID="$PROJECT_ID"
export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

gcloud config set project "$PROJECT_ID" --quiet

echo "OK: SA activated"
echo "    GOOGLE_APPLICATION_CREDENTIALS=$SA_KEY_PATH"
echo "    project=$PROJECT_ID"
echo "Next: cd terraform && terraform apply -var-file=prod.tfvars"
echo "Tip: source this script so exports persist:  source scripts/auth.sh"
