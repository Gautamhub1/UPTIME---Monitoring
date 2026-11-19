"""Serverless uptime monitor - Lambda entry point.

One Lambda function (packaged as a Docker image) handles two kinds of events:

1. EventBridge schedule (every 5 minutes)
   -> checks every URL in TARGET_URLS
   -> saves each result to DynamoDB (kept for 7 days via TTL)
   -> publishes CloudWatch metrics (Up, LatencyMs, SitesDown) used by alarms

2. HTTP API (API Gateway)
   GET /                       -> HTML dashboard
   GET /api/status             -> JSON summary of the last 24 hours per site
   GET /api/check?url=<url>    -> check any public URL right now
   GET /health                 -> {"status": "ok", "version": "<git sha>"}
"""

from __future__ import annotations

import json
import logging
import os
import time
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path

import boto3
from boto3.dynamodb.conditions import Key

from checker import check_url

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

TABLE_NAME = os.environ.get("TABLE_NAME", "uptime-monitor-checks")
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "UptimeMonitor")
APP_VERSION = os.environ.get("APP_VERSION", "dev")
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "7"))

DASHBOARD_HTML = (Path(__file__).parent / "static" / "dashboard.html").read_text(encoding="utf-8")

# AWS clients are created once and reused while the Lambda container stays warm.
_clients: dict = {}


def _cloudwatch():
    if "cloudwatch" not in _clients:
        _clients["cloudwatch"] = boto3.client("cloudwatch")
    return _clients["cloudwatch"]


def _table():
    if "table" not in _clients:
        _clients["table"] = boto3.resource("dynamodb").Table(TABLE_NAME)
    return _clients["table"]


def target_urls() -> list[str]:
    return [u.strip() for u in os.environ.get("TARGET_URLS", "").split(",") if u.strip()]


# ---------------------------------------------------------------------------
# Scheduled checks
# ---------------------------------------------------------------------------
def save_results(results: list[dict], now: datetime) -> None:
    expires_at = int((now + timedelta(days=RETENTION_DAYS)).timestamp())
    with _table().batch_writer() as batch:
        for r in results:
            item = {
                "url": r["url"],
                "checked_at": now.isoformat(timespec="seconds"),
                "up": r["up"],
                "latency_ms": Decimal(str(r["latency_ms"])),
                "expires_at": expires_at,  # DynamoDB TTL deletes the item automatically
            }
            if r.get("status_code") is not None:
                item["status_code"] = r["status_code"]
            if r.get("error"):
                item["error"] = r["error"][:500]
            batch.put_item(Item=item)


def publish_metrics(results: list[dict]) -> None:
    metric_data = []
    for r in results:
        dimensions = [{"Name": "Url", "Value": r["url"]}]
        metric_data.append(
            {"MetricName": "Up", "Dimensions": dimensions,
             "Value": 1.0 if r["up"] else 0.0, "Unit": "Count"}
        )
        metric_data.append(
            {"MetricName": "LatencyMs", "Dimensions": dimensions,
             "Value": r["latency_ms"], "Unit": "Milliseconds"}
        )
    metric_data.append(
        {"MetricName": "SitesDown",
         "Value": float(sum(1 for r in results if not r["up"])), "Unit": "Count"}
    )
    _cloudwatch().put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=metric_data)


def run_scheduled_checks() -> dict:
    now = datetime.now(UTC)
    results = []
    for url in target_urls():
        try:
            results.append(check_url(url))
        except ValueError as exc:  # a bad entry in TARGET_URLS counts as "down"
            results.append(
                {"url": url, "up": False, "status_code": None, "latency_ms": 0.0, "error": str(exc)}
            )

    if results:
        save_results(results, now)
        publish_metrics(results)

    summary = {"checked": len(results), "down": [r["url"] for r in results if not r["up"]]}
    logger.info(json.dumps({"event": "scheduled_check", **summary, "results": results}))
    return summary


# ---------------------------------------------------------------------------
# Status API
# ---------------------------------------------------------------------------
def site_summary(url: str, now: datetime) -> dict:
    """Summarise the last 24 hours of checks for one URL (newest first)."""
    since = (now - timedelta(hours=24)).isoformat(timespec="seconds")
    response = _table().query(
        KeyConditionExpression=Key("url").eq(url) & Key("checked_at").gte(since),
        ScanIndexForward=False,
        Limit=300,  # 24h at one check every 5 minutes = 288 items
    )
    items = response.get("Items", [])
    if not items:
        return {"url": url, "checks_24h": 0, "uptime_24h": None, "latest": None, "history": []}

    up_count = sum(1 for i in items if i["up"])
    latencies = [float(i["latency_ms"]) for i in items if i["up"]]
    latest = items[0]
    return {
        "url": url,
        "checks_24h": len(items),
        "uptime_24h": round(100 * up_count / len(items), 2),
        "avg_latency_ms": round(sum(latencies) / len(latencies), 1) if latencies else None,
        "latest": {
            "checked_at": latest["checked_at"],
            "up": latest["up"],
            "status_code": int(latest["status_code"]) if "status_code" in latest else None,
            "latency_ms": float(latest["latency_ms"]),
            "error": latest.get("error"),
        },
        # Oldest -> newest, for the small chart on the dashboard.
        "history": [
            {"t": i["checked_at"], "up": i["up"], "ms": float(i["latency_ms"])}
            for i in reversed(items)
        ],
    }


def status_report() -> dict:
    now = datetime.now(UTC)
    return {
        "generated_at": now.isoformat(timespec="seconds"),
        "version": APP_VERSION,
        "sites": [site_summary(url, now) for url in target_urls()],
    }


# ---------------------------------------------------------------------------
# HTTP routing
# ---------------------------------------------------------------------------
def _json(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body),
    }


def _html(body: str) -> dict:
    return {
        "statusCode": 200,
        "headers": {
            "Content-Type": "text/html; charset=utf-8",
            "Content-Security-Policy": (
                "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'"
            ),
        },
        "body": body,
    }


def handle_http(event: dict) -> dict:
    path = event.get("rawPath", "/")
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")

    if method != "GET":
        return _json(405, {"error": "Method not allowed"})

    if path == "/":
        return _html(DASHBOARD_HTML)

    if path == "/health":
        return _json(200, {"status": "ok", "version": APP_VERSION})

    if path == "/api/status":
        return _json(200, status_report())

    if path == "/api/check":
        url = (event.get("queryStringParameters") or {}).get("url")
        if not url:
            return _json(400, {"error": "Missing 'url' query parameter"})
        try:
            return _json(200, check_url(url))
        except ValueError as exc:
            return _json(400, {"error": str(exc)})

    return _json(404, {"error": "Not found", "routes": ["/", "/health", "/api/status",
                                                        "/api/check?url=..."]})


def lambda_handler(event: dict, context) -> dict:
    start = time.perf_counter()
    if event.get("source") == "aws.events":  # EventBridge scheduled rule
        result = run_scheduled_checks()
    else:
        result = handle_http(event)
    logger.debug("handled in %.1f ms", (time.perf_counter() - start) * 1000)
    return result
