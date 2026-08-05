import unittest

from scripts.feed_recommendation_engine import (
    PostCandidate,
    RankingConfig,
    RankingEngine,
    RetrievalService,
    ReRanker,
    SignalWeights,
    UserContext,
)


class FakeFeatureStore:
    def __init__(self, following_posts=None, popular_posts=None, raise_seen=False):
        self.following_posts = following_posts or []
        self.popular_posts = popular_posts or []
        self.raise_seen = raise_seen

    def get_user_embedding(self, user_id):
        _ = user_id
        return [1.0, 0.0]

    def get_global_popular_24h(self, limit):
        return self.popular_posts[:limit]

    def get_recent_user_interactions(self, user_id, limit=200):
        _ = (user_id, limit)
        return []

    def get_recently_seen_post_ids(self, user_id, within_seconds=5184000, limit=2000):
        _ = (user_id, within_seconds, limit)
        if self.raise_seen:
            raise RuntimeError("redis unavailable")
        return []

    def get_recently_seen_topic_ids(self, user_id, within_seconds=5184000, limit=500):
        _ = (user_id, within_seconds, limit)
        if self.raise_seen:
            raise RuntimeError("redis unavailable")
        return []

    def upsert_user_embedding(self, user_id, embedding):
        _ = (user_id, embedding)

    def get_following_posts(self, user_id, limit):
        _ = user_id
        return self.following_posts[:limit]


class FakeVectorIndex:
    def __init__(self, items):
        self.items = items

    def search(self, query_vector, k):
        _ = query_vector
        return self.items[:k]


def make_post(post_id, topic, created_at=1_700_000_000):
    return PostCandidate(
        post_id=post_id,
        creator_id="u1",
        topic_id=topic,
        created_at_unix_s=created_at,
        embedding=[1.0, 0.0],
        signals={"like": 10, "view": 100},
        is_new_item=True,
    )


class FeedEngineTests(unittest.TestCase):
    def test_topic_allowlist_applies_before_ranking(self):
        posts = [make_post("p1", "sports"), make_post("p2", "tech")]
        store = FakeFeatureStore(popular_posts=posts)
        service = RetrievalService(feature_store=store, vector_index=FakeVectorIndex(posts), config=RankingConfig())
        user = UserContext(user_id="u", now_unix_s=1_700_010_000, user_embedding=[1.0, 0.0])

        out = service.generate_candidates(user=user, k=10, mode="discovery", topic_allowlist=["sports"])
        self.assertEqual([p.post_id for p in out], ["p1"])

    def test_following_stops_when_no_posts(self):
        cfg = RankingConfig(allow_following_popular_fallback=False)
        store = FakeFeatureStore(following_posts=[], popular_posts=[make_post("pX", "tech")])
        service = RetrievalService(feature_store=store, vector_index=FakeVectorIndex([]), config=cfg)
        user = UserContext(user_id="u", now_unix_s=1_700_010_000, user_embedding=[1.0, 0.0])

        out = service.generate_candidates(user=user, k=20, mode="following")
        self.assertEqual(out, [])

    def test_redis_seen_failure_does_not_crash(self):
        posts = [make_post("p1", "sports")]
        store = FakeFeatureStore(popular_posts=posts, raise_seen=True)
        service = RetrievalService(feature_store=store, vector_index=FakeVectorIndex(posts), config=RankingConfig())
        user = UserContext(user_id="u", now_unix_s=1_700_010_000, user_embedding=[1.0, 0.0])

        out = service.generate_candidates(user=user, k=5, mode="discovery")
        self.assertTrue(len(out) >= 1)

    def test_following_disables_exploration_bonus(self):
        cfg = RankingConfig(exploration_bonus=1.0)
        engine = RankingEngine(weights=SignalWeights(), config=cfg)
        post = make_post("p1", "sports")
        now = 1_700_010_000

        score_discovery = engine.score_post(
            post=post,
            now_unix_s=now,
            user_embedding=[1.0, 0.0],
            enable_exploration_bonus=True,
        )
        score_following = engine.score_post(
            post=post,
            now_unix_s=now,
            user_embedding=[1.0, 0.0],
            enable_exploration_bonus=False,
        )
        self.assertGreater(score_discovery, score_following)


if __name__ == "__main__":
    unittest.main()
