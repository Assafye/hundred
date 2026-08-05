"""Prometheus metrics sink for feed service and alerting integration."""

from __future__ import annotations

from typing import Sequence

from fastapi import FastAPI
from fastapi.responses import Response
from prometheus_client import Counter, Histogram, generate_latest

from scripts.feed_recommendation_engine import FeedOutcome, RecommendationMetricsSink


FEED_SERVED = Counter(
    "feed_served_total",
    "Number of feed responses served",
    ["experiment_id"],
)
FEED_CLICK = Counter(
    "feed_click_total",
    "Number of clicks on feed posts",
    ["experiment_id"],
)
FEED_RETENTION = Counter(
    "feed_retention_total",
    "Retention outcomes",
    ["experiment_id", "window", "retained"],
)
FEED_LATENCY_MS = Histogram(
    "feed_latency_ms",
    "Feed query latency in milliseconds",
    ["mode"],
    buckets=(20, 50, 80, 120, 180, 250, 350, 500, 750, 1000, 1500),
)


class PrometheusMetricsSink(RecommendationMetricsSink):
    def record_served_feed(self, user_id: str, post_ids: Sequence[str], experiment_id: str) -> None:
        _ = user_id
        FEED_SERVED.labels(experiment_id=experiment_id).inc()

    def record_click(self, user_id: str, post_id: str, experiment_id: str) -> None:
        _ = (user_id, post_id)
        FEED_CLICK.labels(experiment_id=experiment_id).inc()

    def record_feed_outcome(self, outcome: FeedOutcome) -> None:
        FEED_RETENTION.labels(
            experiment_id=outcome.experiment_id,
            window="d1",
            retained=str(outcome.retained_d1).lower(),
        ).inc()
        FEED_RETENTION.labels(
            experiment_id=outcome.experiment_id,
            window="d7",
            retained=str(outcome.retained_d7).lower(),
        ).inc()

    def observe_feed_latency_ms(self, mode: str, latency_ms: float) -> None:
        FEED_LATENCY_MS.labels(mode=mode).observe(max(0.0, latency_ms))


def attach_prometheus_route(app: FastAPI) -> None:
    @app.get("/metrics")
    def metrics() -> Response:
        return Response(generate_latest(), media_type="text/plain; version=0.0.4")
