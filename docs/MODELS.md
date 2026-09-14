# 模型与依赖

[English guide](en/MODELS.md) | [完整中文指南](zh-CN/MODELS.md)

本页保留资源来源与校验记录。模型原理、配置、提示词及许可说明请使用上方对应语言的完整指南。

所有必需资源列在 [`scripts/runtime-assets.json`](../scripts/runtime-assets.json)，记录下载地址、大小和 SHA-256。下载文件约 4.6 GB；解压、Python 依赖、模型修复和安装缓存需要额外空间。权重不提交到 Git。

| 资源 | 固定来源 |
|---|---|
| Qwen3-ASR 0.6B | [Qwen 官方模型](https://huggingface.co/Qwen/Qwen3-ASR-0.6B/tree/5eb144179a02acc5e5ba31e748d22b0cf3e303b0)，提交 `5eb144179a02acc5e5ba31e748d22b0cf3e303b0` |
| HY-MT1.5-1.8B Q8_0 | [腾讯官方 GGUF](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/tree/265b2e615a7dc9b06c435dc878829ad99a512ba2)，提交 `265b2e615a7dc9b06c435dc878829ad99a512ba2` |
| llama.cpp | [b10809 官方发行包](https://github.com/ggml-org/llama.cpp/releases/tag/b10809)，macOS arm64 |
| Silero VAD | [sherpa-onnx 官方模型附件](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models)，固定文件校验值 |
| 英文 Kokoro | [kokoro-onnx model-files-v1.0](https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.0) 的模型与音色 |
| 中文 Kokoro 音色 | [kokoro-onnx model-files-v1.1](https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.1) 的 `voices-v1.1-zh.bin` |
| 中文词表配置 | [hexgrad 官方模型](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh/tree/01e7505bd6a7a2ac4975463114c3a7650a9f7218)，提交 `01e7505bd6a7a2ac4975463114c3a7650a9f7218` |
| Python 环境管理 | [uv 0.12.13](https://github.com/astral-sh/uv/releases/tag/0.12.13)，安装脚本固定压缩包 SHA-256 |

## 保留已验证的中文 TTS

原来验证的 `kokoro-v1.1-zh.onnx` 为 343,605,188 字节，SHA-256：

```text
eefec708cbc7aba8e8129b5c2f7cb92e1fe7d281af1e1dd451592d9ff0714a0d
```

上游相同发行附件现已更换为不同文件。安装器因此使用 [leonelhs 保存的历史副本](https://huggingface.co/leonelhs/kokoro-thewh1teagle/blob/463d2d58c267a5c58b8989a73d171e153c50be20/kokoro-v1.1-zh.onnx)，固定提交 `463d2d58c267a5c58b8989a73d171e153c50be20`。该副本是第三方镜像；我们按本机已验证原文件的校验值验证内容一致性，不使用镜像中的其他代码或模型。

安装后在 `runtime/model-tools` 隔离环境运行已有的 [repair_kokoro_speed.py](../VoxBridge/tools/repair_kokoro_speed.py)，仅把 `speed` 输入从 INT32 改为 FLOAT，保留所有权重与节点。输出另存为 `kokoro-v1.1-zh-float-speed.onnx`，校验值必须为：

```text
047e20ff94e676c7ed62b6f68778acc63a4922c194fe62c8708402b46da633d6
```

中文继续使用 `zm_029` 男声、整句优先合成和既有 Auto 语速。原模型保持原样；详情见[修复验证](../VoxBridge/docs/MACOS-CHINESE-TTS-SPEED-VERIFICATION.md)。

## Python 与离线运行

服务环境使用 [`requirements.lock`](../VoxBridge/deploy/macos/requirements.lock) 中本机验证过的版本。ONNX 图修复工具使用单独的 [`model-tools.lock`](../scripts/model-tools.lock)，不升级服务的运行依赖。FFmpeg 和发音资源由固定 Python 包提供。

首次安装需要访问 GitHub、Hugging Face 和 Python 包索引。安装就绪后，服务设置 `HF_HUB_OFFLINE=1` 和 `TRANSFORMERS_OFFLINE=1`，模型推理无需互联网，不回退到云模型。播放在线视频本身仍需要网络。

可在根目录只读校验所有模型与下载包：

```sh
.venv/bin/python scripts/setup_assets.py --verify-only
```

下载或现有文件校验失败时安装停止，不静默换用另一个版本。更换模型应作为单独的质量与性能验证任务。
