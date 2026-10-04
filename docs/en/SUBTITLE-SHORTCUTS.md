# Control subtitles during presentations

[简体中文](../zh-CN/SUBTITLE-SHORTCUTS.md)

Included in **LingoCove 1.0.0** and later. Font-size shortcuts require **build 39 or later**; older release downloads may not include them.

While interpretation is running, control desktop subtitles directly from a full-screen PowerPoint presentation without switching back to LingoCove. Recognition, translation, spoken output and web monitoring continue independently.

| Default shortcut | Action |
|---|---|
| Control + Shift + Command + S | Show / hide subtitles |
| Control + Shift + Command + B | Show / hide the rectangular subtitle background |
| Control + Shift + Command + ↑ | Move subtitles up |
| Control + Shift + Command + ↓ | Move subtitles down |
| Control + Shift + Command + ← | Decrease subtitle font size by 2 pt |
| Control + Shift + Command + → | Increase subtitle font size by 2 pt |
| Control + Shift + Command + 9 | Place subtitles at the top of the selected display |
| Control + Shift + Command + 0 | Place subtitles at the bottom, including over the Dock |

Each Up/Down Arrow press moves **8 screen points**. Hold for about 0.3 seconds to move continuously; releasing stops movement. Subtitles stay within the display and their position is saved automatically. Top/bottom actions preserve horizontal position and the selected subtitle display.

**Left/Right Arrow** changes subtitle size by **2 pt** within **12–144 pt**. Hold for 0.3 seconds to repeat at a controlled pace (one step every 0.12 seconds). Changes save automatically and update the settings slider. Resizing a hidden caption does not reveal it. From build 40, Reading first with native local speech reflows at the current PCM playback position without restarting a reading timer or replaying earlier pages. Without native local playback, resizing reflows current and unread text and grants the new page its full reading time. It never changes TTS speed or audio scheduling.

Hidden **Reading first** captions with native local speech continue following PCM playback and restore the current reading card when shown. Without native local playback, hiding pauses the reading clock and showing resumes its remaining time. **Follow speech** continues following playback while hidden and restores the currently spoken caption. Moving subtitles preserves the current presentation. If there is no current translation, showing subtitles does not create preview text or start interpretation.

The console's book button and **Reading history** menu retain completed full translations and corrections for reading at your own pace, including after stopping. Accepted incremental wording not covered by a full translation is also recorded as **Spoken supplement**. The record resets at the next session and is not saved across App relaunches. Live captions aim for a 0.6-second lead when the next PCM is scheduled; they do not promise every page the fallback timer's minimum hold. Native audio finishing waits for published PCM and actual playback, excluding unpublished speculative preparation/HLS mirror buffering, and stops after 60 seconds without progress or the 180-second hard limit. These limits do not guarantee processing/playing unlimited backlog without omissions. See [caption timing, history and finish limits](../../VoxBridge/docs/READING-SUBTITLES.md).

In **Subtitle Settings…**, select **Enable rectangular background** to place a filled rectangle behind the current caption. It is off by default and shares **Shadow and background color** and **Shadow and background opacity** with the text shadow. The background also works when the shadow is disabled. Its width and height follow the actual text bounds with a small inset around the text. Each rendered line, including automatic wraps, has its own fitted rectangle with transparent space between lines. Empty lines and missing captions have no background. The subtitle width setting still controls wrapping, not the background width. Toggling it preserves the text, page clock and spoken output. Settings save automatically. Upgrades preserve valid existing custom bindings. New actions receive their default key or an unused key if that default is occupied; check the settings page.

## Customize shortcuts

Open **Subtitle Settings…** and scroll to **Enable global shortcuts during interpretation**. Disable the group, choose a different final key for each action, or select **Restore default shortcuts**. Control, Shift and Command remain mandatory; plain arrows, Space and Esc cannot be assigned. Keys already assigned to another subtitle action cannot be selected again.

The table uses US keyboard labels. For other layouts, use the labels displayed in settings. Bindings retain their physical key positions; labels update with the current keyboard layout, including the A/Q difference between AZERTY and QWERTY.

Global keys are registered while interpretation is running or finishing queued audio. They are released after stopping, disabling shortcuts or quitting. The App checks system-reserved keys and requests exclusive registration. If a key cannot be registered, the console and subtitle settings display a warning; other available keys continue working. Choose a different key, or close the conflicting app and restart interpretation.

The defaults avoid Microsoft's published [PowerPoint for Mac presentation shortcuts](https://support.microsoft.com/en-US/accessibility/powerpoint/use-keyboard-shortcuts-to-deliver-powerpoint-presentations) and [editing shortcuts](https://support.microsoft.com/en-us/accessibility/powerpoint/use-keyboard-shortcuts-to-create-powerpoint-presentations). Custom app shortcuts, PowerPoint add-ins and user overrides cannot all be discovered automatically. Check the keys before a live presentation.

## Developer verification

From `VoxBridge/`, run `../.venv/bin/python -m pytest tests/test_subtitle_shortcuts.py tests/test_native_localization.py -q`. Coverage includes occupied-key detection and release, hold/release behavior, font-size limits, migration of custom bindings, display boundaries, French keyboard labels, current-caption restoration, pagination without local speech, and real PCM output draining normally during rapid subtitle changes. The audio check plays a silent fixture without connecting to model services.

Build 39 validation on 2026-09-29: **1,389 tests passed, 32 skipped**, with one third-party deprecation warning. Added coverage for font steps and bounds, controlled hold repeat, older-binding migration, Carbon font-action callbacks and uninterrupted silent PCM during resizing. Installed build 39 with the existing signing identity; English/Chinese settings rendered correctly and all eight global keys registered during interpretation. Tool-generated font shortcuts did not trigger the system callback; physical-keyboard behavior across applications still requires manual acceptance. PowerPoint slideshow and model endurance tests were not repeated for this change.

`tests/macos/SubtitleShortcutPresentationAcceptance.swift` is a time-bounded manual acceptance harness for a disposable PowerPoint deck. It records actual OS-delivered hotkey actions, the foreground app, visibility, movement and font size. It does not capture audio, connect to models or save user preferences.

Local verification on 2026-09-15 used macOS 26.6.2 and PowerPoint 16.112.4: **1,241 tests passed, 32 skipped**, with one third-party Starlette/AnyIO deprecation warning. App compilation and signature verification passed. Native settings were checked for customization, persistence, reset, disable and English/Chinese switching. Automated tests cover real Carbon event handling, key registration/release, pagination and continuous playback of a silent PCM fixture.

In a disposable two-slide PowerPoint deck, tool-generated presses of all five combinations left the slide unchanged; a plain Right Arrow advanced normally. Those generated presses did not reach the system global-hotkey callback. **Physical-keyboard triggering across applications and the hold-to-move experience still need manual acceptance**; the PowerPoint compatibility check does not establish that result.
