"""Journey-based load test (closed model) with SLO assertions on exit.

Run:
  locust -f templates/locustfile.py --headless -u 300 -r 30 -t 4m \
    --host http://localhost:8080 --csv results/locust --only-summary

Env:
  SLO_P95=200  SLO_ERRORS=0.5
"""

import os
import random

from locust import HttpUser, between, events, task

SLO_P95_MS = float(os.getenv("SLO_P95", "200"))
SLO_ERROR_PCT = float(os.getenv("SLO_ERRORS", "0.5"))
ID_MAX = int(os.getenv("ID_MAX", "100000"))


class AppUser(HttpUser):
    """Realistic mix: browse dominates, writes are a minority."""

    wait_time = between(1, 3)  # think time, never zero
    host = os.getenv("BASE_URL", "http://localhost:8080")

    def on_start(self):
        # Real auth flow, not a bypass flag.
        with self.client.post("/api/auth/login", json={"user": "perf", "password": "perf"}, catch_response=True) as r:
            if r.status_code != 200:
                r.failure(f"login failed: {r.status_code}")
                return
            token = r.json().get("token")
            if not token:
                r.failure("no token in login response")
                return
            self.client.headers.update({"Authorization": f"Bearer {token}"})

    @task(14)
    def browse_list(self):
        with self.client.get(f"/api/items?page={random.randint(1, 50)}&limit=20", name="/api/items [list]", catch_response=True) as r:
            if r.status_code != 200:
                r.failure(f"status {r.status_code}")
            elif not isinstance(r.json().get("items"), list):
                r.failure("payload shape changed")

    @task(5)
    def read_detail(self):
        with self.client.get(f"/api/items/{random.randint(1, ID_MAX)}", name="/api/items/[id]", catch_response=True) as r:
            if r.status_code != 200:
                r.failure(f"status {r.status_code}")

    @task(3)
    def search(self):
        term = random.choice(["alpha", "beta", "gamma", "delta"])
        with self.client.get(f"/api/search?q={term}", name="/api/search", catch_response=True) as r:
            if r.status_code != 200:
                r.failure(f"status {r.status_code}")

    @task(2)
    def write(self):
        with self.client.post("/api/items", json={"name": f"perf-{random.randint(1, 10**9)}"}, name="/api/items [create]", catch_response=True) as r:
            if r.status_code not in (200, 201):
                r.failure(f"status {r.status_code}")


@events.quitting.add_listener
def assert_slo(environment, **kwargs):
    """Turn the SLO into an exit code so CI and gate scripts can trust it."""
    stats = environment.stats.total
    if stats.num_requests == 0:
        environment.process_exit_code = 1
        print("SLO: FAIL, no requests executed")
        return

    p95 = stats.get_response_time_percentile(0.95)
    error_pct = (stats.num_failures / stats.num_requests) * 100
    print(f"SLO: p95={p95:.1f}ms (target {SLO_P95_MS}) errors={error_pct:.2f}% (target {SLO_ERROR_PCT})")

    failures = []
    if p95 > SLO_P95_MS:
        failures.append(f"p95 {p95:.1f} > {SLO_P95_MS}")
    if error_pct > SLO_ERROR_PCT:
        failures.append(f"error rate {error_pct:.2f}% > {SLO_ERROR_PCT}%")

    if failures:
        environment.process_exit_code = 1
        print("SLO: FAIL, " + "; ".join(failures))
    else:
        environment.process_exit_code = 0
        print("SLO: PASS")
