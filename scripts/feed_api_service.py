"""Production-oriented API layer for feed recommendation serving.

This file wraps the ranking engine with a stable HTTP contract:
- mode-aware feed retrieval
- pagination cursor
- explicit error payloads
- observability hooks
"""

from __future__ import annotations

import base64
import json
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Literal, Optional, Sequence

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from scripts.feed_recommendation_engine import (
    FeedRecommendationService,
    PostCandidate,
    RecommendationMetricsSink,
    RetrievalService,
    ReRanker,
    RankingConfig,
    RankingEngine,
    SignalWeights,
    UserContext,
)
from scripts.feed_metrics import PrometheusMetricsSink, attach_prometheus_route


FeedMode = Literal["discovery", "following"]


class FeedQueryRequest(BaseModel):
    user_id: str = Field(min_length=1)
    mode: FeedMode = "discovery"
    page_size: int = Field(default=20, ge=1, le=100)
    topic_allowlist: Optional[List[str]] = None
    experiment_id: str = "default"
    cursor: Optional[str] = None
    now_unix_s: Optional[int] = None


class FeedItemResponse(BaseModel):
    post_id: str
    creator_id: str
    topic_id: str
    created_at_unix_s: int
    score_debug: Optional[float] = None


class FeedQueryResponse(BaseModel):
    items: List[FeedItemResponse]
    next_cursor: Optional[str]
    has_more: bool


class ApiError(BaseModel):
    code: str
    message: str


@dataclass
class FeedServiceContainer:
    service: FeedRecommendationService
    metrics: RecommendationMetricsSink


def _encode_cursor(offset: int) -> str:
    payload = {"offset": max(0, offset)}
    blob = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(blob).decode("ascii")


def _decode_cursor(cursor: Optional[str]) -> int:
    if not cursor:
        return 0
    try:
        blob = base64.urlsafe_b64decode(cursor.encode("ascii"))
        payload = json.loads(blob.decode("utf-8"))
        return max(0, int(payload.get("offset", 0)))
    except Exception:
        raise HTTPException(status_code=400, detail=ApiError(code="INVALID_CURSOR", message="cursor is invalid").model_dump())


def _to_item(post: PostCandidate) -> FeedItemResponse:
    return FeedItemResponse(
        post_id=post.post_id,
        creator_id=post.creator_id,
        topic_id=post.topic_id,
        created_at_unix_s=post.created_at_unix_s,
    )


def create_feed_app(
    retrieval_service: RetrievalService,
    ranking_engine: RankingEngine,
    reranker: ReRanker,
    metrics_sink: Optional[RecommendationMetricsSink] = None,
) -> FastAPI:
    app = FastAPI(title="Feed Recommendation API", version="1.0.0")

    sink: RecommendationMetricsSink = metrics_sink or PrometheusMetricsSink()
    service = FeedRecommendationService(
        feature_store=retrieval_service.feature_store,
        retrieval_service=retrieval_service,
        ranking_engine=ranking_engine,
        reranker=reranker,
        metrics_sink=sink,
    )
    attach_prometheus_route(app)

    @app.post("/v1/feed/query", response_model=FeedQueryResponse, responses={400: {"model": ApiError}, 500: {"model": ApiError}})
    def query_feed(body: FeedQueryRequest) -> FeedQueryResponse:
        started = time.perf_counter()
        now_unix_s = body.now_unix_s or int(time.time())
        offset = _decode_cursor(body.cursor)

        try:
            # Fetch a superset and page on top for stable cursor semantics.
            pull_size = min(100, max(body.page_size * 3, body.page_size + offset + 5))
            user = UserContext(
                user_id=body.user_id,
                now_unix_s=now_unix_s,
                user_embedding=retrieval_service.feature_store.get_user_embedding(body.user_id),
                is_cold_start_user=False,
            )
            feed = service.build_feed_by_mode(
                user=user,
                page_size=pull_size,
                mode=body.mode,
                experiment_id=body.experiment_id,
                topic_allowlist=body.topic_allowlist,
            )
            page = feed[offset : offset + body.page_size]
            next_offset = offset + len(page)
            has_more = next_offset < len(feed)
            next_cursor = _encode_cursor(next_offset) if has_more else None
            return FeedQueryResponse(
                items=[_to_item(p) for p in page],
                next_cursor=next_cursor,
                has_more=has_more,
            )
        except HTTPException:
            raise
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=ApiError(code="INVALID_ARGUMENT", message=str(exc)).model_dump())
        except Exception:
            raise HTTPException(
                status_code=500,
                detail=ApiError(code="INTERNAL", message="feed query failed").model_dump(),
            )
        finally:
            latency_ms = (time.perf_counter() - started) * 1000.0
            if isinstance(sink, PrometheusMetricsSink):
                sink.observe_feed_latency_ms(mode=body.mode, latency_ms=latency_ms)

    return app


def create_default_feed_app(retrieval_service: RetrievalService) -> FastAPI:
    config = retrieval_service.config
    return create_feed_app(
        retrieval_service=retrieval_service,
        ranking_engine=RankingEngine(weights=SignalWeights(), config=config),
        reranker=ReRanker(config=config),
    )
