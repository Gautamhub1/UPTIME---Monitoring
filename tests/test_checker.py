import socket
import urllib.error

import pytest

import checker


class FakeResponse:
    def __init__(self, status):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def resolve_to(monkeypatch, ip):
    monkeypatch.setattr(
        checker.socket,
        "getaddrinfo",
        lambda host, port, *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0))],
    )


def test_site_up(monkeypatch):
    monkeypatch.setattr(checker._opener, "open", lambda req, timeout: FakeResponse(200))
    result = checker.check_url("https://example.com")
    assert result["up"] is True
    assert result["status_code"] == 200
    assert result["latency_ms"] >= 0


def test_redirect_counts_as_up(monkeypatch):
    def redirect(req, timeout):
        raise urllib.error.HTTPError(req.full_url, 301, "Moved", {}, None)

    monkeypatch.setattr(checker._opener, "open", redirect)
    result = checker.check_url("https://example.com")
    assert result["up"] is True
    assert result["status_code"] == 301


def test_server_error_counts_as_down(monkeypatch):
    def fail(req, timeout):
        raise urllib.error.HTTPError(req.full_url, 503, "Unavailable", {}, None)

    monkeypatch.setattr(checker._opener, "open", fail)
    result = checker.check_url("https://example.com")
    assert result["up"] is False
    assert result["status_code"] == 503


def test_network_error_counts_as_down(monkeypatch):
    def fail(req, timeout):
        raise urllib.error.URLError("timed out")

    monkeypatch.setattr(checker._opener, "open", fail)
    result = checker.check_url("https://example.com")
    assert result["up"] is False
    assert result["status_code"] is None
    assert result["error"] == "timed out"


@pytest.mark.parametrize("url", ["ftp://example.com", "example.com", "https://", ""])
def test_rejects_invalid_urls(url):
    with pytest.raises(ValueError):
        checker.check_url(url)


@pytest.mark.parametrize(
    "ip", ["10.0.0.5", "127.0.0.1", "169.254.169.254", "192.168.1.1", "::1"]
)
def test_blocks_private_addresses(monkeypatch, ip):
    resolve_to(monkeypatch, ip)
    with pytest.raises(ValueError, match="non-public"):
        checker.check_url("http://internal.test")


def test_unresolvable_host(monkeypatch):
    def fail(host, port, *a, **k):
        raise socket.gaierror("not found")

    monkeypatch.setattr(checker.socket, "getaddrinfo", fail)
    with pytest.raises(ValueError, match="Cannot resolve"):
        checker.check_url("https://does-not-exist.invalid")
