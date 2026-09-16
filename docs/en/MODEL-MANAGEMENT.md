# Model files and download management

[简体中文](../zh-CN/MODEL-MANAGEMENT.md) · [README](../../README.md)

This feature is available in the current source and local update. The existing 1.8.0 download does not include this window.

Choose **Model Manager** in the main App or menu bar. The first-run installer also offers **View model files**; until initial installation finishes, downloads remain controlled by the installer.

## Files and storage

The window lists Qwen3-ASR 0.6B, HY-MT1.5 1.8B Q8_0, multilingual and Chinese Kokoro models, voices, tokenizer/configuration files, and Silero VAD. The current manifest contains 18 model and supporting files, occupying approximately **4.88 GB** after completion, including the generated Chinese speed-control model and excluding the Python runtime.

Each row shows its model, filename, stored bytes, expected size and status. Select a file to inspect its actual location, pinned download URL and SHA-256. You can reveal it in Finder or open its download source.

- Release installations normally use `~/Library/Application Support/VoxHalo/assets/models/`.
- Source installations use `models/` in the current service project's parent directory. The window resolves the actual location; it does not migrate existing models.
- Qwen weights keep their downloaded precision on disk; inference still uses the verified MLX INT8 setting. Chinese `kokoro-v1.1-zh-float-speed.onnx` is generated locally from the verified original model, and the restored result must match its established SHA-256.

## Check and recover

| Status / action | Meaning |
|---|---|
| Saved, not verified | File exists with the expected size; a full checksum has not yet been checked |
| Verified | Contents match the manifest SHA-256; changing the file invalidates this result |
| Missing | File is absent and can be downloaded again |
| Partial, can resume | A `.part` download remains and can be resumed |
| Damaged, repair available | Size or checksum differs; repair preserves a named backup first |
| Cannot access | Resolve the permissions, link or file-type issue first |
| Refresh status | Check local files again; the open window also refreshes automatically |
| Verify integrity | Read and checksum files in the background without downloading |

If you accidentally delete a model, end interpretation and **Stop services**. Open Model Manager, select the missing file, and click **Download / repair selected file**. Alternatively, **Download / repair all models** keeps valid files and restores missing or damaged models. You do not need to delete other models or reinstall the App.

Downloads show the current filename, completed bytes, total bytes and percentage. **Pause download** keeps completed and partial files. Click the download action again to resume; servers that do not support ranges restart that partial file. Closing the manager window keeps downloading. Quitting the App stops downloads and retains progress.

You can inspect files while services run. Downloads and repairs require stopped services and exclude service startup and desktop bootstrap. Open **Download details** for errors, then retry after restoring the connection or freeing sufficient space. Internet is needed for downloading; installed recognition, translation, speech and subtitles continue to run locally.
