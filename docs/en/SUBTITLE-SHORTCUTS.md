# Control subtitles during presentations

[简体中文](../zh-CN/SUBTITLE-SHORTCUTS.md)

This feature is available in the current source tree. The previously published **1.8.0 installer does not include these shortcuts**. Build the App from the current source to use them.

While interpretation is running, control desktop subtitles directly from a full-screen PowerPoint presentation without switching back to VoxHalo. Recognition, translation, spoken output and web monitoring continue independently.

| Default shortcut | Action |
|---|---|
| Control + Shift + Command + S | Show / hide subtitles |
| Control + Shift + Command + ↑ | Move subtitles up |
| Control + Shift + Command + ↓ | Move subtitles down |
| Control + Shift + Command + 9 | Place subtitles at the top of the selected display |
| Control + Shift + Command + 0 | Place subtitles at the bottom, including over the Dock |

Each arrow press moves **8 screen points**. Hold for about 0.3 seconds to move continuously; releasing stops movement. Subtitles stay within the display and their position is saved automatically. Top/bottom actions preserve horizontal position and the selected subtitle display.

Hidden subtitles continue to follow current speech. Showing them restores the current caption without replaying old sentences. When local playback is off, long translations retain their page clock while hidden or moved. If there is no current translation, showing subtitles does not create preview text or start interpretation.

## Customize shortcuts

Open **Subtitle Settings…** and scroll to **Enable global shortcuts during interpretation**. Disable the group, choose a different final key for each action, or select **Restore default shortcuts**. Control, Shift and Command remain mandatory; plain arrows, Space and Esc cannot be assigned. Keys already assigned to another subtitle action cannot be selected again.

The table uses US keyboard labels. For other layouts, use the labels displayed in settings. Bindings retain their physical key positions; labels update with the current keyboard layout, including the A/Q difference between AZERTY and QWERTY.

Global keys are registered while interpretation is running or finishing queued audio. They are released after stopping, disabling shortcuts or quitting. The App checks system-reserved keys and requests exclusive registration. If a key cannot be registered, the console and subtitle settings display a warning; other available keys continue working. Choose a different key, or close the conflicting app and restart interpretation.

The defaults avoid Microsoft's published [PowerPoint for Mac presentation shortcuts](https://support.microsoft.com/en-US/accessibility/powerpoint/use-keyboard-shortcuts-to-deliver-powerpoint-presentations). Custom app shortcuts, PowerPoint add-ins and user overrides cannot all be discovered automatically. Check the keys before a live presentation.

## Developer verification

From `VoxBridge/`, run `../.venv/bin/python -m pytest tests/test_subtitle_shortcuts.py tests/test_native_localization.py -q`. Coverage includes occupied-key detection and release, hold/release behavior, display boundaries, French keyboard labels, current-caption restoration, pagination without local speech, and real PCM output draining normally during rapid subtitle changes. The audio check plays a silent fixture without connecting to model services.

`tests/macos/SubtitleShortcutPresentationAcceptance.swift` is a time-bounded manual acceptance harness for a disposable PowerPoint deck. It records actual OS-delivered hotkey actions, the foreground app, visibility and movement. It does not capture audio, connect to models or save user preferences.

Local verification on 2026-09-15 used macOS 26.6.2 and PowerPoint 16.112.4: **1,241 tests passed, 32 skipped**, with one third-party Starlette/AnyIO deprecation warning. App compilation and signature verification passed. Native settings were checked for customization, persistence, reset, disable and English/Chinese switching. Automated tests cover real Carbon event handling, key registration/release, pagination and continuous playback of a silent PCM fixture.

In a disposable two-slide PowerPoint deck, tool-generated presses of all five combinations left the slide unchanged; a plain Right Arrow advanced normally. Those generated presses did not reach the system global-hotkey callback. **Physical-keyboard triggering across applications and the hold-to-move experience still need manual acceptance**; the PowerPoint compatibility check does not establish that result.
