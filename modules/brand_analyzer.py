"""Gemini Flash-Lite brand analyzer with fallback sentiment 0.62."""
from __future__ import annotations
import json, os, re
from typing import Any

PROJECT_ID = os.getenv("GOOGLE_CLOUD_PROJECT") or os.getenv("GCP_PROJECT_ID") or "key-journal-378204"
LOCATION = os.getenv("VERTEX_LOCATION") or "us-central1"
MODEL_ID = os.getenv("GEMINI_MODEL", "gemini-2.0-flash-lite")

class BrandAnalyzer:
    def __init__(self, project_id: str | None = None, location: str | None = None, model_id: str | None = None) -> None:
        self.project_id = project_id or PROJECT_ID
        self.location = location or LOCATION
        self.model_id = model_id or MODEL_ID
        self._model: Any = None

    def _load(self) -> Any | None:
        if self._model is not None:
            return self._model if self._model is not False else None
        try:
            import vertexai
            from vertexai.generative_models import GenerativeModel
            vertexai.init(project=self.project_id, location=self.location)
            self._model = GenerativeModel(self.model_id)
            return self._model
        except Exception:
            self._model = False
            return None

    @staticmethod
    def fallback_result(competitor_name: str = "unknown") -> dict[str, Any]:
        return {
            "competitor_name": competitor_name,
            "sentiment_score": 0.62,
            "key_themes": ["Mock theme A", "Mock theme B"],
            "raw_analysis": "Fallback analysis",
            "gap_summary": "Fallback analysis",
            "model_id": "fallback-stub",
            "fallback": True,
        }

    def analyze_competitor(self, competitor_name: str, competitor_copy: str, our_brand_copy: str | None = None) -> dict[str, Any]:
        our = our_brand_copy or "Resumora (resumora.net) luxury AI resume builder."
        model = self._load()
        if not model:
            return self.fallback_result(competitor_name)
        prompt = f"Compare OUR vs COMPETITOR. JSON only with sentiment_score,key_themes,raw_analysis,gap_summary.\nOUR:{our}\nCOMPETITOR({competitor_name}):{competitor_copy}"
        try:
            text = re.sub(r"^```(?:json)?\s*|\s*```$", "", (model.generate_content(prompt).text or "").strip(), flags=re.I | re.M)
            data = json.loads(text)
            return {
                "competitor_name": competitor_name,
                "sentiment_score": float(data.get("sentiment_score", 0.62)),
                "key_themes": list(data.get("key_themes") or ["Mock theme A", "Mock theme B"]),
                "raw_analysis": str(data.get("raw_analysis") or "Fallback analysis"),
                "gap_summary": str(data.get("gap_summary") or ""),
                "model_id": self.model_id,
                "fallback": False,
            }
        except Exception:
            return self.fallback_result(competitor_name)

    def generate_weekly_report(self, competitors: dict[str, str], our_brand_copy: str | None = None) -> list[dict[str, Any]]:
        return [self.analyze_competitor(n, c, our_brand_copy) for n, c in competitors.items()]
