"""Resolve the deployment listener URL and render its QR code locally."""

from __future__ import annotations

import ipaddress
import re
from io import BytesIO
from typing import Optional
from urllib.parse import SplitResult, urlsplit, urlunsplit

import qrcode
from qrcode.image.svg import SvgPathImage

from voxbridge.tts.lan_address import LANAddressUnavailable, detect_lan_ipv4


_MAX_LISTENER_URL_LENGTH = 2048
_HOSTNAME_PATTERN = re.compile(r"^[A-Za-z0-9.-]+$")
_LOCAL_IPV4_NETWORKS = tuple(
    ipaddress.ip_network(network)
    for network in (
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
    )
)


def _parse_listener_url(value: str) -> SplitResult:
    candidate = str(value or "").strip()
    if not candidate or len(candidate) > _MAX_LISTENER_URL_LENGTH:
        raise ValueError("listener URL must be a non-empty absolute URL")

    parsed = urlsplit(candidate)
    if parsed.scheme.lower() not in {"http", "https"}:
        raise ValueError("listener URL scheme must be http or https")
    if not parsed.netloc or parsed.hostname is None:
        raise ValueError("listener URL must include a host")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("listener URL must not contain credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("listener URL must not contain a query or fragment")
    try:
        parsed.port
    except ValueError as exc:
        raise ValueError("listener URL contains an invalid port") from exc

    hostname = parsed.hostname
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        if not _HOSTNAME_PATTERN.fullmatch(hostname):
            raise ValueError("listener URL contains an invalid host")
        labels = hostname.rstrip(".").split(".")
        if any(not label or label.startswith("-") or label.endswith("-") for label in labels):
            raise ValueError("listener URL contains an invalid host")

    return parsed


def _canonical_listener_url(parsed: SplitResult) -> str:
    path = parsed.path.rstrip("/")
    if path not in {"", "/listen"}:
        raise ValueError("listener URL path must be /listen")
    return urlunsplit((parsed.scheme.lower(), parsed.netloc, "/listen", "", ""))


def _is_local_http_host(hostname: str) -> bool:
    host = hostname.rstrip(".").lower()
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return host == "localhost" or host.endswith(".local") or "." not in host
    if isinstance(address, ipaddress.IPv4Address):
        return any(address in network for network in _LOCAL_IPV4_NETWORKS)
    return address.is_loopback or address.is_link_local or address.is_private


def validate_listener_url(value: str) -> str:
    """Validate and canonicalize an explicit HTTPS or local-network URL."""

    parsed = _parse_listener_url(value)
    if parsed.scheme.lower() == "http" and not _is_local_http_host(parsed.hostname or ""):
        raise ValueError("http listener URLs must use a local-network host")
    return _canonical_listener_url(parsed)


def validate_listener_config(value: str) -> str:
    return 'auto' if value == 'auto' else validate_listener_url(value)


def listener_url_for_request(request_url: str, configured_url: Optional[str] = None,
                             *, auto_port: int = 8024) -> str:
    """Resolve an explicit URL, current Mac LAN address, or request origin."""

    if configured_url == 'auto':
        return f'http://{detect_lan_ipv4()}:{int(auto_port)}/listen'
    if configured_url:
        return validate_listener_url(configured_url)
    request = urlsplit(str(request_url or ""))
    parsed = _parse_listener_url(
        urlunsplit((request.scheme, request.netloc, "", "", ""))
    )
    return urlunsplit((parsed.scheme.lower(), parsed.netloc, "/listen", "", ""))


def render_listener_qr_svg(listener_url: str) -> str:
    """Render a script-free SVG QR locally for an already resolved listener URL."""

    parsed = _parse_listener_url(listener_url)
    canonical_url = _canonical_listener_url(parsed)
    qr = qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=1,
        border=2,
    )
    qr.add_data(canonical_url)
    qr.make(fit=True)
    output = BytesIO()
    qr.make_image(image_factory=SvgPathImage).save(output)
    return output.getvalue().decode("utf-8")


__all__ = [
    "LANAddressUnavailable",
    "listener_url_for_request",
    "render_listener_qr_svg",
    "validate_listener_config",
    "validate_listener_url",
]
