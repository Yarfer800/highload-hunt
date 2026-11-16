-- Deterministic production-like dataset for Postgres.
-- Rename tables/columns to match the project, then run:
--
--   psql "$DATABASE_URL" -v rows=1000000 -f templates/seed-postgres.sql
--
-- The dataset is stable: the same :rows always produces the same ids and values,
-- so runs stay comparable. Keep the row count in PERF-REPORT.md.

\set ON_ERROR_STOP on
\set rows 1000000
\set tenants 500
\set users 50000

DROP TABLE IF EXISTS perf_items;
DROP TABLE IF EXISTS perf_users;

CREATE TABLE perf_users (
  id          bigint PRIMARY KEY,
  email       text   NOT NULL,
  tenant_id   integer NOT NULL,
  created_at  timestamptz NOT NULL
);

CREATE TABLE perf_items (
  id          bigint PRIMARY KEY,
  user_id     bigint NOT NULL,
  tenant_id   integer NOT NULL,
  title       text NOT NULL,
  status      text NOT NULL,
  price_cents integer NOT NULL,
  created_at  timestamptz NOT NULL
);

-- Users: spread over tenants, unique emails, 3 years of signups.
INSERT INTO perf_users (id, email, tenant_id, created_at)
SELECT
  g,
  'user' || g || '@perf.local',
  (g % :tenants) + 1,
  timestamptz '2023-01-01 00:00:00+00' + (g % 94608000) * interval '1 second'
FROM generate_series(1, :users) AS g;

-- Items: :rows rows, skewed ownership (Zipf-ish), beta status distribution,
-- 30 days of creation dates so time filters have real cardinality.
INSERT INTO perf_items (id, user_id, tenant_id, title, status, price_cents, created_at)
SELECT
  g,
  (g % :users) + 1,
  (g % :tenants) + 1,
  'item-' || g || '-' || substr(md5(g::text), 1, 8),
  CASE
    WHEN g % 100 < 70 THEN 'active'
    WHEN g % 100 < 90 THEN 'draft'
    ELSE 'archived'
  END,
  (g * 7919) % 100000,
  timestamptz '2026-10-17 00:00:00+00' + (g % 2592000) * interval '1 second'
FROM generate_series(1, :rows) AS g;

ANALYZE perf_users;
ANALYZE perf_items;

-- Indexes are part of the schema under test. Measure with and without the
-- index that matches the hot filter instead of assuming it exists.
CREATE INDEX perf_items_user_created_idx ON perf_items (user_id, created_at DESC);
CREATE INDEX perf_items_tenant_status_idx ON perf_items (tenant_id, status);

SELECT
  (SELECT count(*) FROM perf_users) AS users,
  (SELECT count(*) FROM perf_items) AS items,
  (SELECT count(DISTINCT tenant_id) FROM perf_items) AS tenants;
