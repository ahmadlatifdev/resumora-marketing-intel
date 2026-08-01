#!/usr/bin/env bash
# Local bootstrap for resumora-marketing-intel (Linux / macOS / WSL / Git Bash)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "==> Resumora Marketing Intelligence quickstart"
echo "    Isolation: no Meta/TikTok/Google Ads campaign API calls"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required (3.11+)" >&2
  exit 1
fi

PYTHON_BIN="${PYTHON_BIN:-python3}"
if [[ ! -d .venv ]]; then
  "$PYTHON_BIN" -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

if [[ ! -f terraform/prod.tfvars ]]; then
  cp terraform/prod.tfvars.example terraform/prod.tfvars
  echo "Created terraform/prod.tfvars from example — edit project_id / billing_account_id"
fi

if command -v terraform >/dev/null 2>&1; then
  PROJECT_ID="${GCP_PROJECT_ID:-$(grep -E '^project_id' terraform/prod.tfvars | sed -E 's/.*=\s*\"?([^\"]+)\"?.*/\1/' || true)}"
  if [[ -n "${PROJECT_ID}" && "${PROJECT_ID}" != "YOUR_PROJECT_ID" ]]; then
    echo "==> terraform init (GCS backend resumora-terraform-state-${PROJECT_ID})"
    (
      cd terraform
      terraform init -input=false \
        -backend-config="bucket=resumora-terraform-state-${PROJECT_ID}" \
        -backend-config="prefix=marketing-intelligence" || true
    )
  else
    echo "Skip terraform init — set project_id in terraform/prod.tfvars first"
  fi
else
  echo "terraform not installed — install from https://developer.hashicorp.com/terraform"
fi

echo ""
echo "Next:"
echo "  1. gcloud auth application-default login"
echo "  2. streamlit run dashboard/app.py"
echo "  3. Add GitHub secrets: GCP_PROJECT_ID, GCP_SA_KEY, SLACK_WEBHOOK_URL"
echo "  4. Push to main to deploy via Marketing Intel Deploy workflow"
