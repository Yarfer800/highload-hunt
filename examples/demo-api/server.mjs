// Demo target for highload-hunt. Zero dependencies, deterministic dataset,
// one intentional performance defect controlled by PERF_DEFECT.
//
//   node examples/demo-api/server.mjs                  # defect ON (O(n) scan)
//   PERF_DEFECT=off node examples/demo-api/server.mjs  # defect OFF (Map index)
//   PORT=8080 ITEMS=200000 node examples/demo-api/server.mjs
//
// Endpoints: /health, /api/items?id=N, /api/items?page=&limit=, /api/search?q=term

import http from 'node:http'
import { createDataset, findItem } from './data.mjs'

const PORT = Number(process.env.PORT || 8080)
const ITEMS = Number(process.env.ITEMS || 200_000)
const DEFECT = (process.env.PERF_DEFECT || 'on') !== 'off'

const dataset = createDataset(ITEMS, 42)

function send(res, status, body) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(payload),
  })
  res.end(payload)
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost')
  const path = url.pathname

  if (path === '/health') {
    send(res, 200, { ok: true, items: ITEMS, defect: DEFECT ? 'on' : 'off' })
    return
  }

  if (path === '/api/items') {
    if (url.searchParams.has('id')) {
      const id = Number(url.searchParams.get('id'))
      const item = findItem(dataset, id, { defect: DEFECT })
      if (!item) {
        send(res, 404, { error: 'not found' })
        return
      }
      // Correctness marker for load tests: the body must echo the requested id.
      send(res, 200, { ...item, requestedId: id })
      return
    }

    const limit = Math.min(Number(url.searchParams.get('limit') || 20), 100)
    const page = Math.max(Number(url.searchParams.get('page') || 1), 1)
    const start = (page - 1) * limit
    send(res, 200, { page, limit, total: dataset.items.length, items: dataset.items.slice(start, start + limit) })
    return
  }

  if (path === '/api/search') {
    const term = (url.searchParams.get('q') || '').toLowerCase()
    const matches = []
    for (const item of dataset.items) {
      if (matches.length >= 20) break
      if (item.tag.includes(term) || item.name.includes(term)) matches.push(item)
    }
    send(res, 200, { term, count: matches.length, items: matches })
    return
  }

  send(res, 404, { error: 'unknown route' })
})

server.listen(PORT, () => {
  process.stdout.write(`demo-api on :${PORT} items=${ITEMS} defect=${DEFECT ? 'on' : 'off'} seed=42\n`)
})

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    server.close(() => process.exit(0))
  })
}
