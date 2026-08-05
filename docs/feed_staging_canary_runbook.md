# Feed Staging + Canary Runbook

## 1) Connect app to real endpoint
Build app with dart-define values:

- `FEED_API_BASE_URL=https://<staging-feed-host>`
- `FEED_STABLE_EXPERIMENT_ID=feed-stable-v1`
- `FEED_CANARY_EXPERIMENT_ID=feed-canary-v1`
- `FEED_CANARY_RATIO=0.10`

Example:

```bash
flutter run --dart-define=FEED_API_BASE_URL=https://feed-staging.example.com --dart-define=FEED_CANARY_RATIO=0.10
```

Local example (your current base URL):

```bash
flutter run --dart-define=FEED_API_BASE_URL=http://localhost:8000 --dart-define=FEED_CANARY_RATIO=0.10
```

## 2) Start Uvicorn + Prometheus in staging

Set environment variables in staging shell:

- `FEED_REDIS_URL` (must be redis:// or rediss:// endpoint)
- `FEED_QDRANT_URL`
- `FEED_QDRANT_COLLECTION`
- `FEED_QDRANT_API_KEY` (optional)

If you only have `UPSTASH_REDIS_REST_URL`, fetch the Redis endpoint from Upstash console and set it as `FEED_REDIS_URL`.

Run:

```bash
docker compose -f scripts/staging/docker-compose.feed-staging.yml up -d
```

Windows one-command startup (with preflight checks):

```powershell
./scripts/staging/start-feed-staging.ps1
```

Health checks:

- Feed API: `http://<host>:8000/v1/feed/query` (POST)
- Metrics: `http://<host>:8000/metrics`
- Prometheus: `http://<host>:9090`

## 3) Canary rollout plan by experiment_id

1. Deploy with `FEED_CANARY_RATIO=0.05` for 2-4 hours.
2. If pass, raise to `0.10`, then `0.25`, then `0.50`, then `1.00`.
3. After each step, run gate check:

```bash
python scripts/staging/canary_gate_check.py http://<host>:9090
```

4. Roll forward only when gate passes and alert rules stay green.
5. If gate fails, set `FEED_CANARY_RATIO=0.00` and redeploy app config.

## 5) Security note

If API keys or tokens were shared in chat/logs, rotate them before production rollout.

## 4) Alerts
Prometheus alert rules are in:
- [scripts/alerts/feed_alert_rules.yml](scripts/alerts/feed_alert_rules.yml)

Loaded by:
- [scripts/staging/prometheus.feed.yml](scripts/staging/prometheus.feed.yml)
