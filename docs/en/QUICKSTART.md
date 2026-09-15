# Install VoxHalo on your Mac

**English** | [简体中文](../zh-CN/QUICKSTART.md) · [README](../../README.md)

The **1.8.0 desktop release** includes the App and its Python/AI runtime. You do not need Terminal, Xcode, Homebrew, Docker, a Python installation, or a cloud API key.

## Before you download

- **Mac:** Apple Silicon (M1 or later). Intel and Rosetta are not supported.
- **macOS:** 14.2 or later. The packaged native dependencies target this compatibility floor; the complete interpretation system has been validated on a MacBook Air M4 / 24 GB / macOS 26. Earlier hardware and OS versions still need separate performance validation.
- **Memory:** The desktop installer requires at least 16 GB; 24 GB or more is preferred. Real-time performance on 8 GB is not validated.
- **Storage:** keep at least 20 GB free during installation.
- **Internet:** required to download the App and approximately 4.61 GB of models and speech components. Installation also creates an approximately 344 MB Chinese speech model. Once installed, inference works offline.
- **Model license:** the HY-MT translation model has its own Tencent HY Community License. Its licensed territory excludes the EU, UK and South Korea. The installation window provides the complete text and asks you to confirm that you can use it under its terms. The public availability of the App does not grant a separate model license.

## 1. Download the desktop App

Open [GitHub Releases](https://github.com/hellcatjack/VoxHalo_mac/releases/latest). Under **Assets**, download **VoxHalo-1.8.0-macOS-arm64.dmg**.

Use the DMG for the easiest installation. The ZIP is an alternative copy of the same App. GitHub's automatically generated **Source code** files are for developers and do not contain an installable App.

## 2. Move the App to Applications

Open the DMG, then drag **同声传译.app** to the **Applications** shortcut. Eject the disk image and open the App from Applications. Its displayed name follows your system language, for example **Simultaneous Interpretation** in English.

If your account cannot write to the system Applications folder, copy the App to the **Applications** folder inside your home folder instead. Keep it at a stable location so macOS can remember its audio permissions.

### First-open macOS prompt

This release is **ad-hoc signed, without Apple Developer ID notarization**. macOS may block the first launch because it cannot verify the developer. After verifying that you downloaded it from this project's release page, follow Apple's per-App **System Settings → Privacy & Security → Open Anyway** procedure, if offered. See [Apple's opening-apps guide](https://support.apple.com/en-us/102445).

Do not disable Gatekeeper or your Mac's general security protections. An organization-managed Mac may require its administrator's approval. A checksum confirms that a download is unchanged; it is not a substitute for notarization.

## 3. Install the models in the App

The first-run window lists the local model requirements and download progress. Choose your interface language, review the model licenses, and confirm that the HY-MT terms permit your use. Then click the installation button.

The App:

1. Unpacks its prebuilt runtime into your user account.
2. Downloads the pinned Qwen3-ASR, HY-MT, Kokoro and VAD model files, Japanese dictionary, llama.cpp runtime and two prebuilt speech components.
3. Checks each download's SHA-256, prepares the Chinese speed-control model, and checks the installed runtime.
4. Enables the main console when installation finishes. It does not start recording automatically.

You can cancel an installation and retry later. Valid completed files are reused, and interrupted downloads resume when the server supports it. Keep the Mac awake during the initial download. If a network or disk error appears, correct the cause and retry; do not remove the model folder as a first troubleshooting step.

## 4. Choose sound and languages

In the main console:

1. Choose **Audio input**: system audio, system audio with translation-only playback, or your microphone.
2. Choose **Speech output**: system default, headphones, or another available device.
3. Choose the recognition language and the translated speech language. Chinese, English, Japanese, French, Spanish, Italian, Portuguese and Hindi can each be source or target.
4. Click **Start interpreting**. Allow the relevant macOS audio permission when asked. Model loading on the first service start can take longer than later starts.
5. Speak or play the source audio after capture starts.

For translated video through headphones, choose **System audio · Translation only**, then select your headphones or default output. The App suppresses the source audio during capture and plays the translation. Pause unrelated system audio.

Microphone mode requires microphone permission. System-audio capture requires the screen/system-audio recording permission shown by your version of macOS. Grant only the permission needed for your selected source. Check **System Settings → Privacy & Security** if capture is denied; restart the App if macOS requests it.

## 5. Subtitles, monitoring and stopping

Desktop subtitles follow actual local speech playback. Use subtitle settings to adjust their appearance and position. The optional monitor displays text and status; closing the browser does not stop interpretation.

Phones and tablets can scan the App's QR code on the same LAN. Internet is not needed for LAN listening, but the devices must be able to reach each other. All listeners receive the session's selected target language.

Pause source audio before ending a session. **End interpretation** stops capture; **Stop services** unloads models. Closing the main window keeps the App available in the menu bar. Use **Stop services and quit** to exit fully.

## Files, updates and removal

The release App stores runtime versions and models in **~/Library/Application Support/VoxHalo/**. In Finder, choose **Go → Go to Folder…** and paste that path to inspect it. Do not rename files while services or installation are running.

- **Update:** stop services and quit, then replace the App with the new release. Models are stored separately and can be reused when their checksums match. Each release has a separate runtime directory.
- **Existing source installation:** keep it until you have tested the downloaded App. The desktop release uses its own managed runtime; it does not depend on, move, or delete your previous project folder. App language/audio preferences remain in macOS preferences.
- **Retry:** reopen the installation window. Completed verified model downloads are retained. A corrupted existing file is reported and preserved. Use the explicit repair action to keep a named backup and download a verified replacement.
- **Uninstall:** quit the App, move it to Trash, and remove the VoxHalo Application Support folder if you also want to delete its models and runtime. Removing only the App preserves models for reinstalling.

## If something fails

| Symptom | What to do |
|---|---|
| Download stalls or fails | Check that GitHub, Hugging Face and files.pythonhosted.org are reachable; retry from the App |
| Not enough disk space | Free space on your home volume; leave 20 GB available and retry |
| Checksum mismatch | Keep the displayed details, retry, and report persistent failures; do not use the incomplete file |
| Start is unavailable | Finish model installation first, then wait for the service check to finish |
| No recognized speech | Confirm the input, source language, macOS permission and that source audio is playing |
| No translated speech | Check the selected output device and volume; confirm it is still connected |
| Phone cannot connect | Use the App's LAN address on the same reachable network; a loopback URL works only on the Mac |

For help, include the App version, Mac model/memory/macOS, language direction, input/output selection and error text in a [GitHub issue](https://github.com/hellcatjack/VoxHalo_mac/issues). Remove private transcript content and local control credentials before sharing logs.

Developers can still use the [source installation guide](INSTALLATION.md). Detailed models, voices and licenses are listed in the [model guide](MODELS.md).
