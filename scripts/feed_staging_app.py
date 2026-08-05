"""Staging app factory for running feed API with Uvicorn.

Environment variables:
- FEED_REDIS_URL (required, redis:// or rediss:// endpoint)
- FEED_QDRANT_URL (required)
- FEED_QDRANT_COLLECTION (default: posts_embeddings)
- FEED_QDRANT_API_KEY (optional)

Notes:
- UPSTASH_REDIS_REST_URL is not compatible with redis-py transport.
    Use the Upstash Redis TCP endpoint (redis:// / rediss://) as FEED_REDIS_URL.
"""

from __future__ import annotations

import os
from urllib.parse import urlparse
from typing import List, Sequence

from fastapi import FastAPI

from scripts.feed_api_service import create_feed_app
from scripts.feed_recommendation_engine import (
    ANNVectorIndex,
    PostCandidate,
    QdrantVectorStore,
    RankingConfig,
    RankingEngine,
    ReRanker,
    RedisFeatureStore,
    SignalWeights,
    RetrievalService,
)


class _QdrantIndexAdapter(ANNVectorIndex):
    """Adapter that maps Qdrant payloads into PostCandidate consistently."""

    def __init__(self, vector_store: QdrantVectorStore):
        super().__init__(vector_store=vector_store)


def create_app() -> FastAPI:
    redis_url = os.getenv('FEED_REDIS_URL', '').strip()
    upstash_rest_url = os.getenv('UPSTASH_REDIS_REST_URL', '').strip()
    qdrant_url = os.getenv('FEED_QDRANT_URL', '').strip()
    qdrant_collection = os.getenv('FEED_QDRANT_COLLECTION', 'posts_embeddings').strip()
    qdrant_api_key = os.getenv('FEED_QDRANT_API_KEY', '').strip()

    if not redis_url:
        if upstash_rest_url:
            raise RuntimeError(
                'UPSTASH_REDIS_REST_URL was provided, but FEED_REDIS_URL is missing. '
                'Use the Upstash Redis endpoint (rediss://...) in FEED_REDIS_URL.'
            )
        raise RuntimeError('FEED_REDIS_URL is required for staging app')
    if not (redis_url.startswith('redis://') or redis_url.startswith('rediss://')):
        raise RuntimeError('FEED_REDIS_URL must start with redis:// or rediss://')

    parsed_redis = urlparse(redis_url)
    if parsed_redis.scheme == 'redis' and (parsed_redis.hostname or '').endswith('upstash.io'):
        redis_url = redis_url.replace('redis://', 'rediss://', 1)
    if not qdrant_url:
        raise RuntimeError('FEED_QDRANT_URL is required for staging app')

    try:
        import redis  # type: ignore
    except Exception as exc:
        raise RuntimeError('redis package missing. Install dependencies from scripts/requirements-feed.txt') from exc

    try:
        from qdrant_client import QdrantClient  # type: ignore
    except Exception as exc:
        raise RuntimeError('qdrant-client package missing. Install dependencies from scripts/requirements-feed.txt') from exc

    redis_client = redis.Redis.from_url(redis_url)
    qdrant_client = QdrantClient(url=qdrant_url, api_key=qdrant_api_key or None)

    feature_store = RedisFeatureStore(redis_client=redis_client)
    vector_store = QdrantVectorStore(
        qdrant_client=qdrant_client,
        collection_name=qdrant_collection,
    )
    vector_index = _QdrantIndexAdapter(vector_store=vector_store)

    config = RankingConfig()
    retrieval = RetrievalService(
        feature_store=feature_store,
        vector_index=vector_index,
        config=config,
    )

    return create_feed_app(
        retrieval_service=retrieval,
        ranking_engine=RankingEngine(weights=SignalWeights(), config=config),
        reranker=ReRanker(config=config),
    )
