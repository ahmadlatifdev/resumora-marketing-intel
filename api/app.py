"""Cloud Run job API for Scheduler — no ad writes."""
from __future__ import annotations
import os, sys
from datetime import date
from pathlib import Path
from flask import Flask, jsonify

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from modules.bigquery_client import BigQueryClient
from modules.brand_analyzer import BrandAnalyzer
from modules.pricing_model import PricingOptimizer

app = Flask(__name__)
os.environ.setdefault("AD_PLATFORM_WRITE_ENABLED", "false")

@app.get("/healthz")
def healthz():
    return jsonify({"ok": True, "ads_write": False})

@app.post("/api/brand-analysis")
def brand_analysis():
    results = BrandAnalyzer().generate_weekly_report({"PeerA": "Cheap resumes", "PeerB": "Executive coaching"})
    today = date.today().isoformat()
    rows = [{
        "analysis_date": today,
        "competitor_name": r["competitor_name"],
        "sentiment_score": r["sentiment_score"],
        "key_themes": r.get("key_themes") or [],
        "gap_summary": r.get("gap_summary"),
        "raw_analysis": r.get("raw_analysis"),
        "model_id": r.get("model_id"),
    } for r in results]
    try:
        BigQueryClient().insert_rows("brand_analysis", rows)
        return jsonify({"ok": True, "stored": True, "count": len(rows)})
    except Exception as e:
        return jsonify({"ok": True, "stored": False, "results": results, "error": str(e)})

@app.post("/api/competitor-scrape")
def competitor_scrape():
    today = date.today().isoformat()
    rows = [
        {"competitor_name": "PeerA", "scrape_date": today, "price": 29.99, "product_tier": "basic", "prev_price": 34.99, "url": "https://example.com/a", "notes": "mock"},
        {"competitor_name": "PeerB", "scrape_date": today, "price": 79.0, "product_tier": "premium", "prev_price": 79.0, "url": "https://example.com/b", "notes": "mock"},
    ]
    try:
        BigQueryClient().insert_rows("competitor_pricing", rows)
        return jsonify({"ok": True, "stored": True})
    except Exception as e:
        return jsonify({"ok": True, "stored": False, "error": str(e)})

@app.post("/api/model-retrain")
def model_retrain():
    opt = PricingOptimizer()
    metrics = opt.train(PricingOptimizer.synthesize_demo_frame())
    return jsonify({"ok": True, "metrics": metrics, "advisory_only": True})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
