# VoxHalo for macOS

**English** | [简体中文](README.zh-CN.md)

Local speech interpretation between eight languages for Apple Silicon Macs, with native audio capture, translated speech, playback-synchronized subtitles, and LAN listening.

**App:** 1.6.0, build 18 · **Maintainer:** [hellcatjack](https://github.com/hellcatjack) · **Contact:** [hellcatjack@gmail.com](mailto:hellcatjack@gmail.com)

The App is named **同声传译**. Its current interface is in Chinese; the English installation guide includes the corresponding button names. Recognition, translation, and synthesis run on your Mac. Initial installation downloads models and dependencies; routine inference needs no cloud account or API key.

## Documentation

- [Detailed installation, updates, and troubleshooting](docs/en/INSTALLATION.md)
- [Eight-language validation and limitations](docs/en/EIGHT-LANGUAGES.md)
- [Phase 1 refactor validation](docs/en/PHASE1-VALIDATION.md)
- [Architecture and reusable module boundaries](docs/en/ARCHITECTURE.md)
- [Models, quantization, prompts, and licenses](docs/en/MODELS.md)
- [中文说明](README.zh-CN.md)
- [Change history](CHANGELOG.en.md) · [Release validation](docs/PUBLICATION.md)

## Features

- Chinese, English, Japanese, French, Spanish, Italian, Portuguese and Hindi: 56 directed pairs, selected with source and target menus before starting.
- Native system-audio capture, translation-only system playback, default input, or a specific microphone/audio interface.
- Default output, a specific headset/speaker, or LAN listening without local playback.
- Continuous PCM playback with automatic catch-up speed; Chinese synthesis favors complete sentences to reduce mid-sentence prosody resets.
- Completed-translation subtitles synchronized with local speech. Adjust font, size, colors, shadow, display, position, and width, including the Dock area.
- The App owns capture and playback. Closing or refreshing the monitoring browser does not stop interpretation.
- Automatically detected LAN addresses and QR codes let phones/tablets listen to shared HLS audio.

```text
System audio / microphone
  → Native capture → Qwen3-ASR → stable source text → HY-MT → translated text
  → Kokoro → native PCM playback + subtitle overlay
           → shared HLS stream for LAN listeners

Browser monitor ← source text, translations, and TTS status
```

## Models and acceleration

| Component | Model and size | Configuration in this release |
|---|---|---|
| Speech recognition | [Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B), 0.6B model variant | MLX 0.32.2 / mlx-qwen3-asr 0.4.0; INT8 weights, group size 64; Metal GPU |
| Translation | [HY-MT1.5-1.8B](https://huggingface.co/tencent/HY-MT1.5-1.8B), 1.8B parameters | Official Q8_0 GGUF; llama.cpp b10809; Metal GPU; 4,096-token context |
| Multilingual speech (seven languages) | [Kokoro-82M v1.0](https://huggingface.co/hexgrad/Kokoro-82M), approximately 82M parameters | One shared ONNX Runtime CPU model; English `am_michael`, six additional voices |
| Chinese speech | [Kokoro-82M v1.1-zh](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh), approximately 82M parameters | ONNX Runtime CPU, male voice `zm_029`; repaired floating-point speed input |
| Speech activity | Silero VAD ONNX | CPU; assists silence handling and speech-boundary protection |

ASR and translation share a GPU execution lock; TTS uses two CPU threads. This release uses Metal and does not deploy models to the Apple Neural Engine. The internal OpenAI-compatible translation endpoint is a **local llama.cpp service**, not a request to OpenAI.

The [model guide](docs/en/MODELS.md) documents exact settings, fixed revisions, checksums, and separate model licenses. Installation downloads about **4.58 GB** of model/runtime assets, plus Python packages, and creates an additional **344 MB** Chinese speed-repair model.

## Minimum Mac configuration

**Minimum recommended trial configuration: Apple M1, 16 GB unified memory, macOS 14.2+, and 20 GB free storage.** This is an engineering starting point, **not a machine configuration validated by this project**. The lowest configuration on which this complete system has actually been validated is **MacBook Air M4 / 24 GB / macOS 26**. Compatibility or successful model loading does not guarantee sustained real-time performance.

| Item | Minimum requirement / trial recommendation | Validated or recommended for regular use |
|---|---|---|
| Processor | Apple Silicon, M1 or later, native `arm64` | M4 was tested; other models need their own performance checks |
| Unified memory | 16 GB recommended for evaluation; 8 GB is unvalidated and not recommended | 24 GB or more; tested with 24 GB |
| macOS | 14.2+ for the complete feature set, based on API/package compatibility | macOS 26; documentation checked on 26.6.2 |
| Free storage | Reserve 20 GB for models, environments, downloads, and temporary files | Additional space for updates or local test recordings |
| Build tools | Compatible Xcode Command Line Tools, with an SDK exposing macOS 14.2 audio-tap APIs | Tested with Swift 6.3.3 and SDK 26.5 |
| Python | Installed automatically: native Python 3.12.14 | Use the repository's `.venv` |
| Network | Internet for installation; LAN for listening devices | Inference is local after installation |

Intel Macs and Rosetta/x86 Python are unsupported by this installer. macOS 14.0–14.1 cannot provide translation-only audio capture. Earlier M-series Macs, 16 GB configurations, and macOS 14/15 have **not** undergone the project's complete installation and long-duration validation. Test your actual workload before relying on an unvalidated configuration for a live event.

The App's deployment target alone is not the full system requirement. MLX and ONNX packages have their own platform requirements; the pinned MLX version publishes macOS 14, 15, and 26 wheels. See [compatibility evidence](docs/en/INSTALLATION.md#compatibility-evidence).

## Installation

See the [step-by-step guide](docs/en/INSTALLATION.md) for prerequisites, permissions, verification, updates, relocation, and recovery.

First install Apple's command-line tools and wait for installation to finish:

```sh
xcode-select --install
```

Clone into a permanent location, install, and open the App:

```sh
mkdir -p "$HOME/Projects"
cd "$HOME/Projects"
git clone https://github.com/hellcatjack/VoxHalo_mac.git
cd VoxHalo_mac
./setup.sh
open "$HOME/Applications/同声传译.app"
```

No Homebrew, Docker, separately installed Python, virtual sound card, paid API, or remote inference server is required. The installer creates local environments, installs pinned dependencies, verifies model SHA-256 values, repairs Chinese speed handling, and builds the App. It does not start recording.

**Keep the entire checkout at its installation path.** The App records that path and uses its `.venv`, `runtime`, and `models` directories. Copying only the `.app` to another Mac is insufficient. Builds use an ad-hoc local signature and are not Developer ID notarized. Distribution is source plus an installer, not a universal standalone DMG.

## Usage

1. Choose **输入来源** (input), **朗读输出** (output), and **识别 → 译音** (source → target) in the App.
2. Optionally enter a few ASR context terms, then select **开始传译** (start interpretation). Allow the requested macOS audio permissions.
3. Once capture is active, speak or play the source audio. **打开监控页** (open monitor) is optional.
4. **结束传译** (end interpretation) stops capture and finishes the remaining speech. **停止服务** (stop services) unloads models. **停止服务并退出** (stop services and quit) fully exits.

To hear only translated YouTube audio, choose **系统播放声音 · 只听译音**, select output, start interpretation, then play the video with the video's sound enabled. The App suppresses source playback during capture. Pause the video before ending interpretation. Capture covers other applications' system audio, not one Chrome tab; pause unrelated audio sources.

Use headphones with microphone input to reduce acoustic feedback. System-audio modes exclude this App's own speech. End the session before changing input, output, or direction. Closing the control window keeps interpretation running; the menu-bar icon reopens it.

Use **字幕设置…** (subtitle settings) to adjust the overlay. Local subtitles follow actual playback; newer translations do not replace a sentence still being spoken. With local playback disabled, the overlay displays completed translations without a local speech clock.

The monitor is at `http://127.0.0.1:8024`. LAN listeners use the App's address or QR code and press **Start Listening**. HLS phone playback can have additional buffering compared with native Mac playback.

## Maintenance and troubleshooting

From the repository root:

```sh
./macos.sh check
./macos.sh status
.venv/bin/python scripts/setup_assets.py --verify-only
```

Logs are in `VoxBridge/logs/`. The [installation guide](docs/en/INSTALLATION.md#troubleshooting) covers permissions, missing devices, failed downloads, occupied ports, moved installations, App launch issues, updates, and uninstallation.

## Limitations and validation

- Qwen uses bounded-window redecoding, approximately every two seconds, with source revisions and final checks. This is not upstream vLLM streaming or a native incremental KV-cache decoder.
- One active audio producer is supported. Stable short phrases balance speed and accuracy; recognition, translation, synthesis, and queueing all add delay.
- Homophones, mixed-language proper names, pronouns, and clause relationships can still be wrong. Church terminology prompts do not eliminate these errors.
- Append-only additions to already spoken text can be spoken separately; arbitrary corrections to a sentence already heard are not automatically replayed.
- LAN audio shares source order, but phones and the Mac are not sample-synchronized. iPhone background/lock-screen playback requires device-specific validation.

M4/24 GB validation includes a 600-second Chinese sermon segment and a 609.479-second English segment. Translation-to-first-PCM timing is **not** headset end-to-end latency. See the [historical validation](VoxBridge/docs/MACOS-TRANSLATION-INTEGRITY.md) and [source release checks](docs/PUBLICATION.md); those detailed records are in Chinese.

## Privacy and network access

Inference runs locally. Debug-file recording is disabled in the default profile; normal use does not intentionally save source recordings. Runtime logs and explicitly generated diagnostics can contain text or operational details. Device choices and subtitle appearance are stored in local macOS preferences.

The application listens on `0.0.0.0:8024`, with no web login enabled in the Mac profile. Devices that can reach it may view monitoring text and hear the LAN stream. Use a trusted network; do not expose this port through a public router. HY-MT binds to `127.0.0.1:8876`; native capture/control uses a separate local credential. Do not publish `VoxBridge/artifacts/macos-service/` or its token.

## Development and contributions

Open issues and pull requests at [hellcatjack/VoxHalo_mac](https://github.com/hellcatjack/VoxHalo_mac). Include App/macOS versions, chip/memory, input/output modes, direction, reproduction steps, and sanitized logs. For security issues or sensitive reports, email [hellcatjack@gmail.com](mailto:hellcatjack@gmail.com) instead of publicly posting credentials or private recordings.

```sh
# After installation, from the repository root:
cd VoxBridge
../.venv/bin/python -m pytest -q
cd ..
./build-app.sh --destination "$PWD/dist/同声传译.app"
```

Optional browser and ffprobe-dependent checks may skip when their tools are absent. Read [AGENTS.md](AGENTS.md), keep models/media/environments/runtime state out of Git, and maintain English and Chinese user documentation together.

```text
README.md / README.zh-CN.md      English / Chinese entry points
docs/en/ / docs/zh-CN/          Installation and model guides
setup.sh / build-app.sh         Local installation and App build
scripts/runtime-assets.json    Pinned download and checksum manifest
VoxBridge/deploy/macos/app/    Native App source
VoxBridge/voxbridge/           ASR, translation, TTS, and web services
VoxBridge/tests/               Python and Swift regression tests
models/ runtime/ .venv/        Generated resources, ignored by Git
```

## License and acknowledgments

Source code is licensed under [Apache-2.0](LICENSE). Model weights and third-party packages retain their own licenses. **HY-MT uses the Tencent HY Community License, not Apache-2.0**; its territory excludes the EU, UK, and South Korea and it includes further use/distribution conditions. Review the [pinned license](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/blob/265b2e615a7dc9b06c435dc878829ad99a512ba2/License.txt) before installing or deploying that model.

This independent project is maintained by hellcatjack and is not affiliated with, sponsored by, or endorsed by Tencent. Thanks to Qwen, Tencent Hunyuan, MLX, llama.cpp, Kokoro, sherpa-onnx, Silero VAD, and the dependencies in the [model/license guide](docs/en/MODELS.md#licenses-and-attribution).

The former remote subtitle client remains in Git history, tag `v1.0.0`, and branch `backup/pre-local-system-2026-09-14`. Current changes are summarized in [CHANGELOG.md](CHANGELOG.en.md).
