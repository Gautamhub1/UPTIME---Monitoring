import json
import urllib.error

import boto3

import checker
import handler


class FakeResponse:
    def __init__(self, status):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_event(path, query=None, method="GET"):
    return {
        "rawPath": path,
        "queryStringParameters": query,
        "requestContext": {"http": {"method": method}},
    }


def body(response):
    return json.loads(response["body"])


def fake_sites(monkeypatch):
    """up.example answers 200, down.example answers 500."""

    def open_url(req, timeout):
        if "down" in req.full_url:
            raise urllib.error.HTTPError(req.full_url, 500, "Error", {}, None)
        return FakeResponse(200)

    monkeypatch.setattr(checker._opener, "open", open_url)
    monkeypatch.setenv("TARGET_URLS", "https://up.example, https://down.example")


# --- HTTP routes --------------------------------------------------------------
def test_dashboard_is_served_as_html():
    response = handler.lambda_handler(http_event("/"), None)
    assert response["statusCode"] == 200
    assert response["headers"]["Content-Type"].startswith("text/html")
    assert "Uptime Monitor" in response["body"]


def test_health_returns_version(monkeypatch):
    monkeypatch.setattr(handler, "APP_VERSION", "abc1234")
    response = handler.lambda_handler(http_event("/health"), None)
    assert response["statusCode"] == 200
    assert body(response) == {"status": "ok", "version": "abc1234"}


def test_check_endpoint(monkeypatch):
    monkeypatch.setattr(checker._opener, "open", lambda req, timeout: FakeResponse(200))
    response = handler.lambda_handler(http_event("/api/check", {"url": "https://ok.example"}), None)
    assert response["statusCode"] == 200
    assert body(response)["up"] is True


def test_check_endpoint_requires_url():
    assert handler.lambda_handler(http_event("/api/check"), None)["statusCode"] == 400


def test_check_endpoint_rejects_bad_url():
    response = handler.lambda_handler(http_event("/api/check", {"url": "ftp://x"}), None)
    assert response["statusCode"] == 400


def test_unknown_path_and_method():
    assert handler.lambda_handler(http_event("/nope"), None)["statusCode"] == 404
    assert handler.lambda_handler(http_event("/health", method="POST"), None)["statusCode"] == 405


# --- Scheduled checks + status API (with mocked DynamoDB and CloudWatch) -----
def test_scheduled_run_saves_results_and_publishes_metrics(aws, monkeypatch):
    fake_sites(monkeypatch)
    sent_metrics = []
    monkeypatch.setattr(
        handler._cloudwatch(), "put_metric_data", lambda **kw: sent_metrics.append(kw)
    )

    summary = handler.lambda_handler({"source": "aws.events"}, None)

    assert summary == {"checked": 2, "down": ["https://down.example"]}

    items = boto3.resource("dynamodb").Table("uptime-monitor-checks").scan()["Items"]
    assert len(items) == 2
    assert all("expires_at" in item for item in items)

    metrics = sent_metrics[0]["MetricData"]
    sites_down = next(m for m in metrics if m["MetricName"] == "SitesDown")
    assert sites_down["Value"] == 1.0


def test_status_report_summarises_history(aws, monkeypatch):
    fake_sites(monkeypatch)
    monkeypatch.setattr(handler._cloudwatch(), "put_metric_data", lambda **kw: None)
    handler.lambda_handler({"source": "aws.events"}, None)

    response = handler.lambda_handler(http_event("/api/status"), None)
    data = body(response)
    sites = {s["url"]: s for s in data["sites"]}

    assert response["statusCode"] == 200
    assert sites["https://up.example"]["uptime_24h"] == 100.0
    assert sites["https://up.example"]["latest"]["status_code"] == 200
    assert sites["https://down.example"]["uptime_24h"] == 0.0
    assert sites["https://down.example"]["latest"]["up"] is False
    assert len(sites["https://up.example"]["history"]) == 1


def test_status_report_before_first_check(aws, monkeypatch):
    monkeypatch.setenv("TARGET_URLS", "https://new.example")
    data = body(handler.lambda_handler(http_event("/api/status"), None))
    assert data["sites"][0]["checks_24h"] == 0
    assert data["sites"][0]["latest"] is None


def test_scheduled_run_with_no_targets(aws, monkeypatch):
    monkeypatch.setenv("TARGET_URLS", "")
    assert handler.lambda_handler({"source": "aws.events"}, None) == {"checked": 0, "down": []}
