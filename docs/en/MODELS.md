# Models, runtime settings, and licenses

**English** | [简体中文](../zh-CN/MODELS.md) · [Project README](../../README.md) · [Installation](INSTALLATION.md)

This document describes App 1.5.2/build 17. The authoritative settings are in [macos_service.py](../../VoxBridge/tools/macos_service.py), the [MLX adapter](../../VoxBridge/voxbridge/asr/mlx_backend.py), and the [asset manifest](../../scripts/runtime-assets.json). It describes this implementation, not every capability advertised by the upstream model families.

## 1. Qwen3-ASR 0.6B: speech recognition

- **Source:** [Qwen/Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B), the smaller 0.6B-named variant of the Qwen3-ASR family. The installed system does not use the 1.7B variant.
- **Runtime:** MLX 0.32.2, mlx-metal 0.32.2, and [mlx-qwen3-asr 0.4.0](https://github.com/moona3k/mlx-qwen3-asr), using the Apple GPU through Metal.
- **Precision:** the original local checkpoint is loaded with FP16 dtype, then MLX quantizes eligible weights to 8 bits with group size 64. Activations and unquantized layers remain floating point. The approximately 1.88 GB downloaded checkpoint is not an already packed INT8 file; startup conversion and temporary allocations also require memory.
- **Input:** mono 16 kHz audio. The native client sends 100 ms frames; recognition is triggered at approximately 2-second intervals. The default boundary policy uses a 12-second threshold, 0.8-second candidate silence, and 0.32-second overlap, with protection for incomplete phrases and final redecoding.
- **Streaming:** bounded-window repeated decoding plus source revisions; no claim of upstream vLLM streaming or fully incremental KV-cache reuse. Initial text can change before it is committed.
- **Language:** Chinese ASR for Chinese → English; English ASR for English → Chinese. The model family supports additional languages, but this App exposes only these two directions.
- **Context:** optional ASR terms help names and specialist vocabulary; the native UI accepts at most 24 whitespace-separated entries, 160 characters combined. These terms do not replace the separate translation policy or guarantee correct recognition.

The [upstream model card](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) documents the model family and Apache-2.0 license. Mixed-language speech, names, accents, and noise still need workload-specific evaluation.

## 2. HY-MT1.5-1.8B: text translation

[Tencent HY-MT1.5-1.8B](https://huggingface.co/tencent/HY-MT1.5-1.8B) is a 1.8-billion-parameter translation model. This installation uses the [official Q8_0 GGUF](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF), approximately 1.91 GB, served locally by llama.cpp b10809.

| Setting | Value |
|---|---|
| Endpoint | `http://127.0.0.1:8876`, OpenAI-compatible API, model alias `hy-mt` |
| GPU offload | `--gpu-layers 99`, Metal; flash attention enabled |
| Context / concurrency | 4,096 tokens; one parallel request; two CPU/batch threads |
| Prompt cache | `cache_prompt=false`; server `--cache-ram 0` |
| Generation | `temperature=0`, `top_p=0.6`, `top_k=20` |
| Repetition settings | `repeat_penalty=1.05`, `repeat_last_n=64` |
| Output budget | Normally 256 tokens; bounded recovery can raise the budget to 512 |
| Request handling | 30-second timeout; one translation worker |

The `mac-verified` profile deliberately uses temperature **0**, while the upstream example recommends 0.7. Installation preserves the locally tested profile. An OpenAI API key is not needed; all requests go to the local server.

### Translation policy

- Preserve what the speaker actually said and return translated text without explanation.
- Chinese → English uses the project's church/ESV terminology policy when appropriate; English → Chinese favors conventional Chinese Bible names and church terminology.
- Do not reconstruct scripture, fill missing passages, correct quotations from memory, or add theological explanations.
- When a bounded glossary matches actual source terms, provide terms in source order with the short translation template. The normal church policy is used when there is no glossary match.
- Detect policy-like output, abnormal expansion, and unfinished output. A bounded retry uses the short template without glossary hints; failed output is not sent to speech synthesis.

Prompt construction is in [prompts.py](../../VoxBridge/voxbridge/translation/prompts.py); terminology and recovery logic are in [church_terms.py](../../VoxBridge/voxbridge/streaming/church_terms.py) and [translation_quality.py](../../VoxBridge/voxbridge/streaming/translation_quality.py). The upstream [prompt examples](https://huggingface.co/tencent/HY-MT1.5-1.8B#prompts) are references, not a claim that this App uses every upstream default. HY-MT remains capable of ordinary translation errors.

## 3. Kokoro: translated speech

Kokoro is a compact neural TTS model, not the translation language model. Both approximately 82M-parameter versions use `kokoro-onnx 0.5.0`, ONNX Runtime 1.30.0, two CPU threads, and a base speed of 1.05 with automatic catch-up. CPU synthesis leaves GPU capacity for ASR and translation.

| Output | Model | Voice | Segmentation |
|---|---|---|---|
| English | Kokoro v1.0 ONNX | `am_michael` | Existing natural speech chunks |
| Chinese | Kokoro v1.1-zh ONNX, repaired speed input | `zm_029`, male | Prefer complete sentences; unusually long text is split within synthesis limits |

Local output uses AVAudioEngine PCM playback. The LAN path shares generated speech through AAC/HLS. Subtitles follow local rendered audio rather than the arrival time of a translation. Native playback and LAN HLS can have different buffering delays.

### Reproducing the Chinese speed fix

The original validated Chinese model declares `speed` as INT32. The pinned call path truncated fractional speeds. [repair_kokoro_speed.py](../../VoxBridge/tools/repair_kokoro_speed.py) changes that one graph input declaration to FLOAT, verifies that the rest of the serialized graph is unchanged, and writes a separate file. A narrow adapter supplies float32 speed values. The original model and voice are retained.

The upstream release attachment has since changed. To reproduce the tested model, the manifest pins a [historical mirror](https://huggingface.co/leonelhs/kokoro-thewh1teagle/blob/463d2d58c267a5c58b8989a73d171e153c50be20/kokoro-v1.1-zh.onnx), whose bytes match the previously validated file. No other code or model is taken from that mirror.

| File | SHA-256 |
|---|---|
| Original `kokoro-v1.1-zh.onnx` | `eefec708cbc7aba8e8129b5c2f7cb92e1fe7d281af1e1dd451592d9ff0714a0d` |
| Generated `kokoro-v1.1-zh-float-speed.onnx` | `047e20ff94e676c7ed62b6f68778acc63a4922c194fe62c8708402b46da633d6` |

Repair tooling lives separately in `runtime/model-tools`, pinned by [model-tools.lock](../../scripts/model-tools.lock). It does not upgrade the speech-service packages.

## 4. VAD and resource use

Silero VAD ONNX runs on CPU and assists voice activity, silence handling, and boundary protection. It is not another transcription or translation model. The Mac path uses NumPy/ONNX Runtime and does not require PyTorch, CUDA, ROCm, or vLLM.

ASR and translation share a GPU lock to avoid simultaneous heavy GPU work; audio reception continues independently. The 16 GB trial recommendation is a memory-budget estimate, not a measured minimum. A [historical test](../../VoxBridge/docs/MACOS-LOW-LATENCY-VERIFICATION.md) recorded approximately 3.32 GiB combined ASR/translation process RSS, which excludes some shared/GPU allocations and does not represent the whole system. macOS, the browser, synthesis, model loading, and temporary buffers need additional memory. Only M4/24 GB has complete local validation; see [Mac requirements](../../README.md#minimum-mac-configuration).

## 5. Fixed assets and offline operation

Sizes below are decimal download sizes rounded from the manifest. They are not runtime RAM requirements.

| Group | Download | Fixed source |
|---|---:|---|
| Qwen checkpoint/config/tokenizer | 1.881 GB | Qwen revision `5eb144179a02acc5e5ba31e748d22b0cf3e303b0` |
| HY-MT GGUF and license | 1.909 GB | Tencent revision `265b2e615a7dc9b06c435dc878829ad99a512ba2` |
| Kokoro models, voices, Chinese config | 751 MB | Pinned releases/checksums; Chinese mirror `463d2d58c267a5c58b8989a73d171e153c50be20`; config `01e7505bd6a7a2ac4975463114c3a7650a9f7218` |
| Silero VAD | 0.644 MB | sherpa-onnx release asset, fixed SHA-256 |
| llama.cpp archive | 11.1 MB | Official `b10809` macOS arm64 release |

The installer additionally obtains uv 0.12.13, managed Python 3.12.14, and [pinned service packages](../../VoxBridge/deploy/macos/requirements.lock). The Chinese repaired model adds approximately 344 MB on disk. Reserve 20 GB for the full installation and temporary space.

The [machine-readable manifest](../../scripts/runtime-assets.json) lists every URL, byte size, and SHA-256. Downloads with mismatching checksums are not promoted to installed assets. Existing mismatching files are kept and reported. Verification:

```sh
# From the repository root
.venv/bin/python scripts/setup_assets.py --verify-only
```

Runtime sets `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`. Inference uses local files after setup; missing assets cause an error instead of a cloud fallback. Watching an online source video still needs internet access.

## Licenses and attribution

The source code's [Apache-2.0 license](../../LICENSE) does not replace model or dependency licenses.

| Component | License / authoritative source |
|---|---|
| Qwen3-ASR weights | [Apache-2.0, Qwen model card](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) |
| HY-MT weights | [Tencent HY Community License](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/blob/265b2e615a7dc9b06c435dc878829ad99a512ba2/License.txt) |
| Kokoro weights | [Apache-2.0, English](https://huggingface.co/hexgrad/Kokoro-82M) / [Chinese](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh) |
| MLX / llama.cpp / ONNX Runtime | MIT; [MLX](https://github.com/ml-explore/mlx), [llama.cpp](https://github.com/ggml-org/llama.cpp), [ONNX Runtime](https://github.com/microsoft/onnxruntime) |
| MLX ASR adapter / Kokoro adapter | [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr) / [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx); retain their package licenses |
| VAD / sherpa-onnx | [Silero VAD](https://github.com/snakers4/silero-vad) / [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx); retain upstream licenses |
| hls.js | Apache-2.0; bundled [notice](../../VoxBridge/voxbridge/tts/vendor/README.txt) and [license](../../VoxBridge/voxbridge/tts/vendor/hls.LICENSE.txt) |
| FFmpeg, eSpeak NG, Misaki, uv, Python | Separate package licenses and bundled third-party notices apply; these are not relicensed by this repository |

HY-MT's published license limits its territory to locations outside the EU, UK, and South Korea and includes use, attribution, redistribution, and other conditions. The installer retains `models/translation-experiments/gguf/License.txt`; read the complete agreement before use. This is an independently maintained project by hellcatjack, with no Tencent affiliation, sponsorship, or endorsement. Deployers providing a service must identify their own actual service provider as required by the model terms.

Do not infer that all downloaded weights are unrestricted open-source assets from this repository's code license. Model files and test recordings are not committed to Git.
