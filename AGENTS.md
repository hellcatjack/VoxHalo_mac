# Project instructions

- This is the complete Apple Silicon local installation. The service package lives in `VoxBridge/`; the Python environment lives at the repository root in `.venv/`.
- Use `.venv/bin/python` from the root, or `../.venv/bin/python` from `VoxBridge/`. Do not fall back to global Python. Bootstrap with `./setup.sh` when needed.
- The application service port is **8024**. HY-MT listens on loopback port **8876**. Do not change these without the user's instruction.
- Preserve the verified Qwen3-ASR 0.6B MLX INT8 / HY-MT Q8_0 / Kokoro settings unless explicitly working on that behavior.
- Capture and local playback belong to the native App. Browser monitoring must not own or interrupt business state. Subtitle styling must not change TTS output or scheduling.
- Never commit model files, downloaded media, `.venv`, `runtime`, credentials, preferences, logs or generated artifacts. Runtime assets belong in the checksum manifest, not Git.
- Run relevant tests from `VoxBridge/`; run the full suite before release. Build Apps into `dist/` for verification so the running installation is not overwritten.
- Publishing identity: `hellcatjack <hellcatjack@gmail.com>`. Configure this locally to the repository, not globally.
