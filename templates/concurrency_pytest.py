"""In-process concurrency test for a Python layer (repo, pool, cache, consumer).

Run: pytest tests/perf -m perf -q
"""

import asyncio
import os
import time

import pytest

pytestmark = pytest.mark.perf

CALLS = int(os.getenv("PERF_CALLS", "200"))
CONCURRENCY = int(os.getenv("PERF_CONCURRENCY", "50"))
SLO_P95_S = float(os.getenv("SLO_P95_MS", "50")) / 1000
MAX_RSS_GROWTH_MB = float(os.getenv("MAX_RSS_GROWTH_MB", "50"))


@pytest.mark.asyncio
async def test_repository_concurrency(repo):
    """Replace `repo` with a fixture that builds the real dependency."""
    latency: list[float] = []
    errors: list[Exception] = []
    slow_calls: list[float] = []
    semaphore = asyncio.Semaphore(CONCURRENCY)
    loop = asyncio.get_running_loop()

    try:
        import psutil

        rss_before = psutil.Process().memory_info().rss
    except ImportError:  # psutil is optional
        rss_before = None

    async def one(item_id: int) -> None:
        async with semaphore:
            started = time.perf_counter()
            try:
                await repo.find_with_items(item_id)
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)
            finally:
                latency.append(time.perf_counter() - started)
                # Record blocking calls when PYTHONASYNCIODEBUG=1 is set.
                if loop.slow_callback_duration and (time.perf_counter() - started) > loop.slow_callback_duration:
                    slow_calls.append(time.perf_counter() - started)

    await asyncio.gather(*(one(i) for i in range(CALLS)))

    latency.sort()
    p95 = latency[min(len(latency) - 1, int(len(latency) * 0.95))]

    assert not errors, f"{len(errors)} errors, first: {errors[0]!r}"
    assert len(latency) == CALLS
    assert p95 <= SLO_P95_S, f"p95 {p95 * 1000:.1f}ms exceeds {SLO_P95_S * 1000:.0f}ms"

    if rss_before is not None:
        import psutil

        growth_mb = (psutil.Process().memory_info().rss - rss_before) / 1024 / 1024
        assert growth_mb < MAX_RSS_GROWTH_MB, f"RSS grew {growth_mb:.1f}MB, suspected leak"

    # Slow calls reveal blocking work hidden inside async code.
    assert not slow_calls, f"{len(slow_calls)} calls exceeded slow_callback_duration"


@pytest.mark.perf
def test_pool_saturation(pool):
    """Assert the pool queues instead of failing, and recovers."""
    import concurrent.futures

    def hold(_: int):
        with pool.connection() as conn:  # adapter-specific
            conn.execute("SELECT 1")
            time.sleep(0.01)

    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as ex:
        list(ex.map(hold, range(CALLS)))
    elapsed = time.perf_counter() - started

    assert elapsed < 30, "pool queue did not drain, suspected leak or timeout"
