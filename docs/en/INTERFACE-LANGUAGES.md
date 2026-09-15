# Interface languages

**English** | [简体中文](../zh-CN/INTERFACE-LANGUAGES.md)

App 1.7.0 (build 20) provides Chinese, English, Japanese, French, Spanish, Italian, Portuguese and Hindi for the main window, menus, subtitle settings, common status/error messages, monitor, listener and password-protected sign-in pages.

## Choosing a language

Use **Interface language** at the top of the App. Choices always use each language’s own name. The default follows macOS preferred languages in order; regional variants such as pt-BR map to Portuguese. Chinese variants, including zh-Hant, use the Simplified Chinese interface provided in this release. If none of the preferred languages is supported, the interface uses English.

The monitor, listener and sign-in pages have their own interface selector and follow the browser’s ordered language preferences by default. Manual choices are saved in site storage and shared by pages on the same origin. App preferences remain separate. Select **Follow system** in the App or **Automatic** on the web to restore automatic selection. An unsupported saved choice also returns to automatic selection. If browser storage is blocked, switching still works in the open page but may not persist.

You can change the interface during interpretation. This does not change recognition/target languages, devices, ASR context, translated text, published speech or playback state. A Japanese interface can still run English-to-French interpretation. Chinese automatic speech remains 1.10–1.30.

## Scope and resources

All interface translations are bundled offline. They do not call Qwen, HY-MT or a cloud service. Actual source text, translations, captions, device names and user input remain unchanged. System-owned controls, including file choosers, follow macOS language settings. Raw third-party technical error details may retain their original language. Permission dialogs use system-selected localized descriptions; changing the App interface does not change an already-open system dialog.

Catalogs live in `VoxBridge/voxbridge/ui_locales/`. Native and browser presentation resources are independent of the business language catalog. The legacy browser-owned capture demo is outside the default native product flow; this release covers the native App, passive monitor, listener and optional sign-in page.

Verification covers catalog/placeholder completeness, locale priority and persistence, native controls preserving input and device selection, browser language switches during playback preserving audio/captions, and mobile layouts. The App was compiled and visually checked in English, Japanese, French and Hindi. This is not a claim of native-speaker review of every phrase or additional recognition/translation accuracy guarantees.

## Release verification · 2026-09-15

- Full Python suite: **1,163 passed, 32 skipped**, one dependency deprecation warning. Skips cover optional runtime/browser/FFmpeg requirements unavailable to that test environment. The new native and browser localization checks ran successfully.
- AppKit checks cover all eight languages, preserving menu shortcuts, selected device/language codes, user input and control enabled states. Existing native session and eight-language catalog checks also passed.
- Browser checks cover switching during simulated playback, caption identity, ordered preferences, saved choices, mobile layouts and sign-in form values/redirect escaping. These are browser regression checks, not a new physical-device audio endurance test.
- Installed **1.7.0 build 20** passed code-signature verification. The installed binary and native catalogs match the verified build. After Desktop Folder permission was granted, the App returned to an idle state with start controls enabled and existing interpretation/device settings preserved.
