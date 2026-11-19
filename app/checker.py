"""HTTP checking logic - no AWS code here, so it is easy to test on its own."""

from __future__ import annotations

import ipaddress
import os
import socket
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

TIMEOUT_SECONDS = float(os.environ.get("CHECK_TIMEOUT_SECONDS", "5"))
USER_AGENT = f"aws-uptime-monitor/{os.environ.get('APP_VERSION', 'dev')}"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Report 3xx responses as-is instead of following them.

    Following redirects blindly would let a public URL bounce the request to a
    private address, bypassing the check in validate_url().
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def validate_url(url: str) -> None:
    """Allow only http(s) URLs that resolve to public IP addresses.

    This blocks Server-Side Request Forgery (SSRF): without it, anyone could use
    /api/check to make our Lambda call internal or private addresses.
    """
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("URL must start with http:// or https:// and include a host")

    try:
        addresses = {info[4][0] for info in socket.getaddrinfo(parsed.hostname, None)}
    except socket.gaierror as exc:
        raise ValueError(f"Cannot resolve host '{parsed.hostname}'") from exc

    for address in addresses:
        if not ipaddress.ip_address(address).is_global:
            raise ValueError(f"Host '{parsed.hostname}' resolves to a non-public address")


def check_url(url: str, timeout: float = TIMEOUT_SECONDS) -> dict:
    """Request a URL once and report whether it is up, its status code and latency."""
    validate_url(url)

    status_code = None
    error = None
    start = time.perf_counter()
    try:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with _opener.open(request, timeout=timeout) as response:
            status_code = response.status
    except urllib.error.HTTPError as exc:  # 3xx/4xx/5xx still mean the server answered
        status_code = exc.code
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        error = str(getattr(exc, "reason", exc))
    latency_ms = round((time.perf_counter() - start) * 1000, 1)

    result = {
        "url": url,
        "up": status_code is not None and status_code < 400,
        "status_code": status_code,
        "latency_ms": latency_ms,
    }
    if error:
        result["error"] = error
    return result
