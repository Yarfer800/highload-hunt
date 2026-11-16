//go:build perf

// In-process concurrency test for a Go layer. Build tag keeps normal CI fast.
//
// Run: go test -tags perf ./tests/perf -run TestRepositoryConcurrency -v -race -timeout 15m
package perf

import (
	"context"
	"runtime"
	"sort"
	"sync"
	"testing"
	"time"
)

const (
	calls       = 200
	concurrency = 50
	sloP95      = 50 * time.Millisecond
)

type repo interface {
	FindWithItems(ctx context.Context, id int) (any, error)
}

func TestRepositoryConcurrency(t *testing.T) {
	var r repo // set to the real implementation
	if r == nil {
		t.Skip("wire the repository under test")
	}

	var (
		wg        sync.WaitGroup
		mu        sync.Mutex
		latencies = make([]time.Duration, 0, calls)
		errs      []error
	)

	for w := 0; w < concurrency; w++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for i := worker; i < calls; i += concurrency {
				start := time.Now()
				if _, err := r.FindWithItems(context.Background(), i); err != nil {
					mu.Lock()
					errs = append(errs, err)
					mu.Unlock()
				}
				mu.Lock()
				latencies = append(latencies, time.Since(start))
				mu.Unlock()
			}
		}(w)
	}
	wg.Wait()

	if len(errs) > 0 {
		t.Fatalf("%d errors, first: %v", len(errs), errs[0])
	}
	if len(latencies) != calls {
		t.Fatalf("expected %d samples, got %d", calls, len(latencies))
	}

	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	p95 := latencies[int(float64(len(latencies))*0.95)]
	if p95 > sloP95 {
		t.Fatalf("p95 %v exceeds %v (n=%d)", p95, sloP95, len(latencies))
	}
}

// Leak guard: run with -race, then inspect the goroutine delta.
func TestGoroutineLeak(t *testing.T) {
	before := runtime.NumGoroutine()
	TestRepositoryConcurrency(t)
	time.Sleep(100 * time.Millisecond)
	after := runtime.NumGoroutine()
	if after-before > 5 {
		t.Fatalf("goroutine leak: %d -> %d", before, after)
	}
}

// Benchmark variant for allocation and throughput tracking.
func BenchmarkRepository(b *testing.B) {
	var r repo
	if r == nil {
		b.Skip("wire the repository under test")
	}
	b.ReportAllocs()
	b.RunParallel(func(pb *testing.PB) {
		i := 0
		for pb.Next() {
			i++
			if _, err := r.FindWithItems(context.Background(), i%calls); err != nil {
				b.Fatal(err)
			}
		}
	})
}
