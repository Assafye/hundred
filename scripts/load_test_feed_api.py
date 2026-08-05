"""Basic load test for feed API.

Usage:
  python scripts/load_test_feed_api.py http://localhost:8000/v1/feed/query 30 600
"""

from __future__ import annotations

import json
import statistics
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed


def _post(url: str, payload: dict) -> tuple[int, float]:
    started = time.perf_counter()
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST", headers={"Content-Type": "application/json"})
    status = 0
    try:
        with urllib.request.urlopen(req, timeout=5.0) as res:
            status = int(res.status)
            _ = res.read()
    except Exception:
        status = 0
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    return status, elapsed_ms


def main() -> int:
    if len(sys.argv) < 4:
        print("Usage: python scripts/load_test_feed_api.py <url> <workers> <requests>")
        return 1

    url = sys.argv[1]
    workers = int(sys.argv[2])
    total_requests = int(sys.argv[3])

    latencies = []
    ok = 0
    lock = threading.Lock()

    def one_call(i: int) -> tuple[int, float]:
        payload = {
            "user_id": f"load_user_{i % 200}",
            "mode": "discovery",
            "page_size": 20,
            "experiment_id": "load-test-v1",
            "topic_allowlist": ["sports", "tech"],
        }
        return _post(url, payload)

    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futures = [ex.submit(one_call, i) for i in range(total_requests)]
        for f in as_completed(futures):
            status, latency = f.result()
            with lock:
                latencies.append(latency)
                if status == 200:
                    ok += 1

    total_s = time.perf_counter() - started
    latencies.sort()
    p50 = latencies[int(0.50 * len(latencies))] if latencies else 0.0
    p95 = latencies[int(0.95 * len(latencies))] if latencies else 0.0
    p99 = latencies[int(0.99 * len(latencies))] if latencies else 0.0
    rps = total_requests / total_s if total_s > 0 else 0.0

    print(f"requests={total_requests} ok={ok} success_rate={ok/total_requests:.2%}")
    print(f"rps={rps:.2f} total_s={total_s:.2f}")
    print(f"latency_ms p50={p50:.2f} p95={p95:.2f} p99={p99:.2f} mean={statistics.mean(latencies):.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
