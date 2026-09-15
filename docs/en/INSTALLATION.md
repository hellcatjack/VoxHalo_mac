# Installation and operation guide

**English** | [简体中文](../zh-CN/INSTALLATION.md) · [README](../../README.md) · [Models](MODELS.md)

These instructions match the repository's `setup.sh` and App 1.6.0/build 18. Run commands in Terminal. Commands with `$HOME` adapt to your account; do not replace them with the original developer's path.

## 1. Check your Mac

The recommended evaluation floor is **M1 / 16 GB / macOS 14.2+ / 20 GB free storage**, inferred from architecture, package compatibility, and a memory budget. It is not a validated real-time performance minimum. The complete system has been tested on **MacBook Air M4 / 24 GB / macOS 26**. For regular use, prefer the validated configuration; earlier chips, 16 GB machines, and macOS 14/15 require testing of their own.

```sh
uname -m
sw_vers -productVersion
sysctl -n hw.memsize
df -h "$HOME"
```

Expected architecture: `arm64`. `hw.memsize` reports bytes: 16 GiB is `17179869184`, and 24 GiB is `25769803776`. Available disk space is in the `Avail` column. An `x86_64` result means either an Intel Mac or an emulated shell; use a native Terminal on Apple Silicon. Intel is unsupported.

### Compatibility evidence

- The App build targets macOS 14.0, but [translation-only capture](../../VoxBridge/deploy/macos/app/SystemAudioTap.swift) explicitly requires macOS 14.2 audio taps.
- [MLX installation requirements](https://ml-explore.github.io/mlx/build/html/install.html) specify Apple Silicon and macOS 14+. The fixed [MLX 0.32.2](https://pypi.org/project/mlx/0.32.2/#files) and [mlx-metal 0.32.2](https://pypi.org/project/mlx-metal/0.32.2/#files) publish separate macOS 14/15/26 wheels. The tested Mac selected the macOS 26 wheel; that does not mean it is the only published wheel.
- The pinned [ONNX Runtime 1.30.0](https://pypi.org/project/onnxruntime/1.30.0/#files) includes a macOS 14 arm64 wheel. The supplied llama-server binary declares macOS 13.3 as its deployment minimum.
- Full build verification used macOS 26.6.2, Swift 6.3.3, and macOS SDK 26.5. A source target or wheel tag is compatibility evidence, not a completed installation test on every older OS.

The installer checks Apple Silicon and build-tool availability. It does not benchmark your Mac or enforce a 16 GB memory limit. An 8 GB machine is not a supported performance claim.

## 2. Install Apple command-line tools

```sh
xcode-select --install
```

Finish the system installer before continuing. If tools are already installed, check:

```sh
xcode-select -p
xcrun --find swiftc
xcrun --show-sdk-version
git --version
```

Use command-line tools compatible with your macOS and recent enough to expose the macOS 14.2 audio-tap APIs. A full Xcode installation is also usable when selected as the active developer directory. No Homebrew installation is required.

## 3. Clone into a permanent folder

Avoid temporary folders or cloud-synced folders that may evict large model files. A user-owned folder also avoids a need for `sudo`.

```sh
mkdir -p "$HOME/Projects"
cd "$HOME/Projects"
git clone https://github.com/hellcatjack/VoxHalo_mac.git
cd VoxHalo_mac
```

The public HTTPS clone does not require a GitHub login. If you already have this checkout, use the update instructions instead of nesting another clone inside it. The `v1.5.1` tag preserves the original source release; `main` carries the latest code and documentation.

## 4. Install the runtime, models, and App

```sh
./setup.sh
```

The script performs these steps:

1. Downloads uv **0.12.13** from its official release and checks the archive's SHA-256.
2. Installs managed Python **3.12.14** and creates the root `.venv`; it does not use global Python.
3. Installs the pinned Mac dependencies and local VoxBridge package.
4. Creates the isolated `runtime/model-tools` environment for ONNX graph repair.
5. Downloads and checks the assets in `scripts/runtime-assets.json`, including Qwen, HY-MT, Kokoro, VAD, and llama.cpp.
6. Generates the separate Chinese floating-point-speed model and checks its expected hash.
7. Checks local resources and compiles/codesigns **同声传译.app** into `~/Applications`.

Setup also installs `pyopenjtalk==0.4.1` and the checksum-pinned OpenJTalk 1.11 dictionary for Japanese. This native dependency uses the command-line build tools installed above. Japanese speech never downloads a dictionary during a session.

About 4.58 GB of model/runtime assets are downloaded, plus Python and packages. Installation time depends on your network; no fixed duration is promised. The first App service start also loads and quantizes the ASR model, so allow it to finish before trying to capture audio.

The installer needs access to GitHub release assets, Hugging Face model files, and Python package indexes. It creates local resources only and does not start recording. Model use is subject to the [separate model licenses](MODELS.md#licenses-and-attribution), including HY-MT's custom conditions.

### Optional installation choices

The default `~/Applications` destination is user-owned. To use the system Applications folder instead, if your account can write there:

```sh
VOXHALO_APP_PATH="/Applications/同声传译.app" ./setup.sh
```

To reuse matching assets from an existing installation, substitute its actual root directory below:

```sh
VOXHALO_ASSET_CACHE="/absolute/path/to/existing/VoxHalo_mac" ./setup.sh
```

The cache source is read only; matching files are copied after verification. Environments are created in the new checkout. Checksum failures never silently select another model. Do not run the installer using `sudo` to work around permissions.

## 5. Verify installation

From the repository root:

```sh
.venv/bin/python --version
./macos.sh check
.venv/bin/python scripts/setup_assets.py --verify-only
```

Expect Python 3.12.x, a message that Python/models/FFmpeg are present, and confirmation that assets match SHA-256. `check` verifies resources; it does not start inference or prove that microphone permissions are granted.

Optional service readiness check:

```sh
./macos.sh start
./macos.sh status
```

Both `app.ready` and `translation.ready` should be `true`. This starts models but does not select an audio input or begin capture. End this check with `./macos.sh stop` if you do not intend to use the App immediately. Ports are fixed at **8024** for the application and **8876** for the local translator. A conflicting process is reported rather than terminated.

## 6. Open the App and allow audio access

```sh
open "$HOME/Applications/同声传译.app"
```

If you selected `/Applications`, open the App at that path instead. Current builds use an ad-hoc signature, not Developer ID notarization. If macOS blocks a locally built copy, follow the system's app-opening prompt or its Privacy & Security controls; do not disable Gatekeeper globally.

| Input or operation | Required action |
|---|---|
| Microphone | Allow **同声传译** under Privacy & Security → Microphone |
| System playback | Allow the App under Screen & System Audio Recording, or the equivalent label in your macOS version |
| Checkout in a protected folder | Allow the specific folder request if it is your chosen installation location |
| LAN listeners | Allow incoming connections for the relevant service if macOS Firewall prompts |

Rebuilding or updating an ad-hoc signed App changes its code identity. macOS may request audio access again even when the previous entry still appears enabled. The system-audio dialog is separate from the Desktop-folder dialog; finish each requested permission before expecting capture to start.

Full Disk Access is not required. If you change audio permission after denying it, quit and reopen the App. Permissions belong to the native App, not Chrome.

## 7. Start your first session

| App label | Meaning |
|---|---|
| 输入来源 | Input source |
| 朗读输出 | Speech output |
| 识别 → 译音 | Source and target languages; eight choices, identical pairs excluded |
| 开始传译 / 结束传译 | Start / end interpretation |
| 启动服务 / 停止服务 | Load / unload model services |
| 打开监控页 | Open read-only monitoring page |
| 字幕设置… | Configure subtitle appearance and placement |
| 停止服务并退出 | Stop capture, playback, and services, then quit |

For translated browser audio, select **系统播放声音 · 只听译音**, then **系统默认输出** or a specific headset, and choose the direction matching the source speech. Click **开始传译**, wait for active capture, then play the video. Keep the video's audio enabled. Suppression of the original sound is handled by the App; muting the source can remove the signal being captured.

Check input level, source text, translation, and speech output with a short sample. Test with the browser monitor both open and closed. Before ending interpretation, pause the source video. If you use regular **系统播放声音**, the original audio remains audible alongside translated speech.

Capture includes other applications' system playback and excludes this App's own speech; pause other tabs and avoid opening a local HLS player during system capture. For microphone capture, use headphones to limit acoustic feedback. Change devices or direction only after ending the session. If an explicitly selected device disconnects, reconnect it or choose another device and press **刷新设备** (refresh devices).

## 8. Monitor, subtitles, and LAN listeners

- **Monitor:** `http://127.0.0.1:8024` on the Mac, or the Mac's actual LAN address from another device. It is not the session controller.
- **Subtitles:** enable the overlay in **字幕设置…**. Configure display, font, size, color, shadow, position, and width; bottom placement can cover the Dock. Appearance changes do not alter TTS audio.
- **Listeners:** scan the App's QR code on the same LAN, then press **Start Listening**. It points to the detected LAN IP, not `127.0.0.1`. No LAN address means local use can continue, but no valid LAN QR code is offered.

If another device cannot connect, check Wi-Fi/Ethernet, firewall permissions, and guest-network/client isolation. The default profile has no web login; keep `8024` on a trusted network. Mobile HLS buffering is separate from the native Mac audio clock.

## 9. Update or rebuild

Stop services and quit the App. From the existing repository root:

```sh
git status --short
git pull --ff-only
./setup.sh
```

Save or commit local changes before pulling; do not discard them with a forced reset. Existing matching models are reused. To rebuild only the App after dependencies are already installed:

```sh
./build-app.sh
```

To build a review copy without replacing the installed App:

```sh
./build-app.sh --destination "$PWD/dist/同声传译.app"
```

If you previously chose a custom App destination, specify it again when rebuilding; it is not automatically remembered by the shell script. App audio/subtitle preferences are stored separately in macOS UserDefaults.

When upgrading from the former Chinese App name, quit the old App first. The new entry is `同声传译.app`. After verifying the new copy, remove the old App copy and desktop shortcut to avoid opening the earlier build. The bundle identifier remains unchanged, so existing preferences can be reused.

## 10. Relocate, migrate, or uninstall

The App stores the absolute checkout location. Python environments also contain installation-specific paths. Do not move only the App, copy a Linux environment, or assume an existing `.venv` remains valid after moving folders.

For relocation or migration, stop the old installation, clone a fresh checkout at the final destination, and run `setup.sh` there. Optionally use `VOXHALO_ASSET_CACHE` to copy verified model assets from the old workspace. Rebuild the App against the new path, verify it, and only then remove the old installation. Only one installation can own ports 8024/8876 at a time.

To uninstall, select **停止服务并退出**, remove the App from its chosen Applications folder, and remove the checkout only if its models/logs are no longer needed. Optional preference reset, with the App closed:

```sh
defaults delete org.pccs.voxbridge.console
```

This resets this App's device/subtitle preferences; it does not remove model files or macOS audio permissions. A “domain not found” response simply means no saved preference domain exists.

For an existing 1.5.x installation, follow the update procedure below and rerun `./setup.sh`; a source-only `git pull` does not install the new Japanese dependency or dictionary.

## Troubleshooting

| Symptom | Check and recovery |
|---|---|
| `swiftc` or SDK unavailable | Finish Command Line Tools installation; verify `xcode-select -p` and `xcrun --find swiftc`; select a valid compatible Xcode/tool installation |
| Architecture rejected / no compatible wheel | Confirm `uname -m` is `arm64` and your OS meets the documented compatibility floor; do not substitute untested dependency versions |
| Download interrupted | Restore network access and rerun `./setup.sh`; verified completed assets are reused, while an incomplete individual download may restart |
| Checksum mismatch | Read the exact reported path, preserve/move that file out of the asset location, then rerun; never edit the manifest merely to accept an unknown file |
| Python environment invalid after moving | Use a fresh clone and rebuild environments at the final path; reuse only verified assets |
| `8024` or `8876` occupied | Stop the other known installation/application that owns the port; do not blindly kill unrelated processes |
| No input level | Check App audio permissions, selected device, source playback volume, and whether the source is paused or muted |
| Source sound still audible | Select **系统播放声音 · 只听译音**, confirm capture started, and check macOS 14.2+; regular system-audio mode preserves source sound |
| Translation appears but no speech | Check output selection, system volume, device connection, local-playback setting, TTS queue, and logs |
| App opens but cannot find service files | The checkout may have moved or been deleted; recreate the installation and rebuild the App |
| Increasing backlog / memory pressure | Close unrelated heavy applications, use the validated configuration, and evaluate a representative long sample; model loading alone does not establish real-time suitability |
| LAN page unavailable | Verify the App's current LAN IP, firewall, and network isolation; a phone's `127.0.0.1` is the phone itself |

Useful read-only checks:

```sh
./macos.sh status
lsof -nP -iTCP:8024 -sTCP:LISTEN
lsof -nP -iTCP:8876 -sTCP:LISTEN
tail -n 80 VoxBridge/logs/macos-app.log
tail -n 80 VoxBridge/logs/macos-translation.log
```

Review logs before sharing. Never attach the native control token, private recordings, or full runtime-state directories to a public issue. Report reproducible problems with App/macOS versions, chip/memory, direction, devices, and sanitized error text to [GitHub Issues](https://github.com/hellcatjack/VoxHalo_mac/issues).
