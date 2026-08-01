"""RandomForest pricing optimizer — advisory only."""
from __future__ import annotations
from typing import Any
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_absolute_error
from sklearn.model_selection import train_test_split

FEATURE_COLS = ["price_to_competitor_ratio", "conversion_rate", "user_segment_encoded", "data_volume"]

class PricingOptimizer:
    def __init__(self, n_estimators: int = 100, random_state: int = 42) -> None:
        self.model = RandomForestRegressor(n_estimators=n_estimators, random_state=random_state, n_jobs=-1)
        self.is_fitted = False
        self.last_mae: float | None = None

    @staticmethod
    def synthesize_demo_frame(n: int = 400, seed: int = 7) -> pd.DataFrame:
        rng = np.random.default_rng(seed)
        seg = rng.integers(0, 3, size=n)
        ratio = rng.uniform(0.6, 1.4, size=n)
        conv = np.clip(0.25 - 0.12 * (ratio - 1.0) + rng.normal(0, 0.03, n), 0.01, 0.5)
        vol = rng.integers(50, 2000, size=n)
        price = 29 + 25 * seg + 40 * ratio + rng.normal(0, 3, n)
        return pd.DataFrame({
            "price_to_competitor_ratio": ratio,
            "conversion_rate": conv,
            "user_segment_encoded": seg,
            "data_volume": vol,
            "optimal_price": price,
        })

    def train(self, df: pd.DataFrame, target_col: str = "optimal_price") -> dict[str, Any]:
        x, y = df[FEATURE_COLS], df[target_col]
        xtr, xte, ytr, yte = train_test_split(x, y, test_size=0.2, random_state=42)
        self.model.fit(xtr, ytr)
        self.last_mae = float(mean_absolute_error(yte, self.model.predict(xte)))
        self.is_fitted = True
        return {"mae": self.last_mae, "n_train": len(xtr), "n_test": len(xte)}

    def predict_optimal_price(self, features: dict[str, Any]) -> dict[str, Any]:
        if not self.is_fitted:
            self.train(self.synthesize_demo_frame())
        row = np.array([[float(features.get(c, 0)) for c in FEATURE_COLS]])
        price = float(self.model.predict(row)[0])
        tree = np.array([t.predict(row)[0] for t in self.model.estimators_])
        conf = float(np.clip(1.0 - (tree.std() / max(price, 1.0)), 0.35, 0.95))
        return {"recommended_price": round(price, 2), "confidence_score": round(conf, 3), "advisory_only": True}
