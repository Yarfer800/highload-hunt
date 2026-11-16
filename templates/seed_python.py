#!/usr/bin/env python3
"""Deterministic dataset generator, standard library only.

    python3 templates/seed_python.py > /tmp/seed.sql
    psql "$DATABASE_URL" -f /tmp/seed.sql

    ROWS=2000000 python3 templates/seed_python.py > /tmp/seed.sql

Emits SQL so it needs no driver. Adjust the table shape to the project schema.
Record ROWS and SEED in PERF-REPORT.md so runs stay comparable.
"""

import os
import random
import sys
from datetime import datetime, timedelta, timezone

ROWS = int(os.getenv("ROWS", "1000000"))
USERS = int(os.getenv("USERS", "50000"))
TENANTS = int(os.getenv("TENANTS", "500"))
SEED = int(os.getenv("SEED", "42"))

STATUSES = ["active"] * 7 + ["draft"] * 2 + ["archived"]
BASE = datetime(2023, 1, 1, tzinfo=timezone.utc)
RECENT = datetime(2026, 10, 17, tzinfo=timezone.utc)

rand = random.Random(SEED)
out = sys.stdout


def write(line: str = "") -> None:
    out.write(line + "\n")


def ts(moment: datetime) -> str:
    return moment.isoformat()


write("BEGIN;")
write("TRUNCATE perf_items, perf_users RESTART IDENTITY;")

write("INSERT INTO perf_users (id, email, tenant_id, created_at) VALUES")
batch = []
for i in range(1, USERS + 1):
    tenant = (i % TENANTS) + 1
    created = BASE + timedelta(seconds=rand.randrange(0, 94_608_000))
    batch.append(f"({i},'user{i}@perf.local',{tenant},'{ts(created)}')")
    if len(batch) == 1000:
        write(",".join(batch) + ";")
        batch.clear()
        if i < USERS:
            write("INSERT INTO perf_users (id, email, tenant_id, created_at) VALUES")
if batch:
    write(",".join(batch) + ";")

write("INSERT INTO perf_items (id, user_id, tenant_id, title, status, price_cents, created_at) VALUES")
batch = []
for i in range(1, ROWS + 1):
    user_id = (i % USERS) + 1
    tenant = (i % TENANTS) + 1
    status = STATUSES[i % len(STATUSES)]
    price = (i * 7919) % 100_000
    created = RECENT + timedelta(seconds=rand.randrange(0, 2_592_000))
    batch.append(f"({i},{user_id},{tenant},'item-{i}','{status}',{price},'{ts(created)}')")
    if len(batch) == 1000:
        write(",".join(batch) + ";")
        batch.clear()
        if i < ROWS:
            write("INSERT INTO perf_items (id, user_id, tenant_id, title, status, price_cents, created_at) VALUES")
if batch:
    write(",".join(batch) + ";")

write("CREATE INDEX IF NOT EXISTS perf_items_user_created_idx ON perf_items (user_id, created_at DESC);")
write("CREATE INDEX IF NOT EXISTS perf_items_tenant_status_idx ON perf_items (tenant_id, status);")
write("ANALYZE perf_users;")
write("ANALYZE perf_items;")
write("COMMIT;")
