# 模型、运行配置与许可证

[English](../en/MODELS.md) | **简体中文** · [项目首页](../../README.zh-CN.md) · [安装指南](INSTALLATION.md)

本文对应 App 1.5.1/build 16。实际配置以 [macos_service.py](../../VoxBridge/tools/macos_service.py)、[MLX 适配器](../../VoxBridge/voxbridge/asr/mlx_backend.py)和[资源清单](../../scripts/runtime-assets.json)为准。这里介绍本项目的实现，不代表上游模型系列的所有功能。

## 1. Qwen3-ASR 0.6B：语音识别

- **来源：**[Qwen/Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)，Qwen3-ASR 系列中命名为 0.6B 的较小型号；当前系统不使用 1.7B 型号。
- **运行时：**MLX 0.32.2、mlx-metal 0.32.2 和 [mlx-qwen3-asr 0.4.0](https://github.com/moona3k/mlx-qwen3-asr)，通过 Metal 使用 Apple GPU。
- **精度：**先以 FP16 dtype 加载本地原始检查点，再由 MLX 将适用权重量化为 8 bit，group size 为 64。激活及未量化层仍为浮点。下载的约 1.88 GB 检查点不是预先压好的 INT8 文件，启动转换和临时分配也需要内存。
- **输入：**16 kHz 单声道音频；原生客户端每 100 ms 发送一帧，约两秒触发一次识别。默认采用 12 秒边界阈值、0.8 秒候选静音和 0.32 秒重叠，并保留未完句保护及最终重解码。
- **流式方式：**有界窗口重复解码与原文修订；不宣称使用上游 vLLM 流式实现或完整增量 KV 缓存。原文提交前可能发生变化。
- **语言：**中译英使用中文 ASR，英译中使用英文 ASR。模型系列支持更多语言，但 App 当前只提供这两个方向。
- **提示词：**可填少量名称／专业术语；原生界面最多接受 24 项以空白分隔的词条，合计 160 字符。这些词条不替代独立翻译策略，也不保证识别正确。

[官方模型卡](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)说明模型系列与 Apache-2.0 许可。中英混说、专名、口音和噪声仍需用实际场景评估。

## 2. HY-MT1.5-1.8B：文本翻译

[腾讯 HY-MT1.5-1.8B](https://huggingface.co/tencent/HY-MT1.5-1.8B)是 18 亿参数翻译模型。本安装使用[官方 Q8_0 GGUF](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF)，约 1.91 GB，由本地 llama.cpp b10809 提供服务。

| 设置 | 本版本取值 |
|---|---|
| 接口 | `http://127.0.0.1:8876`，OpenAI 兼容 API，模型别名 `hy-mt` |
| GPU | `--gpu-layers 99`，Metal，开启 flash attention |
| 上下文／并行 | 4,096 token；一个并行请求；CPU 与 batch 各两线程 |
| 提示缓存 | `cache_prompt=false`；服务端 `--cache-ram 0` |
| 生成参数 | `temperature=0`、`top_p=0.6`、`top_k=20` |
| 重复惩罚 | `repeat_penalty=1.05`、`repeat_last_n=64` |
| 输出预算 | 通常 256 token；有界恢复可提高到 512 |
| 请求处理 | 超时 30 秒；一个翻译工作线程 |

`mac-verified` 配置使用温度 **0**，与上游示例建议的 0.7 不同；安装时保留本机已经测试的配置。无需 OpenAI API 密钥，全部请求发往本地服务器。

### 翻译策略

- 忠实于演讲者的实际原文，只输出译文本身。
- 中译英在适用时采用项目内教会／ESV 术语策略；英译中使用通行的中文圣经译名和教会术语。
- 不根据记忆重构经文、补齐段落、修正引文或增加神学解释。
- 有界术语表命中实际原文时，按原文出现顺序给出术语，配合简短翻译模板；无命中时使用普通教会提示词。
- 检测规则说明式输出、异常扩张和未完成输出，进行有界重试；恢复时使用不带术语提示的简短模板，失败结果不进入语音合成。

提示词构造见 [demo_streaming_ws.py](../../VoxBridge/voxbridge/cli/demo_streaming_ws.py)，术语与恢复逻辑见 [church_terms.py](../../VoxBridge/voxbridge/streaming/church_terms.py) 和 [translation_quality.py](../../VoxBridge/voxbridge/streaming/translation_quality.py)。[上游提示词示例](https://huggingface.co/tencent/HY-MT1.5-1.8B#prompts)是参考，不表示本项目采用上游所有默认值。普通语义误译仍可能发生。

## 3. Kokoro：译文朗读

Kokoro 是小型神经 TTS 模型，不承担文本翻译。两个约 8,200 万参数型号均使用 `kokoro-onnx 0.5.0`、ONNX Runtime 1.30.0、两个 CPU 线程、基础速度 1.05 和 Auto 追赶，让 GPU 优先处理识别和翻译。

| 输出语言 | 模型 | 音色 | 切分方式 |
|---|---|---|---|
| 英文 | Kokoro v1.0 ONNX | `am_michael` | 既有自然语句分块 |
| 中文 | Kokoro v1.1-zh ONNX，修复语速输入 | `zm_029` 男声 | 优先完整句子，超长文本按合成容量分批 |

本机通过 AVAudioEngine 播放 PCM；局域网通过 AAC/HLS 共享已生成语音。字幕跟随本机实际输出音频，而非译文到达时间。本机原生播放与局域网 HLS 可以具有不同缓冲延迟。

### 中文语速修复如何复现

原来验证过的中文模型将 `speed` 声明为 INT32，固定调用路径会截断小数语速。[repair_kokoro_speed.py](../../VoxBridge/tools/repair_kokoro_speed.py)只把该输入声明改为 FLOAT，验证其余序列化图保持原样，并另存文件；适配器传入 float32 语速。原模型与男声音色保留。

上游发行附件后来发生变化，因此清单固定使用一个[历史镜像](https://huggingface.co/leonelhs/kokoro-thewh1teagle/blob/463d2d58c267a5c58b8989a73d171e153c50be20/kokoro-v1.1-zh.onnx)，其内容与此前已验证文件逐字节一致，不使用该镜像的其他代码或模型。

| 文件 | SHA-256 |
|---|---|
| 原始 `kokoro-v1.1-zh.onnx` | `eefec708cbc7aba8e8129b5c2f7cb92e1fe7d281af1e1dd451592d9ff0714a0d` |
| 生成的 `kokoro-v1.1-zh-float-speed.onnx` | `047e20ff94e676c7ed62b6f68778acc63a4922c194fe62c8708402b46da633d6` |

修复工具在独立的 `runtime/model-tools` 环境运行，由 [model-tools.lock](../../scripts/model-tools.lock)固定版本，不升级语音服务的依赖。

## 4. VAD 与资源分配

Silero VAD ONNX 在 CPU 上运行，辅助语音活动、静音处理与边界保护，不是另一个识别或翻译模型。Mac 路径使用 NumPy／ONNX Runtime，无需 PyTorch、CUDA、ROCm 或 vLLM。

识别与翻译共享 GPU 锁，避免同时进行重负载 GPU 推理；音频接收独立继续。16 GB 试用建议属于内存预算估算，不是实测最低值。[历史测试](../../VoxBridge/docs/MACOS-LOW-LATENCY-VERIFICATION.md)曾记录识别／翻译进程合计 RSS 约 3.32 GiB，但它不包含全部共享／GPU 分配，更不代表整机占用。macOS、浏览器、合成、加载模型和临时缓冲还需额外内存。目前只有 M4／24 GB 完成整套验证，见 [Mac 配置要求](../../README.zh-CN.md#最低-mac-配置)。

## 5. 固定资源与离线运行

以下为清单统计的十进制下载大小，经过四舍五入，不是运行内存需求。

| 资源组 | 下载量 | 固定来源 |
|---|---:|---|
| Qwen 权重、配置与分词器 | 1.881 GB | Qwen 提交 `5eb144179a02acc5e5ba31e748d22b0cf3e303b0` |
| HY-MT GGUF 与许可证 | 1.909 GB | 腾讯提交 `265b2e615a7dc9b06c435dc878829ad99a512ba2` |
| Kokoro 模型、音色与中文配置 | 751 MB | 固定 release／校验值；中文镜像 `463d2d58c267a5c58b8989a73d171e153c50be20`；词表 `01e7505bd6a7a2ac4975463114c3a7650a9f7218` |
| Silero VAD | 0.644 MB | sherpa-onnx 发行附件，固定 SHA-256 |
| llama.cpp 压缩包 | 11.1 MB | 官方 `b10809` macOS arm64 发行包 |

安装器还会下载 uv 0.12.13、托管 Python 3.12.14 和[固定服务依赖](../../VoxBridge/deploy/macos/requirements.lock)。中文修复模型额外占约 344 MB，完整安装及临时空间建议预留 20 GB。

[机器可读清单](../../scripts/runtime-assets.json)列出每个 URL、字节大小和 SHA-256。校验不符的下载不会作为有效资源安装；不匹配的现有文件会保留并报错。验证方法：

```sh
# 在仓库根目录执行
.venv/bin/python scripts/setup_assets.py --verify-only
```

运行时设置 `HF_HUB_OFFLINE=1` 和 `TRANSFORMERS_OFFLINE=1`。安装后从本地文件推理，缺资源时报错，不回退到云模型。播放在线视频本身仍需要互联网。

## 许可证与署名

源码的 [Apache-2.0 许可证](../../LICENSE)不替代模型和依赖的许可证。

| 组件 | 许可证／官方来源 |
|---|---|
| Qwen3-ASR 权重 | [Apache-2.0，Qwen 模型卡](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) |
| HY-MT 权重 | [Tencent HY Community License](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/blob/265b2e615a7dc9b06c435dc878829ad99a512ba2/License.txt) |
| Kokoro 权重 | Apache-2.0：[英文](https://huggingface.co/hexgrad/Kokoro-82M)／[中文](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh) |
| MLX／llama.cpp／ONNX Runtime | MIT：[MLX](https://github.com/ml-explore/mlx)、[llama.cpp](https://github.com/ggml-org/llama.cpp)、[ONNX Runtime](https://github.com/microsoft/onnxruntime) |
| MLX ASR 适配／Kokoro 适配 | [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr)／[kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx)，保留安装包各自许可 |
| VAD／sherpa-onnx | [Silero VAD](https://github.com/snakers4/silero-vad)／[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)，保留上游许可 |
| hls.js | Apache-2.0，随代码保留[来源声明](../../VoxBridge/voxbridge/tts/vendor/README.txt)和[许可](../../VoxBridge/voxbridge/tts/vendor/hls.LICENSE.txt) |
| FFmpeg、eSpeak NG、Misaki、uv、Python | 遵循各发行包许可和第三方声明，不因本仓库发布而更改 |

HY-MT 公布的许可适用地域不包含欧盟、英国和韩国，并包含使用、署名、再分发等条件。安装器保留 `models/translation-experiments/gguf/License.txt`，使用前应阅读完整协议。本项目由 hellcatjack 独立维护，与腾讯没有关联、赞助或背书关系。对外提供服务的部署者应按模型协议披露其实际服务提供者。

不能因为本仓库源码采用开源许可证，就推断所有下载权重均没有使用限制。模型文件和测试录音不提交到 Git。
