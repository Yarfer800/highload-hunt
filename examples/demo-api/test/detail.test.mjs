// Regression test for the demo-api defect.
// Fails on the pre-fix code path (O(n) scan), passes on the Map index.
//
//   node --test examples/demo-api/test/
//   SLO_P95_MS=5 node --test examples/demo-api/test/

import test from 'node:test'
import assert from 'node:assert/strict'
import { createDataset, findItem } from '../data.mjs'

const ITEMS = Number(process.env.ITEMS || 200_000)
const SLO_P95_MS = Number(process.env.SLO_P95_MS || 5)
const CALLS = 200
const CONCURRENCY = 50

const dataset = createDataset(ITEMS, 42)

function p95(values) {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))]
}

test('indexed lookup returns the right item', () => {
  for (const id of [1, 2, 500, 12_345, ITEMS]) {
    const item = findItem(dataset, id)
    assert.ok(item, `id ${id} missing`)
    assert.equal(item.id, id)
  }
  assert.equal(findItem(dataset, ITEMS + 1), null)
})

test(`p95 lookup <= ${SLO_P95_MS}ms over ${CALLS} calls`, () => {
  const latencies = []
  for (let i = 0; i < CALLS; i += 1) {
    const id = 1 + ((i * 7919) % ITEMS)
    const started = performance.now()
    const item = findItem(dataset, id)
    latencies.push(performance.now() - started)
    assert.equal(item.id, id)
  }
  const value = p95(latencies)
  assert.ok(value <= SLO_P95_MS, `p95 ${value.toFixed(2)}ms exceeds ${SLO_P95_MS}ms: O(n) scan is back`)
})

test('lookup stays bounded under concurrency', async () => {
  const latencies = []
  const errors = []

  async function worker(offset) {
    for (let i = offset; i < CALLS; i += CONCURRENCY) {
      const id = 1 + ((i * 104_729) % ITEMS)
      const started = performance.now()
      try {
        const item = findItem(dataset, id)
        if (!item || item.id !== id) errors.push(new Error(`wrong item for ${id}`))
      } catch (error) {
        errors.push(error)
      }
      latencies.push(performance.now() - started)
    }
  }

  await Promise.all(Array.from({ length: CONCURRENCY }, (_, offset) => worker(offset)))

  assert.equal(errors.length, 0, errors.slice(0, 3).map(String).join(' | '))
  assert.equal(latencies.length, CALLS)
  const value = p95(latencies)
  assert.ok(value <= SLO_P95_MS * 4, `concurrent p95 ${value.toFixed(2)}ms exceeds ${SLO_P95_MS * 4}ms`)
})

test('lost index: the defect path is measurably slower', () => {
  // Guards the claim in PERF-REPORT.md: the defect is O(n), the fix is O(1).
  const defectSample = []
  for (let i = 0; i < 5; i += 1) {
    const started = performance.now()
    findItem(dataset, 1 + i * 1000, { defect: true })
    defectSample.push(performance.now() - started)
  }
  const fixedSample = []
  for (let i = 0; i < 5; i += 1) {
    const started = performance.now()
    findItem(dataset, 1 + i * 1000)
    fixedSample.push(performance.now() - started)
  }
  assert.ok(
    Math.min(...defectSample) > Math.min(...fixedSample) * 10,
    `defect ${defectSample.map((v) => v.toFixed(2))} vs fixed ${fixedSample.map((v) => v.toFixed(2))}`,
  )
})
