"""Streamlit dashboard — SA credentials via env. Ad writes blocked."""
from __future__ import annotations
import os, sys
from pathlib import Path
import pandas as pd
import plotly.express as px
import streamlit as st

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from modules.bigquery_client import BigQueryClient
from modules.brand_analyzer import BrandAnalyzer
from modules.pricing_model import PricingOptimizer

PROJECT = os.getenv("GOOGLE_CLOUD_PROJECT") or os.getenv("GCP_PROJECT_ID", "key-journal-378204")
DATASET = os.getenv("BIGQUERY_DATASET", "marketing_intelligence")
COSTS = pd.DataFrame([
    {"service": "BigQuery", "low": 2.0, "high": 15.0},
    {"service": "Vertex AI", "low": 0.5, "high": 1.0},
    {"service": "Cloud Run", "low": 0.0, "high": 18.0},
    {"service": "Scheduler", "low": 0.02, "high": 0.02},
    {"service": "Storage", "low": 0.0, "high": 0.0},
])

st.set_page_config(page_title="Resumora Marketing Intel", layout="wide")
st.title("Resumora Marketing Intelligence")
st.caption(f"resumora.net · {PROJECT}/{DATASET} · ads never modified")

tab_p, tab_b, tab_c, tab_cost = st.tabs(["Pricing Recommendations", "Brand Perception", "Competitor Alerts", "Cost Dashboard"])

with tab_p:
    opt = PricingOptimizer()
    opt.train(PricingOptimizer.synthesize_demo_frame())
    pred = opt.predict_optimal_price({"price_to_competitor_ratio": 1.0, "conversion_rate": 0.1, "user_segment_encoded": 1, "data_volume": 500})
    st.metric("Recommended price", f"${pred['recommended_price']:.2f}")
    st.metric("Confidence", f"{pred['confidence_score']:.0%}")
    st.warning("Advisory only — does not change Stripe prices.")

with tab_b:
    st.json(BrandAnalyzer.fallback_result("PeerA"))
    if st.button("Run brand analysis"):
        st.dataframe(pd.DataFrame(BrandAnalyzer().generate_weekly_report({"PeerA": "Cheap resumes", "PeerB": "Executive coaching"})))

with tab_c:
    st.info("Competitor pricing loads from BigQuery when data exists.")
    try:
        df = BigQueryClient().get_competitor_pricing(30)
        st.dataframe(df if not df.empty else pd.DataFrame({"note": ["empty"]}))
    except Exception as e:
        st.warning(str(e))

with tab_cost:
    st.dataframe(COSTS)
    mid = COSTS.assign(mid=(COSTS.low + COSTS.high) / 2)
    st.plotly_chart(px.bar(mid, x="service", y="mid", title="Est. monthly midpoint USD"), use_container_width=True)
