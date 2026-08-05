# Feed Recommendation System Design

## 1) Objective
A backend recommendation pipeline for feed ranking, hidden from end users and easy to extend.

Core formula:

$$
Score(p, u, t) = \left(\sum_i w_i \cdot s_i(p, u)\right) \cdot e^{-\lambda \Delta t} + \mathbb{1}_{new}(p) \cdot \beta
$$

- $s_i \in [0, 1]$: normalized signals (like, share, view, comment, ...).
- $w_i$: configurable signal weights.
- $\lambda$: time-decay coefficient.
- $\Delta t$: age of post in hours.
- $\beta$: exploration bonus for cold-start items.

## 2) Modular Architecture
- FeatureStore: manages user/post features, interaction history, and popularity windows (Redis-backed).
- RetrievalService: candidate generation using vector search and cosine similarity.
- RankingEngine: computes the linear weighted score + exponential decay + exploration bonus.
- ReRanker: post-processing for diversity and de-duplication.

Implemented skeleton: [scripts/feed_recommendation_engine.py](scripts/feed_recommendation_engine.py)

## 3) Candidate Retrieval (Embeddings)
Recommended embedding models:
- sentence-transformers/all-MiniLM-L6-v2 (fast baseline)
- sentence-transformers/all-mpnet-base-v2 (better quality)
- intfloat/multilingual-e5-base (strong multilingual support)

Flow:
1. Build/refresh user embedding from recent interactions.
2. Query ANN index (HNSW/FAISS/ScaNN) for top-K similar posts.
3. If user cold-start, fallback to Global Popular 24h.

## 4) Re-Ranking Rules (Diversity)
- Remove duplicate post IDs.
- Enforce local constraints, for example:
- max 2 posts from same creator in sequence.
- max 2 posts from same topic in sequence.

This reduces filter bubbles and improves feed variety.

## 5) Cold Start Strategy
- User cold start:
- use Global Popular 24h ranked by normalized engagement.
- Item cold start:
- set is_new_item=true and apply exploration bonus $\beta$ for early exposure.

## 6) Scalability Strategy (1M users)
Split into two tiers:
- Pre-computation (batch/offline):
- update normalized signals,
- compute global popularity windows,
- optionally precompute candidate pools per segment/cohort.
- Real-time serving (online path):
- retrieve candidate pool,
- score with latest context,
- apply re-rank constraints,
- return top N.

Redis usage:
- embeddings cache,
- interaction timelines,
- hot popularity sets,
- short-lived state for recent feed exposures.

Expected bottleneck:
- Vector retrieval latency and fan-out under high QPS.
Mitigations:
- ANN index sharding by language/topic,
- two-stage retrieval (coarse then fine),
- cache top-N candidates per active user,
- degrade gracefully to precomputed pools on peak load.

## 7) Weight and Lambda Selection (Math)
Interpretation:
- Larger $w_i$ means stronger influence of signal $i$.
- Larger $\lambda$ means faster freshness decay.

Practical tuning loop:
1. Start from priors (e.g., share > like > view).
2. Run offline replay/backtest on historical logs.
3. Optimize online KPIs via A/B test.
4. Guard with safety constraints (creator/topic diversity, fairness caps).

Half-life relation:

$$
\text{half-life} = \frac{\ln 2}{\lambda}
$$

Example:
- $\lambda=0.08$ per hour gives half-life of ~8.66 hours.

## 8) Textual Flow Diagram
1. Post created.
2. Content embedding generated and indexed.
3. FeatureStore updates post signals and metadata.
4. Batch jobs refresh popularity and optional precomputed pools.
5. User opens feed.
6. RetrievalService gets candidate set (embedding ANN or cold-start fallback).
7. RankingEngine computes score for each candidate.
8. ReRanker removes duplicates and enforces diversity.
9. Feed returned and exposure logged for monitoring/A-B tests.

## 9) Monitoring and Experimentation
Primary metrics:
- CTR@K (click-through rate on first K feed items)
- Save/Share/Comment rates
- D1/D7 retention impact
- Session depth and dwell time
- Creator/topic diversity score

System metrics:
- p95/p99 feed latency
- ANN retrieval latency
- cache hit ratio
- ranking failures/timeouts

A/B testing for weights:
- Randomly assign users to experiment buckets.
- Keep only one changed parameter group per experiment (e.g., weight set A vs B).
- Log exposure with experiment_id and compute uplift with confidence intervals.
- Roll out progressively with guardrail metrics (latency, retention, abuse reports).

## 10) Extensibility Contract
To add a new signal (e.g., screen_time):
1. Add normalized value to post/user features in FeatureStore pipeline.
2. Add weight entry in SignalWeights.by_signal.
3. No changes required in retrieval, ranking core loops, or re-ranker interfaces.
