# VoxBridge local instructions

See [workspace instructions](../AGENTS.md) and [Mac guide](docs/MACOS.md).

- Python is fixed to `../.venv/bin/python` when working here. Do not use global Python.
- The application service must use port `8024`; internal HY-MT uses loopback `8876`.
- Start and stop using `./macos.sh`; the native App owns capture and local playback.
- Direction is selected before capture. `en2zh` forces English ASR and Chinese TTS; `zh2en` forces Chinese ASR and English TTS.
- Preserve the pinned Mac model settings and the independence of browser monitoring.
- Build verification bundles into the workspace `dist/` directory, not over an active App.
