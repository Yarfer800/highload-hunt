import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { monitorEventLoopDelay, performance } from 'node:perf_hooks'

/**
 * In-process concurrency test. Answers layer questions, not HTTP throughput.
 *
 * Replace `repo.findWithItems` and the threshold with the real target.
 * Run: npx vitest run templates/concurrency-node.test.ts
 */

const CALLS = Number(process.env.PERF_CALLS || 200)
const CONCURRENCY = Number(process.env.PERF_CONCURRENCY || 50)
const SLO_P95_MS = Number(process.env.SLO_P95 || 50)
const MAX_RSS_GROWTH_MB = Number(process.env.MAX_RSS_GROWTH_MB || 50)

// Replace with the real dependency under test.
const repo = {
  async findWithItems(id: number): Promise<unknown> {
    return { id, items: [] }
  },
}

function pct(sorted: number[], p: number): number {
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))]
}

describe('perf: repository under concurrency', () => {
  const lag = monitorEventLoopDelay({ resolution: 10 })

  beforeAll(() => {
    lag.enable()
  })

  afterAll(() => {
    lag.disable()
  })

  it(`keeps p95 <= ${SLO_P95_MS}ms at ${CONCURRENCY} concurrent callers`, async () => {
    const latencies: number[] = []
    const errors: unknown[] = []
    const rssBefore = process.memoryUsage().rss
    let cursor = 0

    async function worker() {
      while (true) {
        const id = ++cursor
        if (id > CALLS) return
        const started = performance.now()
        try {
          await repo.findWithItems(id)
        } catch (err) {
          errors.push(err)
        } finally {
          latencies.push(performance.now() - started)
        }
      }
    }

    await Promise.all(Array.from({ length: CONCURRENCY }, () => worker()))

    const rssGrowthMb = (process.memoryUsage().rss - rssBefore) / 1024 / 1024
    const sorted = [...latencies].sort((a, b) => a - b)
    const p95 = pct(sorted, 0.95)
    const eventLoopP99Ms = lag.percentile(99) / 1e6

    expect(errors, `errors: ${errors.slice(0, 3).map(String).join(' | ')}`).toHaveLength(0)
    expect(latencies.length).toBe(CALLS)
    expect(p95).toBeLessThanOrEqual(SLO_P95_MS)
    expect(eventLoopP99Ms, 'event loop blocked by a sync call').toBeLessThan(50)
    expect(rssGrowthMb, 'memory growth suggests a leak').toBeLessThan(MAX_RSS_GROWTH_MB)
  }, 120_000)
})
