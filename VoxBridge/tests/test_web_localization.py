from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

import pytest

from voxbridge.monitor import MONITOR_HTML
from voxbridge.tts.listener_page import TTS_LISTENER_HTML
from voxbridge.web.localization import WEB_CATALOG, embedded_localization


def test_web_catalog_is_complete_and_placeholders_match():
    assert set(WEB_CATALOG) == {"zh", "en", "ja", "fr", "es", "it", "pt", "hi"}
    english = WEB_CATALOG["en"]
    for locale, messages in WEB_CATALOG.items():
        assert set(messages) == set(english), locale
        for key, message in messages.items():
            assert isinstance(message, str) and message.strip(), (locale, key)
            assert set(re.findall(r"\{\w+\}", message)) == set(re.findall(r"\{\w+\}", english[key])), (locale, key)
    # Most copy must actually be translated, allowing cognates and unit formats.
    for locale, messages in WEB_CATALOG.items():
        if locale != "en":
            assert sum(message != english[key] for key, message in messages.items()) > len(english) * .8
    for page in (MONITOR_HTML, TTS_LISTENER_HTML):
        for key in re.findall(r'data-i18n(?:-aria|-alt)?="([^"]+)"', page):
            assert key in english
        assert "__LOCALIZATION__" not in page
        assert "__CATALOG__" not in page


def test_catalog_embedding_escapes_script_and_html_characters(monkeypatch):
    monkeypatch.setitem(WEB_CATALOG["en"], "test.escape", "</script><img src=x onerror=alert(1)>&\u2028\u2029")
    script = embedded_localization()
    assert script.count("</script>") == 1
    assert "<img" not in script
    assert r"\u003c/script\u003e" in script
    assert r"\u2028\u2029" in script


@pytest.fixture
def web_page():
    sync_api = pytest.importorskip("playwright.sync_api")
    chrome = shutil.which("google-chrome")
    mac_chrome = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if chrome is None and mac_chrome.is_file():
        chrome = str(mac_chrome)
    if chrome is None:
        pytest.skip("system Google Chrome is unavailable")
    with sync_api.sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=chrome, headless=True)
        page = browser.new_page()
        page.set_default_timeout(3000)
        yield page
        browser.close()


@pytest.mark.parametrize("preferences,saved,expected", [
    (["de-DE", "fr-CA", "en-US"], None, "fr"),
    (["ja-JP", "fr"], "es", "es"),
    (["de", "pt_BR"], "auto", "pt"),
    (["zh-Hant-TW"], None, "zh"),
    (["de", "ko"], None, "en"),
    (["hi-IN"], "unknown", "hi"),
    (["de", "ja-JP"], "", "ja"),
    (["fr"], "PT-br", "pt"),
])
def test_browser_locale_resolution_and_remembered_manual_choice(web_page, preferences, saved, expected):
    web_page.add_init_script(f"""
      Object.defineProperty(navigator, 'languages', {{value: {json.dumps(preferences)}}});
      if (!sessionStorage.getItem('initialized')) {{
        sessionStorage.setItem('initialized', 'yes');
        const saved = {json.dumps(saved)};
        if (saved !== null) localStorage.setItem('voxhalo.interfaceLanguage', saved);
      }}
    """)
    html = '<html><head><meta charset="utf-8"></head><body><select id="interfaceLanguage"></select><span data-i18n="common.interface"></span>' + embedded_localization() + '<script>VoxUI.mount()</script></body></html>'
    web_page.route("https://voxbridge.test/locale", lambda route: route.fulfill(body=html, content_type="text/html"))
    web_page.goto("https://voxbridge.test/locale")
    assert web_page.evaluate("VoxUI.locale") == expected
    if saved in (None, "auto", "unknown", ""):
        assert web_page.locator("#interfaceLanguage").input_value() == "auto"
    options = web_page.locator("#interfaceLanguage option").all_text_contents()
    assert options[1:] == ["中文", "English", "日本語", "Français", "Español", "Italiano", "Português", "हिन्दी"]
    web_page.select_option("#interfaceLanguage", "it")
    web_page.reload()
    assert web_page.evaluate("VoxUI.locale") == "it"
    assert web_page.locator("#interfaceLanguage").input_value() == "it"
    web_page.select_option("#interfaceLanguage", "auto")
    assert web_page.evaluate("VoxUI.locale") == web_page.evaluate("VoxUI.resolve(navigator.languages)")


def test_storage_denial_does_not_break_localization(web_page):
    errors = []
    web_page.on("pageerror", lambda error: errors.append(str(error)))
    web_page.add_init_script("""
      Object.defineProperty(navigator, 'languages', {value: ['hi-IN']});
      Object.defineProperty(window, 'localStorage', {get() {throw new DOMException('blocked', 'SecurityError')}});
    """)
    html = '<html><head><meta charset="utf-8"></head><body><select id="interfaceLanguage"></select>' + embedded_localization() + '<script>VoxUI.mount()</script></body></html>'
    web_page.route("https://voxbridge.test/locale", lambda route: route.fulfill(body=html, content_type="text/html"))
    web_page.goto("https://voxbridge.test/locale")
    assert web_page.evaluate("VoxUI.locale") == "hi"
    web_page.select_option("#interfaceLanguage", "fr")
    assert web_page.evaluate("VoxUI.locale") == "fr"
    assert not errors


def test_monitor_live_switch_preserves_rows_details_and_business_text(web_page):
    payload = {
        "version": 7, "rows": [{"id": "s1", "revision": 3,
            "source": "<b>原文</b>", "translation": "最新の訳文 <script>unsafe()</script>",
            "spoken": [{"text": "Wait <b>published</b>", "revision": 2}]}],
        "tentative": "まだ話しています", "session": {
            "status": "running", "source_language": "zh", "target_language": "ja",
            "source_name": "中文", "target_name": "日文", "last_error": ""},
        "tts": {"queue_depth": 2, "translated_audio_backlog_ms": 1800,
            "translated_audio_backlog_estimated": True, "tts_effective_speed": 1.2,
            "listener_count": 3, "last_error": ""},
    }
    web_page.route("https://voxbridge.test/monitor", lambda route: route.fulfill(body=MONITOR_HTML, content_type="text/html"))
    web_page.route("**/api/monitor/state", lambda route: route.fulfill(json=payload))
    web_page.route("**/listen/qr.svg", lambda route: route.fulfill(body="", content_type="image/svg+xml"))
    web_page.goto("https://voxbridge.test/monitor")
    web_page.wait_for_selector("details summary")
    web_page.locator("details summary").click()
    web_page.evaluate("window.originalRow = document.querySelector('.row')")
    web_page.locator("#follow").uncheck()
    for locale in WEB_CATALOG:
        web_page.select_option("#interfaceLanguage", locale)
        expected = WEB_CATALOG[locale]["monitor.target"].replace("{language}", WEB_CATALOG[locale]["language.ja"])
        assert web_page.text_content("#targetLabel") == expected
        assert web_page.text_content("#session") == WEB_CATALOG[locale]["monitor.running"]
        assert web_page.locator(".row").first.locator(":scope > div").first.text_content() == payload["rows"][0]["source"]
        assert web_page.locator("details > div").text_content() == payload["rows"][0]["translation"]
        assert web_page.locator(".row").first.locator(":scope > div > div").nth(1).text_content() == "Wait <b>published</b>"
        assert web_page.locator("details").get_attribute("open") == ""
        assert web_page.evaluate("window.originalRow === document.querySelector('.row')")
        assert not web_page.locator("#follow").is_checked()
        assert web_page.locator("#rows b, #rows script").count() == 0


@pytest.mark.parametrize("show_error", [False, True])
def test_login_localization_preserves_credentials_form_and_safe_redirect(web_page, show_error):
    from fastapi.testclient import TestClient
    from test_demo_streaming_ws_protocol import _args, _FakeASR
    from voxbridge.cli.demo_streaming_ws import _create_app, _hash_auth_password

    args = _args()
    args.auth_enabled = True
    args.auth_username = "admin"
    args.auth_password_hash = _hash_auth_password("test-secret")
    client = TestClient(_create_app(args, _FakeASR()))
    next_target = '/listen?label="><script>window.loginInjection=true</script>'
    if show_error:
        response = client.post("/login", data={"username": "admin", "password": "wrong", "next": next_target}, follow_redirects=False)
        assert response.status_code == 401
        assert "set-cookie" not in response.headers
    else:
        response = client.get("/login", params={"next": next_target})
        assert response.status_code == 200
    for key in re.findall(r'data-i18n(?:-aria|-alt)?="([^"]+)"', response.text):
        assert key in WEB_CATALOG["en"]
    web_page.add_init_script("Object.defineProperty(navigator, 'languages', {value: ['de-DE', 'hi-IN']})")
    web_page.route("https://voxbridge.test/login", lambda route: route.fulfill(body=response.text, status=response.status_code, content_type="text/html"))
    web_page.set_viewport_size({"width": 320, "height": 568})
    web_page.goto("https://voxbridge.test/login")
    assert web_page.evaluate("VoxUI.locale") == "hi"
    assert web_page.evaluate("window.loginInjection") is None
    web_page.fill("#username", "test+name")
    web_page.fill("#password", "test-only <password>")
    form_values = {"username": "test+name", "password": "test-only <password>", "next": next_target}
    for locale, messages in WEB_CATALOG.items():
        web_page.select_option("#interfaceLanguage", locale)
        assert web_page.title() == messages["login.title"]
        assert web_page.text_content("label[for=username]") == messages["login.username"]
        assert web_page.text_content("label[for=password]") == messages["login.password"]
        assert web_page.text_content("button[type=submit]") == messages["login.submit"]
        if show_error:
            assert web_page.text_content("[role=alert]") == messages["login.error"]
        else:
            assert web_page.locator("[role=alert]").count() == 0
        assert web_page.evaluate("Object.fromEntries(new FormData(document.querySelector('form')))") == form_values
        assert web_page.locator("#interfaceLanguage").evaluate("node => node.form === null")
        assert web_page.locator("#password").get_attribute("type") == "password"
        assert web_page.locator("#username").get_attribute("autocomplete") == "username"
        assert web_page.locator("#password").get_attribute("autocomplete") == "current-password"
        assert web_page.locator("form").get_attribute("method") == "post"
        assert web_page.locator("form").get_attribute("action") == "/login"
        assert web_page.locator("main").evaluate("node => node.scrollWidth <= node.clientWidth + 1")
    web_page.evaluate("""document.querySelector('form').addEventListener('submit', event => {
      event.preventDefault();
      window.submittedCredentials = Object.fromEntries(new FormData(event.target));
    })""")
    web_page.click("button[type=submit]")
    assert web_page.evaluate("window.submittedCredentials") == form_values
