"""BigQuery client — GOOGLE_APPLICATION_CREDENTIALS / ADC. No Ads APIs."""
from __future__ import annotations
import os
from typing import Any
import pandas as pd
from google.cloud import bigquery
from google.oauth2 import service_account

PROJECT_ID = os.getenv("GOOGLE_CLOUD_PROJECT") or os.getenv("GCP_PROJECT_ID") or "key-journal-378204"
DATASET = os.getenv("BIGQUERY_DATASET") or os.getenv("BQ_DATASET") or "marketing_intelligence"

def _client(project_id: str) -> bigquery.Client:
    key = os.getenv("GOOGLE_APPLICATION_CREDENTIALS")
    if key and os.path.isfile(key):
        return bigquery.Client(project=project_id, credentials=service_account.Credentials.from_service_account_file(key))
    return bigquery.Client(project=project_id)

class BigQueryClient:
    def __init__(self, project_id: str | None = None, dataset: str | None = None) -> None:
        self.project_id = project_id or PROJECT_ID
        self.dataset = dataset or DATASET
        self.client = _client(self.project_id)

    def query_to_df(self, sql: str) -> pd.DataFrame:
        return self.client.query(sql).to_dataframe()

    def insert_rows(self, table_name: str, rows: list[dict[str, Any]]) -> bool:
        errors = self.client.insert_rows_json(self.client.dataset(self.dataset).table(table_name), rows)
        if errors:
            raise RuntimeError(str(errors))
        return True

    def get_user_behavior(self, start_date: str, end_date: str) -> pd.DataFrame:
        sql = f"""
        SELECT user_id, event_date, user_segment, price_paid, conversion_flag
        FROM `{self.project_id}.{self.dataset}.user_behavior`
        WHERE event_date BETWEEN @s AND @e
        """
        cfg = bigquery.QueryJobConfig(query_parameters=[
            bigquery.ScalarQueryParameter("s", "DATE", start_date),
            bigquery.ScalarQueryParameter("e", "DATE", end_date),
        ])
        return self.client.query(sql, job_config=cfg).to_dataframe()

    def get_competitor_pricing(self, days: int = 30) -> pd.DataFrame:
        sql = f"""
        SELECT * FROM `{self.project_id}.{self.dataset}.competitor_pricing`
        WHERE scrape_date >= DATE_SUB(CURRENT_DATE(), INTERVAL @d DAY)
        ORDER BY scrape_date DESC
        """
        cfg = bigquery.QueryJobConfig(query_parameters=[bigquery.ScalarQueryParameter("d", "INT64", days)])
        return self.client.query(sql, job_config=cfg).to_dataframe()

    def get_brand_analysis(self, days: int = 30) -> pd.DataFrame:
        sql = f"""
        SELECT * FROM `{self.project_id}.{self.dataset}.brand_analysis`
        WHERE analysis_date >= DATE_SUB(CURRENT_DATE(), INTERVAL @d DAY)
        ORDER BY analysis_date DESC
        """
        cfg = bigquery.QueryJobConfig(query_parameters=[bigquery.ScalarQueryParameter("d", "INT64", days)])
        return self.client.query(sql, job_config=cfg).to_dataframe()
