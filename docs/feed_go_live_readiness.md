# Feed Go-Live Readiness

## What Was Added
- API layer: [scripts/feed_api_service.py](scripts/feed_api_service.py)
- Prometheus metrics sink: [scripts/feed_metrics.py](scripts/feed_metrics.py)
- Async worker skeleton for embedding updates: [scripts/feed_event_worker.py](scripts/feed_event_worker.py)
- Unit tests: [scripts/tests/test_feed_engine.py](scripts/tests/test_feed_engine.py)
- Basic load test: [scripts/load_test_feed_api.py](scripts/load_test_feed_api.py)
- Alert rules: [scripts/alerts/feed_alert_rules.yml](scripts/alerts/feed_alert_rules.yml)
- Python deps: [scripts/requirements-feed.txt](scripts/requirements-feed.txt)

## Run API Locally
1. Install deps:
   pip install -r scripts/requirements-feed.txt
2. Build app in your bootstrap code by creating a `RetrievalService` with production `FeatureStore` and `VectorIndex`.
3. Run with Uvicorn:
   uvicorn scripts.feed_api_service:create_default_feed_app --factory --host 0.0.0.0 --port 8000

## API Contract
- Endpoint: `POST /v1/feed/query`
- Inputs:
  - `user_id`
  - `mode`: `discovery` or `following`
  - `page_size` (1..100)
  - `topic_allowlist` (optional)
  - `experiment_id`
  - `cursor` (opaque, optional)
- Errors:
  - `INVALID_CURSOR` (400)
  - `INVALID_ARGUMENT` (400)
  - `INTERNAL` (500)

## Run Tests
- `python -m unittest scripts.tests.test_feed_engine`

## Run Load Test
- `python scripts/load_test_feed_api.py http://localhost:8000/v1/feed/query 30 600`

## Production Checklist
- Connect a real ANN vector DB and Redis cluster.
- Wire queue consumer for embedding updates.
- Connect `/metrics` to Prometheus and load alert rules.
- Run canary rollout by experiment_id and compare CTR/retention.
