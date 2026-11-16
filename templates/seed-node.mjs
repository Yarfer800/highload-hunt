#!/usr/bin/env node
// Deterministic dataset generator, zero dependencies.
//
//   node templates/seed-node.mjs > /tmp/seed.sql
//   psql "$DATABASE_URL" -f /tmp/seed.sql
//
//   ROWS=2000000 TENANTS=500 node templates/seed-node.mjs > /tmp/seed.sql
//
// Emits plain SQL so it works with psql, pgAdmin, or any Postgres client.
// Adjust the table shape to the project's schema before using it.

const ROWS = Number(process.env.ROWS || 1_000_000)
const USERS = Number(process.env.USERS || 50_000)
const TENANTS = Number(process.env.TENANTS || 500)
const SEED = Number(process.env.SEED || 42)

function mulberry32(seed) {
  return function next() {
    seed |= 0
    seed = (seed + 0x6d2b79f5) | 0
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const rand = mulberry32(SEED)
const STATUS = ['active', 'active', 'active', 'active', 'active', 'active', 'active', 'draft', 'draft', 'archived']
const baseTime = Date.UTC(2023, 0, 1)
const out = []

out.push('BEGIN;')
out.push('TRUNCATE perf_items, perf_users RESTART IDENTITY;')

out.push('INSERT INTO perf_users (id, email, tenant_id, created_at) VALUES')
const userRows = []
for (let i = 1; i <= USERS; i += 1) {
  const tenant = (i % TENANTS) + 1
  const created = new Date(baseTime + Math.floor(rand() * 94_608_000_000)).toISOString()
  userRows.push(`(${i},'user${i}@perf.local',${tenant},'${created}')`)
}
for (let i = 0; i < userRows.length; i += 1000) {
  out.push(userRows.slice(i, i + 1000).join(',') + ';')
  if (i + 1000 < userRows.length) out.push('INSERT INTO perf_users (id, email, tenant_id, created_at) VALUES')
}

out.push('INSERT INTO perf_items (id, user_id, tenant_id, title, status, price_cents, created_at) VALUES')
const items = []
const monthAgo = Date.UTC(2026, 9, 17)
for (let i = 1; i <= ROWS; i += 1) {
  const userId = (i % USERS) + 1
  const tenant = (i % TENANTS) + 1
  const status = STATUS[i % STATUS.length]
  const price = (i * 7919) % 100_000
  const created = new Date(monthAgo + Math.floor(rand() * 2_592_000_000)).toISOString()
  items.push(`(${i},${userId},${tenant},'item-${i}', '${status}',${price},'${created}')`)
  if (items.length >= 1000) {
    out.push(items.join(',') + ';')
    items.length = 0
    if (i < ROWS) out.push('INSERT INTO perf_items (id, user_id, tenant_id, title, status, price_cents, created_at) VALUES')
  }
}
if (items.length > 0) out.push(items.join(',') + ';')

out.push('CREATE INDEX IF NOT EXISTS perf_items_user_created_idx ON perf_items (user_id, created_at DESC);')
out.push('CREATE INDEX IF NOT EXISTS perf_items_tenant_status_idx ON perf_items (tenant_id, status);')
out.push('ANALYZE perf_users;')
out.push('ANALYZE perf_items;')
out.push('COMMIT;')

process.stdout.write(out.join('\n') + '\n')
