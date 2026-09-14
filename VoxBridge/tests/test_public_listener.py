import re
import xml.etree.ElementTree as ET

import pytest

from voxbridge.tts import public_listener


def test_listener_url_defaults_to_the_current_request_origin():
    assert (
        public_listener.listener_url_for_request("http://127.0.0.1:8024/operator?view=main")
        == "http://127.0.0.1:8024/listen"
    )


def test_auto_listener_uses_detected_lan_even_from_loopback(monkeypatch):
    monkeypatch.setattr(public_listener, 'detect_lan_ipv4', lambda: '192.168.1.253')
    assert public_listener.listener_url_for_request('http://127.0.0.1:8024/', 'auto') == 'http://192.168.1.253:8024/listen'


@pytest.mark.parametrize(
    "configured,expected",
    [
        ("https://listen.church.example", "https://listen.church.example/listen"),
        ("https://listen.church.example/listen/", "https://listen.church.example/listen"),
        ("http://192.168.1.24:8024/listen", "http://192.168.1.24:8024/listen"),
        ("http://voxbridge.local:8024", "http://voxbridge.local:8024/listen"),
    ],
)
def test_listener_url_accepts_https_and_lan_overrides(configured, expected):
    assert public_listener.validate_listener_url(configured) == expected
    assert public_listener.listener_url_for_request(
        "http://127.0.0.1:8024/", configured
    ) == expected


@pytest.mark.parametrize(
    "configured",
    [
        "javascript:alert(1)",
        "file:///tmp/listen",
        "ftp://192.168.1.24/listen",
        "http://example.com/listen",
        "https://user:secret@example.com/listen",
        "https://example.com/listen?token=secret",
        "https://example.com/other",
    ],
)
def test_listener_url_rejects_unsafe_or_non_listener_overrides(configured):
    with pytest.raises(ValueError):
        public_listener.validate_listener_url(configured)


def test_generated_qr_is_xml_safe_local_svg_without_external_content():
    first = public_listener.render_listener_qr_svg(
        "https://listen.church.example/listen"
    )
    second = public_listener.render_listener_qr_svg(
        "https://other.church.example/listen"
    )

    root = ET.fromstring(first)
    assert root.tag == "{http://www.w3.org/2000/svg}svg"
    assert first != second
    assert "<script" not in first.lower()
    assert re.search(r'(?:href|src)=["\']https?://', first, re.I) is None
