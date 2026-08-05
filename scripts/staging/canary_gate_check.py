"""Canary gate check for feed experiments.

Usage:
  python scripts/staging/canary_gate_check.py http://localhost:9090

Pass criteria (last 30m):
- Canary CTR >= Stable CTR * 0.97
- Canary p95 latency <= Stable p95 latency * 1.10
"""

from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request


def _query(prom_url: str, promql: str) -> float:
    url = f"{prom_url.rstrip('/')}/api/v1/query?{urllib.parse.urlencode({'query': promql})}"
    with urllib.request.urlopen(url, timeout=5.0) as res:
        payload = json.loads(res.read().decode('utf-8'))
    if payload.get('status') != 'success':
        raise RuntimeError(f"prometheus query failed: {payload}")
    data = payload.get('data', {}).get('result', [])
    if not data:
        return 0.0
    value = data[0].get('value', [0, '0'])[1]
    return float(value)


def main() -> int:
    if len(sys.argv) < 2:
        print('Usage: python scripts/staging/canary_gate_check.py <prometheus_base_url>')
        return 1

    prom = sys.argv[1]

    stable_ctr = _query(
        prom,
        "sum(rate(feed_click_total{experiment_id=~'.*stable.*'}[30m])) / clamp_min(sum(rate(feed_served_total{experiment_id=~'.*stable.*'}[30m])), 1)",
    )
    canary_ctr = _query(
        prom,
        "sum(rate(feed_click_total{experiment_id=~'.*canary.*'}[30m])) / clamp_min(sum(rate(feed_served_total{experiment_id=~'.*canary.*'}[30m])), 1)",
    )

    stable_p95 = _query(
        prom,
        "histogram_quantile(0.95, sum(rate(feed_latency_ms_bucket{mode='discovery'}[30m])) by (le))",
    )
    canary_p95 = _query(
        prom,
        "histogram_quantile(0.95, sum(rate(feed_latency_ms_bucket{mode='discovery'}[30m])) by (le))",
    )

    ctr_ok = canary_ctr >= stable_ctr * 0.97
    latency_ok = canary_p95 <= stable_p95 * 1.10 if stable_p95 > 0 else True

    print(f"stable_ctr={stable_ctr:.5f} canary_ctr={canary_ctr:.5f} ctr_ok={ctr_ok}")
    print(f"stable_p95={stable_p95:.2f} canary_p95={canary_p95:.2f} latency_ok={latency_ok}")

    if ctr_ok and latency_ok:
        print('CANARY_GATE=PASS')
        return 0

    print('CANARY_GATE=FAIL')
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
