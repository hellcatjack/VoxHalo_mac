# VoxBridge local instructions

See [workspace instructions](../AGENTS.md) and [Mac guide](docs/MACOS.md).

- Python is fixed to `../.venv/bin/python` when working here. Do not use global Python.
- The application service must use port `8024`; internal HY-MT uses loopback `8876`.
- Start and stop using `./macos.sh`; the native App owns capture and local playback.
- Source/target are selected before capture from the shared eight-language catalog. The canonical pair forces source ASR and target TTS; preserve the verified `zh2en` and `en2zh` behavior.
- Preserve the pinned Mac model settings and the independence of browser monitoring.
- Build verification bundles into the workspace `dist/` directory, not over an active App.
