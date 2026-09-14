# macOS local listener URL and QR report

## Result

The main-page listener link and `/listen/qr.svg` now use `/listen` on the
current request origin by default. An operator can set one explicit URL with
`--public-listener-url`; the same canonical value drives both the HTML link and
the locally generated SVG QR.

Explicit URLs accept HTTPS, or HTTP on loopback, RFC1918/link-local addresses,
single-label LAN names, and `.local` names. The validator rejects other
schemes, public plain HTTP, credentials, queries, fragments, invalid hosts or
ports, and paths other than `/listen`. Empty paths and a trailing slash are
canonicalized to `/listen`.

QR generation uses the installed, pinned `qrcode==8.2` package and its SVG path
renderer. It performs no HTTP request and embeds no script or external asset.
The response remains cacheable and includes `Vary: Host` because the default QR
depends on the request origin.

The existing `/listen` page, English PCCS presentation, HLS/Auto/FIFO behavior,
vendored hls.js asset, listener leases, and public listener endpoints were not
changed.

## Changed files

- `voxbridge/tts/public_listener.py`
- `voxbridge/cli/demo_streaming_ws.py` (listener imports, page rendering, QR
  route, and `--public-listener-url` only)
- `tests/test_public_listener.py`
- `tests/test_demo_streaming_ws_protocol.py`
- `tests/test_demo_streaming_ws_utils.py`
- `tests/test_release_docs.py`
- `README.md`
- `docs/API.md`
- `docs/DEPLOYMENT.md`
- `docs/SECURITY_SCAN.md`
- `CHANGELOG.md`
- `docs/macos-listener-report.md`

`pyproject.toml` and `deploy/macos/requirements.lock` declare `qrcode==8.2` as
part of the coordinated macOS runtime work; those files were changed by the
runtime task, not by this listener task.

## Test evidence

Tests were written before the listener implementation. The first collection
run failed because the new resolver API did not exist. After changing the test
import so pytest could collect all cases, the red run reported 16 intended
failures for the missing resolver/validator/renderer and unchanged fixed page
and QR behavior:

```text
../.venv/bin/python -m pytest tests/test_public_listener.py tests/test_demo_streaming_ws_utils.py::test_index_template_displays_public_listener_qr_in_control_bar tests/test_demo_streaming_ws_protocol.py::test_main_page_and_qr_default_to_the_current_local_origin tests/test_demo_streaming_ws_protocol.py::test_explicit_listener_url_drives_both_main_link_and_qr -q
16 failed, 1 warning
```

After implementation, the same focused behavior passed:

```text
../.venv/bin/python -m pytest tests/test_public_listener.py tests/test_demo_streaming_ws_utils.py::test_index_template_displays_public_listener_qr_in_control_bar tests/test_demo_streaming_ws_protocol.py::test_main_page_and_qr_default_to_the_current_local_origin tests/test_demo_streaming_ws_protocol.py::test_explicit_listener_url_drives_both_main_link_and_qr -q
16 passed, 1 warning
```

The macOS launcher had already selected the final option name. Tests were
changed first to require `--public-listener-url`; that red run reported two
expected failures, followed by a 17-case green run covering the final CLI and
endpoint contract:

```text
../.venv/bin/python -m pytest tests/test_demo_streaming_ws_utils.py::test_parse_args_accepts_and_canonicalizes_listener_url tests/test_demo_streaming_ws_protocol.py::test_explicit_listener_url_drives_both_main_link_and_qr -q
2 failed, 1 warning

../.venv/bin/python -m pytest tests/test_public_listener.py tests/test_demo_streaming_ws_utils.py::test_parse_args_accepts_and_canonicalizes_listener_url tests/test_demo_streaming_ws_utils.py::test_parse_args_rejects_public_plain_http_listener_url tests/test_demo_streaming_ws_protocol.py::test_main_page_and_qr_default_to_the_current_local_origin tests/test_demo_streaming_ws_protocol.py::test_explicit_listener_url_drives_both_main_link_and_qr -q
17 passed, 1 warning
```

Utility and documentation regression tests passed:

```text
../.venv/bin/python -m pytest tests/test_public_listener.py tests/test_release_docs.py tests/test_demo_streaming_ws_utils.py -q
243 passed
```

The first complete protocol-suite run exercised every existing
listener/auth/HLS/FIFO test. It reported 173 passes and one unrelated
debug-file failure:

```text
../.venv/bin/python -m pytest tests/test_demo_streaming_ws_protocol.py -q
1 failed, 173 passed, 1 warning
```

The failure was
`test_debug_file_requires_auth_and_can_be_disabled`: the authenticated request
for pytest's macOS `/private/var/...` temporary file receives HTTP 403 instead
of the test's expected 200. The listener and QR tests passed in that run. The
coordinated runtime task subsequently added the resolved macOS temporary root;
the exact debug-file test then passed:

```text
../.venv/bin/python -m pytest tests/test_demo_streaming_ws_protocol.py::test_debug_file_requires_auth_and_can_be_disabled -q
1 passed, 1 warning
```

Fresh combined listener, utility, documentation, and protocol verification
passed with only that now separately verified test deselected:

```text
../.venv/bin/python -m pytest tests/test_public_listener.py tests/test_release_docs.py tests/test_demo_streaming_ws_utils.py tests/test_demo_streaming_ws_protocol.py -k 'not test_debug_file_requires_auth_and_can_be_disabled' -q
416 passed, 1 deselected, 1 warning
```

Both changed Python modules compile successfully, and `git diff --check`
reports no whitespace errors:

```text
../.venv/bin/python -m py_compile voxbridge/tts/public_listener.py voxbridge/cli/demo_streaming_ws.py
git diff --check
```

No browser automation or real model inference was used.

## Fixed outbound URL audit

The runtime constants `PUBLIC_LISTENER_URL` and `PUBLIC_LISTENER_QR_SVG` were
removed. Searching for the former remote hostname, port/path, constants, and
`outboundURL` spellings finds no functional outbound listener URL. Remaining
matches are only the `__PUBLIC_LISTENER_URL__` server-side HTML placeholder and
tests for that placeholder, plus the documentation test that asserts the old
hostname is absent.

The listener QR has no network dependency. Functional translated audio still
depends on the existing local FastAPI service, Kokoro/misaki assets, FFmpeg,
the vendored hls.js fallback, and a reachable bind address. The macOS service
defaults to `127.0.0.1:8024`; a phone requires an explicitly configured LAN bind
and `VOXBRIDGE_LISTENER_URL`, or an operator-provided HTTPS endpoint. Phone and
iPhone playback were not exercised by this protocol-only task.
