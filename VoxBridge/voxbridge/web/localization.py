"""Offline interface catalog and a presentation-only browser localization runtime.

Embed the runtime in each HTML constant so standalone page fixtures work and no
extra request is needed. This catalog is independent of ASR/TTS languages.
"""

import json
from pathlib import Path


WEB_CATALOG = json.loads(
    (Path(__file__).resolve().parents[1] / "ui_locales" / "web.json").read_text(encoding="utf-8")
)

_RUNTIME = r"""<script>
(() => {
  const catalog = __CATALOG__;
  const languages = {zh: '中文', en: 'English', ja: '日本語', fr: 'Français',
    es: 'Español', it: 'Italiano', pt: 'Português', hi: 'हिन्दी'};
  const storageKey = 'voxhalo.interfaceLanguage';
  const bindings = new Map();
  const listeners = new Set();
  let selector = null;
  function baseCode(value) {
    return String(value || '').trim().toLowerCase().replace(/_/g, '-').split('-')[0];
  }
  function resolve(preferences) {
    for (const preference of preferences || []) {
      const code = baseCode(preference);
      if (Object.hasOwn(languages, code)) return code;
    }
    return 'en';
  }
  function browserLanguages() {
    return navigator.languages && navigator.languages.length
      ? navigator.languages : [navigator.language];
  }
  let preference = 'auto';
  try {
    const saved = localStorage.getItem(storageKey);
    const code = baseCode(saved);
    if (Object.hasOwn(languages, code)) preference = code;
  } catch (error) {}
  let locale = preference === 'auto' ? resolve(browserLanguages()) : preference;
  function t(key, parameters = {}) {
    const values = typeof parameters === 'function' ? parameters() : parameters;
    const message = catalog[locale][key] ?? catalog.en[key] ?? key;
    return message.replace(/\{([A-Za-z0-9_]+)\}/g, (match, name) =>
      Object.hasOwn(values, name) ? String(values[name]) : match);
  }
  function write(node, message) {
    if (node.textContent !== message) node.textContent = message;
  }
  function bind(node, key, parameters = {}) {
    if (typeof node === 'string') node = document.getElementById(node);
    node.removeAttribute('data-i18n');
    bindings.set(node, {key, parameters});
    write(node, t(key, parameters));
  }
  function unbind(node) {
    bindings.delete(node);
    node.removeAttribute('data-i18n');
  }
  function apply() {
    document.documentElement.lang = locale === 'zh' ? 'zh-CN' : locale;
    document.querySelectorAll('[data-i18n]').forEach(node => write(node, t(node.dataset.i18n)));
    document.querySelectorAll('[data-i18n-aria]').forEach(node =>
      node.setAttribute('aria-label', t(node.dataset.i18nAria)));
    document.querySelectorAll('[data-i18n-alt]').forEach(node =>
      node.setAttribute('alt', t(node.dataset.i18nAlt)));
    for (const [node, binding] of bindings) {
      if (!node.isConnected) { bindings.delete(node); continue; }
      write(node, t(binding.key, binding.parameters));
    }
    if (selector) {
      selector.options[0].textContent = t('common.auto');
      selector.value = preference;
    }
  }
  function choose(value) {
    preference = value === 'auto' ? 'auto' : resolve([value]);
    locale = preference === 'auto' ? resolve(browserLanguages()) : preference;
    try { localStorage.setItem(storageKey, preference); } catch (error) {}
    apply();
    listeners.forEach(listener => listener());
  }
  function mount() {
    selector = document.getElementById('interfaceLanguage');
    if (selector) {
      selector.replaceChildren();
      for (const [code, label] of [['auto', t('common.auto')], ...Object.entries(languages)]) {
        const option = document.createElement('option');
        option.value = code;
        option.textContent = label;
        if (code !== 'auto') option.lang = code === 'zh' ? 'zh-CN' : code;
        selector.append(option);
      }
      selector.addEventListener('change', () => choose(selector.value));
    }
    apply();
  }
  window.VoxUI = {t, bind, unbind, mount, resolve, choose,
    onChange: listener => listeners.add(listener), get locale() { return locale; }};
  window.addEventListener('languagechange', () => {
    if (preference !== 'auto') return;
    locale = resolve(browserLanguages());
    apply();
    listeners.forEach(listener => listener());
  });
})();
</script>"""


def embedded_localization() -> str:
    """Return an HTML-safe inline script; catalog strings never become markup."""
    payload = json.dumps(WEB_CATALOG, ensure_ascii=False, separators=(",", ":"))
    payload = payload.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    payload = payload.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    return _RUNTIME.replace("__CATALOG__", payload)
