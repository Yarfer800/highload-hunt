// Deterministic dataset and lookup for the demo API.
// Split from server.mjs so tests can exercise the hot path without a socket.

export function mulberry32(seed) {
  return function next() {
    seed |= 0
    seed = (seed + 0x6d2b79f5) | 0
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

export const TAGS = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta']

export function createDataset(count = 200_000, seed = 42, tenants = 50) {
  const rand = mulberry32(seed)
  const items = new Array(count)
  for (let i = 0; i < count; i += 1) {
    items[i] = {
      id: i + 1,
      name: `item-${i + 1}`,
      tenant: Math.floor(rand() * tenants) + 1,
      tag: TAGS[Math.floor(rand() * TAGS.length)],
      price: Math.round(rand() * 100000) / 100,
      createdAt: 1_700_000_000_000 + Math.floor(rand() * 31_536_000_000),
    }
  }
  const index = new Map(items.map((item) => [item.id, item]))
  return { items, index, seed }
}

export function findItem(dataset, id, { defect = false } = {}) {
  if (!defect) return dataset.index.get(id) || null
  // Deliberate defect: full scan plus an unnecessary sort.
  const found = dataset.items.filter((item) => item.id === id)
  found.sort((a, b) => a.createdAt - b.createdAt)
  return found[0] || null
}
