#!/usr/bin/env python3
"""normalize-result.py — turn any load-test output into one JSON schema.

Usage:
  scripts/normalize-result.py --input results/k6.json [--tool auto] [--level 100%]
  scripts/normalize-result.py --input ab.txt --tool ab --target-rps 300

Normalized schema (latencies in ms):
  tool, level, target_rps, rps, p50, p95, p99, max,
  error_rate (percent 0..100), samples, dropped, approx_p95, source

Supported: k6 --summary-export, locust --csv, autocannon -j, ab text,
vegeta report -type=json, ghz --format json, and flat JSON already normalized
(p95, p99, rps, error_rate, samples). Missing p95 in autocannon is approximated
from p97.5 and flagged with approx_p95=true.
"""

import argparse
import csv
import json
import re
import sys


def die(msg: str) -> None:
    print(f"normalize-result: {msg}", file=sys.stderr)
    sys.exit(2)


def detect(raw: str) -> str:
    text = raw.lstrip()
    if text.startswith("{") or text.startswith("["):
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return "unknown"
        if isinstance(data, dict):
            if "metrics" in data:
                return "k6"
            if "latencyDistribution" in data or "statusCodeDistribution" in data:
                return "ghz"
            if "latencies" in data and "requests" in data:
                return "vegeta"
            if "requests" in data and "latency" in data:
                return "autocannon"
            if "p95" in data or "p(95)" in data:
                return "flat"
        return "unknown"
    if "ApacheBench" in raw:
        return "ab"
    if "Request Count" in raw or "Type,Name,Request Count" in raw:
        return "locust"
    return "unknown"


def pick(obj, *keys, default=None):
    for key in keys:
        if isinstance(obj, dict) and key in obj:
            value = obj[key]
            if isinstance(value, (int, float)):
                return float(value)
    return default


def bucket(metrics: dict, name: str) -> dict:
    value = metrics.get(name)
    return value if isinstance(value, dict) else {}


def metric_values(metrics: dict, base: str, phase: str = "steady") -> dict:
    """Return a k6 metric with nested `values` merged, preferring the steady tag."""
    exact = metrics.get(base)
    tagged = None
    for key, value in metrics.items():
        if key.startswith(base + "{") and phase in key and isinstance(value, dict):
            tagged = value
            break
    chosen = tagged or exact
    if not isinstance(chosen, dict):
        return {}
    merged = {
        key: value
        for key, value in chosen.items()
        if isinstance(value, (int, float)) and not isinstance(value, bool)
    }
    values = chosen.get("values")
    if isinstance(values, dict):
        merged.update(
            {
                key: value
                for key, value in values.items()
                if isinstance(value, (int, float)) and not isinstance(value, bool)
            }
        )
    return merged


def from_k6(data: dict) -> dict:
    metrics = data.get("metrics") or {}
    dur = metric_values(metrics, "http_req_duration")
    fail = metric_values(metrics, "http_req_failed")
    reqs = metric_values(metrics, "http_reqs")
    steady_reqs = metric_values(metrics, "http_reqs")
    dropped = metric_values(metrics, "dropped_iterations")

    result = {
        "rps": pick(reqs, "rate", "value"),
        "p50": pick(dur, "p(50)", "med", "avg"),
        "p95": pick(dur, "p(95)"),
        "p99": pick(dur, "p(99)"),
        "max": pick(dur, "max"),
        "error_rate": (pick(fail, "rate", "value") or 0.0) * 100.0,
        "samples": int(pick(steady_reqs, "count", "value") or 0) or None,
        "dropped": int(pick(dropped, "count") or 0),
    }
    if result["p95"] is None and isinstance(data.get("metrics"), dict):
        # Tolerate flat summary-export lookalikes produced by other scripts.
        flat = {k: v for k, v in data.items() if isinstance(v, (int, float))}
        if flat:
            merged = from_flat(flat)
            for key, value in merged.items():
                if result.get(key) is None:
                    result[key] = value
    return result


def from_autocannon(data: dict) -> dict:
    latency = data.get("latency") or {}
    requests = data.get("requests") or {}
    total = pick(requests, "total", "sent") or 0
    bad = (pick(data, "non2xx") or 0) + (pick(data, "errors") or 0) + (pick(data, "timeouts") or 0)
    p95 = pick(latency, "p95", "p97_5")
    return {
        "rps": pick(requests, "average", "mean"),
        "p50": pick(latency, "p50", "median"),
        "p95": p95,
        "p99": pick(latency, "p99"),
        "max": pick(latency, "max"),
        "error_rate": (bad / total * 100.0) if total else 0.0,
        "samples": int(total) or None,
        "dropped": 0,
        "approx_p95": pick(latency, "p95") is None,
    }


def from_vegeta(data: dict) -> dict:
    latencies = data.get("latencies") or {}
    requests = pick(data, "requests") or 0
    success = pick(data, "success")
    status = data.get("status_codes") or {}
    errors = sum(v for k, v in status.items() if not str(k).startswith("2"))
    if success is None and requests:
        success = 1.0 - errors / requests

    def ms(value):
        return None if value is None else value / 1e6

    return {
        "rps": pick(data, "rate"),
        "p50": ms(pick(latencies, "50", "p50")),
        "p95": ms(pick(latencies, "95", "p95")),
        "p99": ms(pick(latencies, "99", "p99")),
        "max": ms(pick(latencies, "max")),
        "error_rate": (1.0 - success) * 100.0 if success is not None else 0.0,
        "samples": int(requests) or None,
        "dropped": 0,
    }


def from_ghz(data: dict) -> dict:
    dist = data.get("latencyDistribution") or []
    percentiles = {}
    for row in dist:
        if isinstance(row, dict):
            pct = row.get("percentage")
            lat = row.get("latency")
            if isinstance(pct, (int, float)) and isinstance(lat, (int, float)):
                percentiles[float(pct)] = lat / 1e6
    count = pick(data, "count") or 0
    errors = pick(data, "error") or 0
    for row in data.get("errorDistribution") or []:
        if isinstance(row, dict):
            errors += pick(row, "count") or 0
    return {
        "rps": pick(data, "rps"),
        "p50": percentiles.get(50),
        "p95": percentiles.get(95),
        "p99": percentiles.get(99),
        "max": max(percentiles.values()) if percentiles else None,
        "error_rate": (errors / count * 100.0) if count else 0.0,
        "samples": int(count) or None,
        "dropped": 0,
    }


def from_ab(raw: str) -> dict:
    lines = raw.splitlines()

    def num(pattern: str):
        for line in lines:
            match = re.search(pattern, line)
            if match:
                return float(match.group(1).replace(",", ""))
        return None

    total = num(r"Complete requests:\s+([\d,]+)")
    failed = num(r"Failed requests:\s+([\d,]+)") or 0
    non2xx = num(r"Non-2xx responses:\s+([\d,]+)") or 0
    percentiles = {}
    for line in lines:
        match = re.match(r"\s+(\d+)%\s+(\d+)", line)
        if match:
            percentiles[int(match.group(1))] = float(match.group(2))
    return {
        "rps": num(r"Requests per second:\s+([\d.]+)"),
        "p50": percentiles.get(50),
        "p95": percentiles.get(95),
        "p99": percentiles.get(99),
        "max": percentiles.get(100),
        "error_rate": ((failed + non2xx) / total * 100.0) if total else 0.0,
        "samples": int(total) if total else None,
        "dropped": 0,
    }


def from_locust_csv(raw: str) -> dict:
    reader = csv.DictReader(raw.splitlines())
    rows = list(reader)
    if not rows:
        die("empty locust csv")
    row = next((r for r in rows if (r.get("Name") or "").strip() == "Aggregated"), rows[-1])

    def cell(*names):
        for name in names:
            value = row.get(name)
            if value not in (None, "", "N/A"):
                try:
                    return float(value)
                except ValueError:
                    continue
        return None

    total = cell("Request Count") or 0
    failures = cell("Failure Count") or 0
    return {
        "rps": cell("Requests/s"),
        "p50": cell("50%", "Median Response Time"),
        "p95": cell("95%"),
        "p99": cell("99%"),
        "max": cell("100%", "Max Response Time"),
        "error_rate": (failures / total * 100.0) if total else 0.0,
        "samples": int(total) or None,
        "dropped": 0,
    }


def from_flat(data: dict) -> dict:
    err = pick(data, "error_rate_pct", "error_rate", "err", "errorRate") or 0.0
    # Flat files state units explicitly through the key name; bare error_rate is percent.
    return {
        "rps": pick(data, "rps", "requests_per_second", "throughput"),
        "p50": pick(data, "p50", "p(50)"),
        "p95": pick(data, "p95", "p(95)", "percentile95"),
        "p99": pick(data, "p99", "p(99)", "percentile99"),
        "max": pick(data, "max"),
        "error_rate": err,
        "samples": int(pick(data, "samples", "count") or 0) or None,
        "dropped": int(pick(data, "dropped", "dropped_iterations") or 0),
        "approx_p95": bool(data.get("approx_p95")),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--tool", default="auto")
    ap.add_argument("--level", default=None)
    ap.add_argument("--target-rps", type=float, default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    try:
        with open(args.input, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError as exc:
        die(f"cannot read {args.input}: {exc}")

    tool = args.tool
    if tool == "auto":
        tool = detect(raw)
    if tool == "unknown":
        die(f"cannot detect tool for {args.input} (pass --tool)")

    data = None
    if tool in {"k6", "autocannon", "vegeta", "ghz", "flat"}:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            die(f"{args.input} is not valid JSON: {exc}")

    parsers = {
        "k6": lambda: from_k6(data),
        "autocannon": lambda: from_autocannon(data),
        "vegeta": lambda: from_vegeta(data),
        "ghz": lambda: from_ghz(data),
        "flat": lambda: from_flat(data),
        "ab": lambda: from_ab(raw),
        "locust": lambda: from_locust_csv(raw),
    }
    if tool not in parsers:
        die(f"unsupported tool: {tool}")

    result = parsers[tool]()
    result.setdefault("approx_p95", False)
    # Re-normalizing an already normalized file must keep its provenance.
    source_meta = data if isinstance(data, dict) else {}
    level = args.level if args.level is not None else source_meta.get("level")
    target_rps = args.target_rps if args.target_rps is not None else source_meta.get("target_rps")
    tool_name = source_meta.get("tool") if tool == "flat" and source_meta.get("tool") else tool
    result.update(
        {
            "tool": tool_name,
            "level": level,
            "target_rps": target_rps,
            "source": args.input,
        }
    )
    for key in ("rps", "p50", "p95", "p99", "max", "error_rate", "samples", "dropped"):
        value = result.get(key)
        if isinstance(value, float):
            result[key] = round(value, 3)

    payload = json.dumps(result, indent=2, sort_keys=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(payload + "\n")
    else:
        print(payload)


if __name__ == "__main__":
    main()
