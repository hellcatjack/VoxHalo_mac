# Building the standalone macOS release

Build on an Apple Silicon Mac with Xcode Command Line Tools. Those tools are required only on the build machine. The downloadable App carries Python 3.12.14 and compiled service dependencies; first launch downloads the pinned models and two upstream audio wheels through the graphical installer.

The complete build is:

```sh
./scripts/bootstrap_release.sh
```

This bootstraps checksum-pinned uv 0.12.13 and managed Python, creates a fresh runtime, compiles the App in `dist/`, and packages it. It does not replace `/Applications/同声传译.app`.

To use an existing verified builder runtime:

```sh
.venv/bin/python scripts/build_desktop_release.py payload \
  --output dist/release-payload \
  --uv runtime/bin/uv \
  --python-home runtime/python/cpython-3.12.14-macos-aarch64-none \
  --cache-dir runtime/uv-cache \
  --keep-workspace

.venv/bin/python VoxBridge/tools/build_macos_app.py \
  --destination dist/同声传译.app \
  --release-payload dist/release-payload

.venv/bin/python scripts/build_desktop_release.py package \
  --app dist/同声传译.app \
  --output dist/release
```

`--keep-workspace` retains `dist/release-payload/workspace` for clean-install and offline model verification. Use a fresh output directory when retaining a second workspace. The source workspace's `.venv`, models, logs, recordings, service state, credentials, preferences, and editable package paths are never copied into the runtime.

## Runtime composition and checks

- Service dependencies are installed fresh from `scripts/release-runtime.lock`. This preserves the verified versions while excluding pytest and its test-only dependencies. MLX and MLX Metal use SHA256-pinned macOS 14 arm64 wheels even when building on macOS 26.
- ONNX graph repair uses a separate fresh `runtime/model-tools` environment from `scripts/model-tools.lock`.
- Python, `.venv`, the repair environment, and service imports use relative paths. Console activation scripts are excluded. The native App launches the included `.venv/bin/python` directly.
- The builder repairs the managed Python library's absolute install ID and drops unused vendor build search paths, then ad-hoc signs the changed staged libraries. Native binaries are audited for macOS 14.2 compatibility and external library references.
- Before packaging, the workspace is renamed to a path containing spaces. Import checks run with a temporary empty home directory, system-only executable search path, and offline model flags. They cover Qwen/MLX, GPU evaluation, ONNX Runtime, Kokoro, Japanese phonemization, audio modules, and the isolated repair environment. A second relocation check verifies the final bundled modules after removing the first-run downloads. Local builds require Metal. CI runners can explicitly use `payload --allow-no-metal` (or `VOXHALO_CI_ALLOW_NO_METAL=1 ./scripts/bootstrap_release.sh`): when Metal is absent, validation uses CPU and records `metal_available: false`, `mlx_evaluation: false`, `cpu_evaluation: true` in `validation.json`. This verifies portable imports only; actual GPU inference must still be checked on an Apple Silicon Mac before publication. The flag does not change the installed service's device selection.
- `imageio-ffmpeg` and `espeakng-loader` are installed for build validation, then removed from the runtime archive. First-run installation fetches the exact upstream wheels listed in `scripts/desktop-wheels.json`; the App does not redistribute those wheels or binaries.
- Python license text, dependency license files, the package inventory, FFmpeg build configuration, and the exact supplied model notices are retained in `licenses/`. Notices originate in the distributions and `scripts/licenses/`; review them before publication.

## Outputs

`dist/release-payload` contains `runtime.tar.gz`, `release.json`, `validation.json`, and `licenses/`. The App build hook copies the archive, release metadata, and licenses into its resources. Archive member names are relative and exclude a containing workspace directory.

Release metadata includes version/build, Python version, archive SHA256 and compressed size, total unpacked file bytes, model plus audio-wheel download bytes, the model and wheel manifest SHA256 values, architecture, and minimum macOS. The deterministic tar/gzip container normalizes archive ownership and timestamps; native builds and upstream package changes can still change its hash.

The package command checks the embedded runtime checksum, matching App version/build, and code signature before producing:

- `VoxHalo-1.8.0-macOS-arm64.zip`
- `VoxHalo-1.8.0-macOS-arm64.dmg`, with an Applications shortcut
- `SHA256SUMS.txt`

The command refuses to overwrite existing ZIP/DMG files and verifies the completed disk image. Ad-hoc signing is not Developer ID signing or notarization. Publication still requires the full service tests, installer failure tests, graphical first-run checks, clean installed model checks, and the release review described in the release plan.

## GitHub publication

The `Standalone Mac release` workflow builds on the standard Apple Silicon `macos-14` runner. Pushes to `release/**` build and test an artifact without publishing a Release. A `v1.8.*` tag additionally runs a separate publish job with repository-scoped `contents: write` permission. That job verifies `SHA256SUMS.txt` and uses the built-in `GITHUB_TOKEN` to create the GitHub Release; no maintainer token is embedded in the App or source.

Run `./scripts/bootstrap_release.sh` to reproduce the same build locally. The current workflow intentionally publishes an **ad-hoc signed, unnotarized** App. Do not label it notarized without a successful Developer ID signing and Apple notarization result. Publishing future versions also requires updating the fixed version/build, tag pattern and release notes path together.
