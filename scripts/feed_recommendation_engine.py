"""Feed recommendation architecture skeleton.

This module is intentionally backend-oriented and not exposed to end users.
It is designed for maintainability and easy extension of new ranking signals.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import logging
from math import exp, log1p, sqrt
import random
import struct
import time
from typing import Any, Callable, Dict, Iterable, List, Literal, Optional, Protocol, Sequence, cast

try:
    import numpy as np
except ImportError:  # pragma: no cover - numpy is optional in this skeleton.
    np = None


logger = logging.getLogger(__name__)


# Recommended sentence-transformer embedding models for content retrieval.
RECOMMENDED_EMBEDDING_MODELS: Sequence[str] = (
    "sentence-transformers/all-MiniLM-L6-v2",  # fast, strong baseline
    "sentence-transformers/all-mpnet-base-v2",  # higher quality, heavier
    "intfloat/multilingual-e5-base",  # good for multilingual feeds
)


@dataclass(frozen=True)
class PostCandidate:
    post_id: str
    creator_id: str
    topic_id: str
    created_at_unix_s: int
    embedding: Sequence[float]
    signals: Dict[str, float]  # raw or semi-normalized engagement signals.
    is_new_item: bool = False


@dataclass(frozen=True)
class UserContext:
    user_id: str
    now_unix_s: int
    user_embedding: Optional[Sequence[float]] = None
    is_cold_start_user: bool = False


@dataclass(frozen=True)
class SignalWeights:
    by_signal: Dict[str, float] = field(
        default_factory=lambda: {
            "like": 0.40,
            "share": 0.30,
            "view": 0.20,
            "comment": 0.10,
            # Extend here for new signals, e.g. "screen_time": 0.15
        }
    )


@dataclass(frozen=True)
class RankingConfig:
    lambda_decay: float = 0.08
    exploration_bonus: float = 0.10
    exploration_lambda_decay: float = 0.30
    min_personalized_exploration_similarity: float = 0.10
    exploration_max_ratio_of_base_score: float = 0.35
    candidate_pool_size: int = 500
    max_same_creator_streak: int = 2
    max_same_topic_streak: int = 2
    seen_history_window_s: int = 5184000
    seen_history_limit: int = 2000
    retrieval_overfetch_multiplier: int = 3
    exploration_epsilon: float = 0.20
    exploration_injection_ratio: float = 0.20
    similarity_skip_threshold: float = 0.90
    signal_log_base: float = 10.0
    signal_caps: Dict[str, float] = field(
        default_factory=lambda: {
            "like": 10000.0,
            "share": 5000.0,
            "view": 200000.0,
            "comment": 5000.0,
        }
    )
    max_page_size: int = 100
    vector_search_timeout_ms: int = 250
    vector_search_latency_budget_ms: int = 300
    circuit_breaker_failure_threshold: int = 3
    circuit_breaker_open_seconds: int = 30
    max_post_age_s: int = 5184000
    following_lambda_decay: float = 0.12
    allow_following_popular_fallback: bool = False


class FeatureStore(Protocol):
    """Persistent state and feature provider (Redis + offline stores)."""

    def get_user_embedding(self, user_id: str) -> Optional[Sequence[float]]:
        ...

    def get_global_popular_24h(self, limit: int) -> List[PostCandidate]:
        ...

    def get_recent_user_interactions(self, user_id: str, limit: int = 200) -> List[str]:
        ...

    def get_recently_seen_post_ids(
        self,
        user_id: str,
        within_seconds: int = 5184000,
        limit: int = 2000,
    ) -> List[str]:
        ...

    def get_recently_seen_topic_ids(
        self,
        user_id: str,
        within_seconds: int = 5184000,
        limit: int = 500,
    ) -> List[str]:
        ...

    def upsert_user_embedding(self, user_id: str, embedding: Sequence[float]) -> None:
        ...

    def get_following_posts(self, user_id: str, limit: int) -> List[PostCandidate]:
        ...


class VectorIndex(Protocol):
    """ANN index interface for vector retrieval."""

    def search(self, query_vector: Sequence[float], k: int) -> List[PostCandidate]:
        ...


class ANNVectorStore(Protocol):
    """Backend protocol for production vector DBs (Qdrant/Pinecone/Milvus/Weaviate)."""

    def query(self, query_vector: Sequence[float], k: int, timeout_ms: Optional[int] = None) -> List[PostCandidate]:
        ...


class ANNVectorIndex:
    """VectorIndex adapter that forces ANN retrieval through a vector database."""

    def __init__(self, vector_store: ANNVectorStore) -> None:
        self.vector_store = vector_store

    def search(self, query_vector: Sequence[float], k: int) -> List[PostCandidate]:
        return self.vector_store.query(query_vector=query_vector, k=k)

    def search_with_timeout(self, query_vector: Sequence[float], k: int, timeout_ms: int) -> List[PostCandidate]:
        return self.vector_store.query(query_vector=query_vector, k=k, timeout_ms=timeout_ms)


class QdrantVectorStore:
    """Example ANN store adapter using Qdrant's indexed similarity search."""

    def __init__(self, qdrant_client, collection_name: str) -> None:
        self.client = qdrant_client
        self.collection_name = collection_name

    def query(self, query_vector: Sequence[float], k: int, timeout_ms: Optional[int] = None) -> List[PostCandidate]:
        # Uses ANN in Qdrant; no manual full-scan cosine search in Python.
        hits = self.client.search(
            collection_name=self.collection_name,
            query_vector=list(query_vector),
            limit=k,
            with_payload=True,
            timeout=(max(1, timeout_ms) / 1000.0) if timeout_ms is not None else None,
        )

        output: List[PostCandidate] = []
        for hit in hits:
            payload = getattr(hit, "payload", {}) or {}
            output.append(
                PostCandidate(
                    post_id=str(payload.get("post_id") or getattr(hit, "id", "")),
                    creator_id=str(payload.get("creator_id", "")),
                    topic_id=str(payload.get("topic_id", "unknown")),
                    created_at_unix_s=int(payload.get("created_at_unix_s", int(time.time()))),
                    embedding=payload.get("embedding", []),
                    signals=dict(payload.get("signals", {})),
                    is_new_item=bool(payload.get("is_new_item", False)),
                )
            )
        return output


@dataclass(frozen=True)
class FeedOutcome:
    user_id: str
    experiment_id: str
    served_post_ids: Sequence[str]
    clicked_post_ids: Sequence[str]
    retained_d1: bool
    retained_d7: bool


class RedisFeatureStore:
    """Reference implementation shape for Redis-backed features.

    Suggested Redis key design:
    - user:{uid}:embedding -> vector blob
    - user:{uid}:interactions -> sorted set by timestamp
    - global:popular:24h -> sorted set of post ids by engagement score
    - post:{pid}:features -> hash with normalized signals + metadata
    """

    def __init__(self, redis_client) -> None:
        self.redis = redis_client

    def get_user_embedding(self, user_id: str) -> Optional[Sequence[float]]:
        key = f"user:{user_id}:embedding"
        raw = self.redis.get(key)
        return decode_float32_vector(raw)

    def get_global_popular_24h(self, limit: int) -> List[PostCandidate]:
        ids = self.redis.zrevrange("global:popular:24h", 0, max(0, limit - 1))
        output: List[PostCandidate] = []
        for raw_post_id in ids:
            post_id = as_text(raw_post_id)
            candidate = self._load_post_candidate(post_id)
            if candidate is not None:
                output.append(candidate)
        return output

    def get_recent_user_interactions(self, user_id: str, limit: int = 200) -> List[str]:
        key = f"user:{user_id}:interactions"
        rows = self.redis.zrevrange(key, 0, max(0, limit - 1))
        return [as_text(v) for v in rows]

    def get_recently_seen_post_ids(
        self,
        user_id: str,
        within_seconds: int = 5184000,
        limit: int = 2000,
    ) -> List[str]:
        now = int(time.time())
        min_score = now - max(0, within_seconds)
        key = f"user:{user_id}:seen_posts"
        # Proactive cleanup for bounded memory usage.
        self.redis.zremrangebyscore(key, 0, min_score - 1)
        rows = self.redis.zrevrangebyscore(key, now, min_score, start=0, num=limit)
        return [as_text(v) for v in rows]

    def get_recently_seen_topic_ids(
        self,
        user_id: str,
        within_seconds: int = 5184000,
        limit: int = 500,
    ) -> List[str]:
        now = int(time.time())
        min_score = now - max(0, within_seconds)
        key = f"user:{user_id}:seen_topics"
        self.redis.zremrangebyscore(key, 0, min_score - 1)
        rows = self.redis.zrevrangebyscore(key, now, min_score, start=0, num=limit)
        return [as_text(v) for v in rows]

    def upsert_user_embedding(self, user_id: str, embedding: Sequence[float]) -> None:
        key = f"user:{user_id}:embedding"
        self.redis.set(key, encode_float32_vector(embedding))

    def get_following_posts(self, user_id: str, limit: int) -> List[PostCandidate]:
        # Optimized path: pre-fanned feed per user, stored as a sorted set ordered by publish time.
        key = f"user:{user_id}:following_feed"
        ids = self.redis.zrevrange(key, 0, max(0, limit - 1))
        output: List[PostCandidate] = []
        for raw_post_id in ids:
            post_id = as_text(raw_post_id)
            candidate = self._load_post_candidate(post_id)
            if candidate is not None:
                output.append(candidate)
        return output

    def _load_post_candidate(self, post_id: str) -> Optional[PostCandidate]:
        raw = self.redis.hgetall(f"post:{post_id}:features")
        if not raw:
            return None

        created_at_unix_s = int(float(as_text(raw.get(b"created_at_unix_s") or raw.get("created_at_unix_s") or "0")))
        creator_id = as_text(raw.get(b"creator_id") or raw.get("creator_id") or "")
        topic_id = as_text(raw.get(b"topic_id") or raw.get("topic_id") or "unknown")
        is_new_item_raw = as_text(raw.get(b"is_new_item") or raw.get("is_new_item") or "0")
        embedding_raw = raw.get(b"embedding") if isinstance(raw, dict) else None
        if embedding_raw is None and isinstance(raw, dict):
            embedding_raw = raw.get("embedding")
        embedding = decode_float32_vector(embedding_raw) or []

        signals = {
            "like": safe_float(as_text(raw.get(b"like") or raw.get("like") or "0")),
            "share": safe_float(as_text(raw.get(b"share") or raw.get("share") or "0")),
            "view": safe_float(as_text(raw.get(b"view") or raw.get("view") or "0")),
            "comment": safe_float(as_text(raw.get(b"comment") or raw.get("comment") or "0")),
        }

        return PostCandidate(
            post_id=post_id,
            creator_id=creator_id,
            topic_id=topic_id,
            created_at_unix_s=created_at_unix_s,
            embedding=embedding,
            signals=signals,
            is_new_item=is_new_item_raw in {"1", "true", "True"},
        )


class RetrievalService:
    """Candidate generation focused on user-interest similarity and controlled exploration."""

    def __init__(
        self,
        feature_store: FeatureStore,
        vector_index: VectorIndex,
        config: Optional[RankingConfig] = None,
        rng: Optional[random.Random] = None,
    ) -> None:
        self.feature_store = feature_store
        self.vector_index = vector_index
        self.config = config or RankingConfig()
        self.rng = rng or random.Random()
        self._cb_state = "closed"
        self._cb_failures = 0
        self._cb_open_until_unix_s = 0
        self._cold_start_fallback_counts: Dict[str, int] = {}

    def generate_candidates(
        self,
        user: UserContext,
        k: int,
        mode: Literal["discovery", "following"] = "discovery",
        topic_allowlist: Optional[Sequence[str]] = None,
    ) -> List[PostCandidate]:
        fetch_k = max(k, 1) * self.config.retrieval_overfetch_multiplier
        topic_allowlist_set = {
            t.strip() for t in (topic_allowlist or []) if isinstance(t, str) and t.strip()
        }
        try:
            seen_post_ids = set(
                self.feature_store.get_recently_seen_post_ids(
                    user_id=user.user_id,
                    within_seconds=self.config.seen_history_window_s,
                    limit=self.config.seen_history_limit,
                )
            )
            seen_topic_ids = set(
                self.feature_store.get_recently_seen_topic_ids(
                    user_id=user.user_id,
                    within_seconds=self.config.seen_history_window_s,
                    limit=500,
                )
            )
        except Exception:
            self._record_cold_start_fallback("redis_seen_history_error")
            logger.exception("Seen-history read failed, continuing with empty seen sets for user_id=%s", user.user_id)
            seen_post_ids = set()
            seen_topic_ids = set()

        if mode == "following":
            # Social graph retrieval path from Redis sorted set.
            try:
                candidates = self.feature_store.get_following_posts(user_id=user.user_id, limit=fetch_k)
            except Exception:
                self._record_cold_start_fallback("redis_following_feed_error")
                logger.exception("Following-feed read failed for user_id=%s", user.user_id)
                candidates = []
        elif user.is_cold_start_user:
            self._record_cold_start_fallback("cold_start_flag")
            candidates = self._safe_global_popular(fetch_k, user.user_id)
        elif user.user_embedding is None:
            self._record_cold_start_fallback("missing_user_embedding")
            candidates = self._safe_global_popular(fetch_k, user.user_id)
        else:
            # Interest graph retrieval: pull by content similarity to user embedding.
            candidates = self._safe_vector_search(user=user, fetch_k=fetch_k)

        seen_output: set[str] = set()
        filtered = self._collect_candidates(
            source=candidates,
            seen_post_ids=seen_post_ids,
            seen_output=seen_output,
            limit=k,
            now_unix_s=user.now_unix_s,
            max_post_age_s=self.config.max_post_age_s,
            topic_allowlist_set=topic_allowlist_set,
        )

        if (
            mode == "discovery"
            and user.user_embedding is not None
            and self.rng.random() < self.config.exploration_epsilon
        ):
            explore_quota = max(1, int(k * self.config.exploration_injection_ratio))
            explore_pool = self.feature_store.get_global_popular_24h(limit=fetch_k)
            exploration_candidates = self._pick_exploration_candidates(
                source=explore_pool,
                seen_post_ids=seen_post_ids,
                seen_output=seen_output,
                seen_topic_ids=seen_topic_ids,
                limit=explore_quota,
                now_unix_s=user.now_unix_s,
                max_post_age_s=self.config.max_post_age_s,
                topic_allowlist_set=topic_allowlist_set,
            )
            filtered = self._inject_exploration(filtered, exploration_candidates, k)
            seen_output = {p.post_id for p in filtered}

        if len(filtered) >= k:
            return filtered[:k]

        # Fallback fill: discovery can use global popular, following uses controlled fallback.
        if len(filtered) < k:
            fallback_candidates: List[PostCandidate] = []
            if mode == "discovery":
                fallback_candidates = self._safe_global_popular(fetch_k, user.user_id)
            elif self.config.allow_following_popular_fallback:
                fallback_candidates = self._safe_global_popular(fetch_k, user.user_id)

            if fallback_candidates:
                filtered.extend(
                    self._collect_candidates(
                        source=fallback_candidates,
                        seen_post_ids=seen_post_ids,
                        seen_output=seen_output,
                        limit=k - len(filtered),
                        now_unix_s=user.now_unix_s,
                        max_post_age_s=self.config.max_post_age_s,
                        topic_allowlist_set=topic_allowlist_set,
                    )
                )

        logger.debug(
            "Retrieval mode=%s user_id=%s requested=%d returned=%d",
            mode,
            user.user_id,
            k,
            len(filtered),
        )

        return filtered[:k]

    def get_cold_start_fallback_counts(self) -> Dict[str, int]:
        return dict(self._cold_start_fallback_counts)

    def _safe_vector_search(self, user: UserContext, fetch_k: int) -> List[PostCandidate]:
        now = int(time.time())
        if self._is_circuit_open(now):
            self._record_cold_start_fallback("circuit_open")
            logger.warning("Vector retrieval bypassed due to open circuit for user_id=%s", user.user_id)
            return self._safe_global_popular(fetch_k, user.user_id)

        start = time.perf_counter()
        try:
            results = self._invoke_vector_search_with_timeout(user.user_embedding or [], fetch_k)
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            if elapsed_ms > self.config.vector_search_latency_budget_ms:
                self._register_circuit_failure(now)
                self._record_cold_start_fallback("vector_search_latency")
                logger.warning(
                    "Vector retrieval exceeded latency budget (%.1fms > %dms), falling back for user_id=%s",
                    elapsed_ms,
                    self.config.vector_search_latency_budget_ms,
                    user.user_id,
                )
                return self._safe_global_popular(fetch_k, user.user_id)

            self._register_circuit_success()
            logger.debug(
                "Vector retrieval success user_id=%s candidates=%d latency_ms=%.2f",
                user.user_id,
                len(results),
                elapsed_ms,
            )
            return results
        except Exception:
            self._register_circuit_failure(now)
            self._record_cold_start_fallback("vector_search_error")
            logger.exception("Vector retrieval failed, using global popular fallback for user_id=%s", user.user_id)
            return self._safe_global_popular(fetch_k, user.user_id)

    def _safe_global_popular(self, fetch_k: int, user_id: str) -> List[PostCandidate]:
        try:
            return self.feature_store.get_global_popular_24h(limit=fetch_k)
        except Exception:
            self._record_cold_start_fallback("redis_global_popular_error")
            logger.exception("Global-popular fallback failed for user_id=%s", user_id)
            return []

    def _invoke_vector_search_with_timeout(self, query_vector: Sequence[float], k: int) -> List[PostCandidate]:
        search_with_timeout = cast(
            Optional[Callable[..., List[PostCandidate]]],
            getattr(self.vector_index, "search_with_timeout", None),
        )
        if callable(search_with_timeout):
            return search_with_timeout(
                query_vector=query_vector,
                k=k,
                timeout_ms=self.config.vector_search_timeout_ms,
            )
        return self.vector_index.search(query_vector=query_vector, k=k)

    def _is_circuit_open(self, now_unix_s: int) -> bool:
        if self._cb_state != "open":
            return False
        if now_unix_s >= self._cb_open_until_unix_s:
            self._cb_state = "half_open"
            return False
        return True

    def _register_circuit_failure(self, now_unix_s: int) -> None:
        self._cb_failures += 1
        if self._cb_failures >= self.config.circuit_breaker_failure_threshold:
            self._cb_state = "open"
            self._cb_open_until_unix_s = now_unix_s + self.config.circuit_breaker_open_seconds

    def _register_circuit_success(self) -> None:
        self._cb_failures = 0
        self._cb_state = "closed"
        self._cb_open_until_unix_s = 0

    def _record_cold_start_fallback(self, reason: str) -> None:
        self._cold_start_fallback_counts[reason] = self._cold_start_fallback_counts.get(reason, 0) + 1
        logger.debug(
            "Cold-start fallback reason=%s count=%d",
            reason,
            self._cold_start_fallback_counts[reason],
        )

    @staticmethod
    def _collect_candidates(
        source: List[PostCandidate],
        seen_post_ids: set[str],
        seen_output: set[str],
        limit: int,
        now_unix_s: int,
        max_post_age_s: int,
        topic_allowlist_set: Optional[set[str]] = None,
    ) -> List[PostCandidate]:
        output: List[PostCandidate] = []
        for post in source:
            if max_post_age_s > 0 and (now_unix_s - post.created_at_unix_s) > max_post_age_s:
                continue
            if topic_allowlist_set and post.topic_id not in topic_allowlist_set:
                continue
            if post.post_id in seen_post_ids or post.post_id in seen_output:
                continue
            output.append(post)
            seen_output.add(post.post_id)
            if len(output) >= limit:
                break
        return output

    def _pick_exploration_candidates(
        self,
        source: List[PostCandidate],
        seen_post_ids: set[str],
        seen_output: set[str],
        seen_topic_ids: set[str],
        limit: int,
        now_unix_s: int,
        max_post_age_s: int,
        topic_allowlist_set: Optional[set[str]] = None,
    ) -> List[PostCandidate]:
        # Prefer topics with low recent exposure to avoid filter bubbles.
        unseen_topic_pool = [
            p
            for p in source
            if p.topic_id not in seen_topic_ids
            and (not topic_allowlist_set or p.topic_id in topic_allowlist_set)
            and p.post_id not in seen_post_ids
            and p.post_id not in seen_output
            and (max_post_age_s <= 0 or (now_unix_s - p.created_at_unix_s) <= max_post_age_s)
        ]
        remaining_pool = [
            p
            for p in source
            if (not topic_allowlist_set or p.topic_id in topic_allowlist_set)
            and p.post_id not in seen_post_ids
            and p.post_id not in seen_output
            and p not in unseen_topic_pool
            and (max_post_age_s <= 0 or (now_unix_s - p.created_at_unix_s) <= max_post_age_s)
        ]

        self.rng.shuffle(unseen_topic_pool)
        self.rng.shuffle(remaining_pool)
        combined = unseen_topic_pool + remaining_pool
        return combined[:limit]

    @staticmethod
    def _inject_exploration(
        primary: List[PostCandidate],
        exploratory: List[PostCandidate],
        limit: int,
    ) -> List[PostCandidate]:
        if not exploratory:
            return primary[:limit]
        if not primary:
            return exploratory[:limit]

        output: List[PostCandidate] = []
        primary_idx = 0
        explore_idx = 0
        gap = max(1, int(limit / max(1, len(exploratory))))

        while len(output) < limit and (primary_idx < len(primary) or explore_idx < len(exploratory)):
            if len(output) % (gap + 1) == gap and explore_idx < len(exploratory):
                output.append(exploratory[explore_idx])
                explore_idx += 1
            elif primary_idx < len(primary):
                output.append(primary[primary_idx])
                primary_idx += 1
            elif explore_idx < len(exploratory):
                output.append(exploratory[explore_idx])
                explore_idx += 1

        return output[:limit]


class RankingEngine:
    """Computes: score = sum(w_i * s_i) * exp(-lambda * delta_t) + exploration_bonus"""

    def __init__(self, weights: SignalWeights, config: RankingConfig) -> None:
        self.weights = weights
        self.config = config
        self._signal_order = tuple(self.weights.by_signal.keys())
        self._weight_vector_np = None
        if np is not None:
            np_mod = cast(Any, np)
            self._weight_vector_np = np_mod.asarray(
                [self.weights.by_signal[s] for s in self._signal_order],
                dtype=np_mod.float64,
            )

    def score_post(
        self,
        post: PostCandidate,
        now_unix_s: int,
        user_embedding: Optional[Sequence[float]] = None,
        lambda_decay_override: Optional[float] = None,
        enable_exploration_bonus: bool = True,
    ) -> float:
        weighted_signal_sum = self._weighted_signal_sum(post.signals)

        delta_hours = max(0.0, (now_unix_s - post.created_at_unix_s) / 3600.0)
        lambda_decay = self.config.lambda_decay if lambda_decay_override is None else lambda_decay_override
        time_decay = exp(-lambda_decay * delta_hours)
        exploration = 0.0
        if enable_exploration_bonus:
            exploration = self._personalized_exploration_bonus(
                post=post,
                delta_hours=delta_hours,
                weighted_signal_sum=weighted_signal_sum,
                user_embedding=user_embedding,
            )

        return weighted_signal_sum * time_decay + exploration

    def _weighted_signal_sum(self, signals: Dict[str, float]) -> float:
        normalized = normalize_signals_log_scaled(
            signals=signals,
            caps=self.config.signal_caps,
            log_base=self.config.signal_log_base,
        )

        if self._weight_vector_np is not None and np is not None:
            np_mod = cast(Any, np)
            signal_vector = np_mod.asarray(
                [self._clamp_01(normalized.get(s, 0.0)) for s in self._signal_order],
                dtype=np_mod.float64,
            )
            return float(self._weight_vector_np.dot(signal_vector))

        total = 0.0
        for signal_name, weight in self.weights.by_signal.items():
            total += weight * self._clamp_01(normalized.get(signal_name, 0.0))
        return total

    def _personalized_exploration_bonus(
        self,
        post: PostCandidate,
        delta_hours: float,
        weighted_signal_sum: float,
        user_embedding: Optional[Sequence[float]],
    ) -> float:
        if not post.is_new_item or user_embedding is None:
            return 0.0

        similarity = max(0.0, cosine_similarity(user_embedding, post.embedding))
        min_similarity = self.config.min_personalized_exploration_similarity
        if similarity <= min_similarity:
            return 0.0

        age_decay = exp(-self.config.exploration_lambda_decay * delta_hours)
        personalized_factor = (similarity - min_similarity) / max(1e-6, (1.0 - min_similarity))
        raw_bonus = self.config.exploration_bonus * age_decay * personalized_factor

        # Bound exploration so freshness does not dominate weak relevance.
        capped_bonus = weighted_signal_sum * self.config.exploration_max_ratio_of_base_score
        return min(raw_bonus, capped_bonus)

    @staticmethod
    def _clamp_01(value: float) -> float:
        return max(0.0, min(1.0, value))


class ReRanker:
    """Removes duplicates and enforces local diversity in final feed ordering."""

    def __init__(self, config: RankingConfig) -> None:
        self.config = config

    def rerank(self, ranked: List[tuple[PostCandidate, float]], limit: int) -> List[PostCandidate]:
        seen_post_ids: set[str] = set()
        output: List[PostCandidate] = []
        blocked_by_diversity: List[PostCandidate] = []
        creator_streak = 0
        topic_streak = 0
        last_creator: Optional[str] = None
        last_topic: Optional[str] = None

        for post, _ in ranked:
            if post.post_id in seen_post_ids:
                continue

            next_creator_streak = creator_streak + 1 if post.creator_id == last_creator else 1
            next_topic_streak = topic_streak + 1 if post.topic_id == last_topic else 1

            if next_creator_streak > self.config.max_same_creator_streak:
                blocked_by_diversity.append(post)
                continue
            if next_topic_streak > self.config.max_same_topic_streak:
                blocked_by_diversity.append(post)
                continue

            if output:
                previous = output[-1]
                if cosine_similarity(previous.embedding, post.embedding) > self.config.similarity_skip_threshold:
                    blocked_by_diversity.append(post)
                    continue

            output.append(post)
            seen_post_ids.add(post.post_id)

            creator_streak = next_creator_streak
            topic_streak = next_topic_streak
            last_creator = post.creator_id
            last_topic = post.topic_id

            if len(output) >= limit:
                break

        # Fallback: if strict diversity constraints over-prune candidates, fill the rest by score order.
        # This path intentionally applies minimal filtering (dedupe only) to guarantee page fill.
        if len(output) < limit:
            for post in blocked_by_diversity:
                if post.post_id in seen_post_ids:
                    continue
                output.append(post)
                seen_post_ids.add(post.post_id)
                if len(output) >= limit:
                    break

        return output


class RecommendationMetricsSink(Protocol):
    """Monitoring hook for online metrics and A/B experiment logging."""

    def record_served_feed(self, user_id: str, post_ids: Sequence[str], experiment_id: str) -> None:
        ...

    def record_click(self, user_id: str, post_id: str, experiment_id: str) -> None:
        ...

    def record_feed_outcome(self, outcome: FeedOutcome) -> None:
        ...


class FeedRecommendationService:
    """High-level orchestration: retrieval -> ranking -> re-ranking."""

    def __init__(
        self,
        feature_store: FeatureStore,
        retrieval_service: RetrievalService,
        ranking_engine: RankingEngine,
        reranker: ReRanker,
        metrics_sink: Optional[RecommendationMetricsSink] = None,
    ) -> None:
        self.feature_store = feature_store
        self.retrieval_service = retrieval_service
        self.ranking_engine = ranking_engine
        self.reranker = reranker
        self.metrics_sink = metrics_sink

    def build_feed(
        self,
        user: UserContext,
        page_size: int,
        experiment_id: str = "default",
        mode: Literal["discovery", "following"] = "discovery",
        topic_allowlist: Optional[Sequence[str]] = None,
    ) -> List[PostCandidate]:
        # Backward-compatible entrypoint with optional mode override.
        return self.build_feed_by_mode(
            user=user,
            page_size=page_size,
            mode=mode,
            experiment_id=experiment_id,
            topic_allowlist=topic_allowlist,
        )

    def build_feed_by_mode(
        self,
        user: UserContext,
        page_size: int,
        mode: Literal["discovery", "following"],
        experiment_id: str = "default",
        topic_allowlist: Optional[Sequence[str]] = None,
    ) -> List[PostCandidate]:
        if page_size <= 0:
            raise ValueError("page_size must be > 0")
        if page_size > self.ranking_engine.config.max_page_size:
            raise ValueError(f"page_size must be <= {self.ranking_engine.config.max_page_size}")

        lambda_override = (
            self.ranking_engine.config.following_lambda_decay
            if mode == "following"
            else None
        )
        enable_exploration_bonus = mode == "discovery"

        t0 = time.perf_counter()
        candidates = self.retrieval_service.generate_candidates(
            user=user,
            k=max(page_size, 1) * 5,
            mode=mode,
            topic_allowlist=topic_allowlist,
        )
        t_retrieval = (time.perf_counter() - t0) * 1000.0

        t1 = time.perf_counter()
        scored = [
            (
                post,
                self.ranking_engine.score_post(
                    post=post,
                    now_unix_s=user.now_unix_s,
                    user_embedding=user.user_embedding,
                    lambda_decay_override=lambda_override,
                    enable_exploration_bonus=enable_exploration_bonus,
                ),
            )
            for post in candidates
        ]
        scored.sort(key=lambda pair: pair[1], reverse=True)
        t_ranking = (time.perf_counter() - t1) * 1000.0

        t2 = time.perf_counter()
        feed = self.reranker.rerank(scored, limit=page_size)
        t_rerank = (time.perf_counter() - t2) * 1000.0

        if self.metrics_sink is not None:
            self.metrics_sink.record_served_feed(
                user_id=user.user_id,
                post_ids=[p.post_id for p in feed],
                experiment_id=experiment_id,
            )

        logger.debug(
            "Feed build mode=%s user_id=%s exp=%s page_size=%d candidates=%d feed=%d latency_ms(retrieval=%.2f ranking=%.2f rerank=%.2f)",
            mode,
            user.user_id,
            experiment_id,
            page_size,
            len(candidates),
            len(feed),
            t_retrieval,
            t_ranking,
            t_rerank,
        )
        return feed

    def record_outcome(
        self,
        user_id: str,
        experiment_id: str,
        served_post_ids: Sequence[str],
        clicked_post_ids: Sequence[str],
        retained_d1: bool,
        retained_d7: bool,
    ) -> None:
        if self.metrics_sink is None:
            return

        outcome = FeedOutcome(
            user_id=user_id,
            experiment_id=experiment_id,
            served_post_ids=served_post_ids,
            clicked_post_ids=clicked_post_ids,
            retained_d1=retained_d1,
            retained_d7=retained_d7,
        )
        self.metrics_sink.record_feed_outcome(outcome)


class BatchScoreUpdater:
    """Offline/pre-compute process to support large-scale traffic.

    At scale, run this as a scheduled job:
    1) refresh normalized engagement features,
    2) refresh global popularity windows,
    3) optionally pre-compute top-N candidate pools per user segment.
    """

    def __init__(self, feature_store: FeatureStore, ranking_engine: RankingEngine) -> None:
        self.feature_store = feature_store
        self.ranking_engine = ranking_engine

    def run(self, user_ids: Iterable[str], now_unix_s: int) -> None:
        # TODO: Implement chunked/batch updates (e.g., 1k users per batch).
        # This should be distributed across workers for million-user scale.
        for _user_id in user_ids:
            # Placeholder for batch pre-computation logic.
            _ = now_unix_s


class UserEmbeddingUpdater:
    """Real-time interest learning via exponential moving average on embeddings."""

    def __init__(self, feature_store: FeatureStore, alpha: float = 0.85) -> None:
        self.feature_store = feature_store
        self.alpha = max(0.0, min(1.0, alpha))

    def update_from_feedback(self, user_id: str, post_embedding: Sequence[float]) -> Sequence[float]:
        old_embedding = self.feature_store.get_user_embedding(user_id)
        if old_embedding is None:
            new_embedding = list(post_embedding)
        else:
            new_embedding = ema_blend_vectors(old_embedding, post_embedding, self.alpha)

        self.feature_store.upsert_user_embedding(user_id=user_id, embedding=new_embedding)
        return new_embedding


def cosine_similarity(a: Sequence[float], b: Sequence[float]) -> float:
    """Utility for local testing and fallback retrieval."""

    if len(a) != len(b) or not a:
        return 0.0

    dot = sum(x * y for x, y in zip(a, b))
    norm_a = sqrt(sum(x * x for x in a))
    norm_b = sqrt(sum(y * y for y in b))
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


def ema_blend_vectors(old_vector: Sequence[float], new_signal_vector: Sequence[float], alpha: float) -> List[float]:
    """UserVector_new = alpha * UserVector_old + (1-alpha) * PostVector_clicked."""

    if len(old_vector) != len(new_signal_vector):
        return list(new_signal_vector)

    bounded_alpha = max(0.0, min(1.0, alpha))
    one_minus_alpha = 1.0 - bounded_alpha

    if np is not None:
        old_np = np.asarray(old_vector, dtype=np.float64)
        new_np = np.asarray(new_signal_vector, dtype=np.float64)
        return list((bounded_alpha * old_np + one_minus_alpha * new_np).tolist())

    return [
        bounded_alpha * old_v + one_minus_alpha * new_v
        for old_v, new_v in zip(old_vector, new_signal_vector)
    ]


def normalize_signals_log_scaled(
    signals: Dict[str, float],
    caps: Dict[str, float],
    log_base: float = 10.0,
) -> Dict[str, float]:
    """Normalize heavy-tail engagement counts into [0, 1] with capped log scaling."""

    output: Dict[str, float] = {}
    if log_base <= 1.0:
        log_base = 10.0

    if np is not None:
        for name, value in signals.items():
            cap = max(1.0, caps.get(name, 1.0))
            clipped = max(0.0, min(float(value), cap))
            output[name] = float(np.log1p(clipped) / np.log1p(cap)) if cap > 0.0 else 0.0
        return output

    for name, value in signals.items():
        cap = max(1.0, caps.get(name, 1.0))
        clipped = max(0.0, min(float(value), cap))
        output[name] = _safe_log1p(clipped) / _safe_log1p(cap) if cap > 0.0 else 0.0
    return output


def compute_ctr(served_post_ids: Sequence[str], clicked_post_ids: Sequence[str]) -> float:
    """CTR over a served feed slice: unique clicked items divided by unique served items."""

    served = {p for p in served_post_ids if p}
    if not served:
        return 0.0
    clicked = {p for p in clicked_post_ids if p}
    return len(served.intersection(clicked)) / len(served)


def encode_float32_vector(vector: Sequence[float]) -> bytes:
    """Binary encoding: [4-byte length][float32 * length]."""

    values = [float(v) for v in vector]
    length_prefix = struct.pack("<I", len(values))
    if np is not None:
        payload = np.asarray(values, dtype=np.float32).tobytes(order="C")
    else:
        payload = struct.pack(f"<{len(values)}f", *values) if values else b""
    return length_prefix + payload


def decode_float32_vector(raw: Optional[bytes]) -> Optional[List[float]]:
    if not raw or len(raw) < 4:
        return None

    if isinstance(raw, str):
        return None

    dim = struct.unpack("<I", raw[:4])[0]
    payload = raw[4:]
    expected = dim * 4
    if len(payload) < expected:
        return None

    payload = payload[:expected]
    if np is not None:
        return list(np.frombuffer(payload, dtype=np.float32, count=dim).astype(np.float64))
    if dim == 0:
        return []
    return list(struct.unpack(f"<{dim}f", payload))


def as_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="ignore")
    return str(value)


def safe_float(value: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _safe_log1p(value: float) -> float:
    if value <= -1.0:
        return 0.0
    return log1p(value)
