# Qwen3-ASR / Zipformer XL 双引擎集成验证

日期：2026-09-12。主机：`上游 Linux 主机`。项目：`/data/Qwen3-ASR/VoxBridge`。

## 结论与范围

已实现采集前手动选择 Qwen3-ASR 或中文 Streaming Zipformer XL。Qwen 仍是新浏览器默认值；每个 WebSocket 有独立识别状态，同一引擎共享模型及推理锁，两个引擎不共享解码状态。XL 按需加载，成功后常驻。

本次没有修改 HY 提示词、英文长度策略、Kokoro 音色、HLS/Listen 实现或 Auto 阈值。XL 采用 sherpa-onnx 原生逐块输入，不重复识别整段、不调用 Qwen 最终重解码、不注入 Qwen overlap/context。分段仍由现有后端 VAD 负责，Sherpa 自带 endpoint detection 关闭。结束时最多补 0.8 秒零样本作为模型右上下文，只解码一次；这不是等待 0.8 秒的定时器。

## 配置与环境保护

| 项目 | 值 |
| --- | --- |
| Python | `/data/Qwen3-ASR/.venv/bin/python` |
| 模型 | `sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30` |
| Sherpa / core | 均为 `1.12.40` |
| 推理 | CPU INT8，2 线程，modified beam search，4 active paths |
| PCM | 单声道、16 kHz、PCM16 传输 |
| 会话处理参数 | chunk 0.6 秒、VAD 0.7 秒、最小切段 3.5 秒、硬切段 45 秒 |
| 无标点前缀 | 约 32 个汉字，结合时间/多次解码稳定性与后文保护 |
| 热词 | 本阶段未启用；页面 Context 只作用于 Qwen |

通过 `pip --no-deps` 只增加 Sherpa 两个固定版本包；安装前后核对，下列版本未变：

- Torch `2.9.1+rocm7.12.0a20260208`。
- torchaudio `2.9.0+rocm7.12.0a20260208`。
- vLLM `0.14.0+rocm700`。
- Triton `3.4.0+rocm7.12.0a20260209`。
- qwen-asr `0.0.6`、numpy `2.2.6`。

四个权重从已有基准目录复制到 `/data/Qwen3-ASR/models/` 的上述模型目录，SHA-256 全部一致，没有改写原有基准或用户视频。

| 文件 | SHA-256 |
| --- | --- |
| encoder.int8.onnx | `f2c543a0330e1ed0bd09c82e4ae7d3f1cbee10a15feca638fcc4f88083a36b8a` |
| decoder.onnx | `8f9c903da2818f207304a3f30b9eeb30028e30398f333c1e95e12c97704173e6` |
| joiner.int8.onnx | `f76ffce14b6ef80098cfdbce8846896ff68133970abc314eafab632f910df0d7` |
| tokens.txt | `6722bd1585f46f84456b29c3550a343a3cc375b971645773c02ed8e0b4e2405c` |

## 验证方法

使用用户提供的 `20260906_活出喜樂的生活_1080p.mp4` 已提取的 16 kHz WAV：

```text
/data/Qwen3-ASR/benchmarks/2026-09-12-zipformer-20260906/original-video-16k.wav
SHA-256: 9fedcc13df3d85da9c60896cfec0498c8df977dba0c021c89e455b9801aa9fc3
```

`tools/benchmark_dual_asr.py` 在进程内运行真实 FastAPI WebSocket 路由和真实 XL 模型。Qwen 用会在误调用时抛错的占位对象替代，避免再加载一份 GPU 模型。测试不开放额外服务端口，不向现场听众广播测试音频。

两种输入方式分别测量：不节流输入用于观察计算吞吐；1× 真实时间输入用单调时钟绝对期限发送 200 ms PCM 块，避免每次解码后累计 sleep 误差。暂停/恢复样本由原视频第 60–72 秒、8 秒人工静音、第 420–432 秒拼接而成，共 32 秒。

## AMD 实测结果

| 测试 | 首个 partial | 首个稳定提交 | 解码总耗时 / RTF | 结束后收尾 |
| --- | --- | --- | --- | --- |
| 30 秒，不节流（60–90 秒片段） | 不作为实时延迟依据 | 不作为实时延迟依据 | 3.783 秒 / 0.126 | 不作为实时收尾依据 |
| 60 秒，1×（60–120 秒片段） | 0.851 秒 | 10.447 秒 | 9.098 秒 / 0.152 | 0.156 秒 |
| 32 秒，1×，含 8 秒静音 | 0.851 秒 | 10.451 秒 | 3.873 秒 / 0.121 | 0.144 秒 |

第一行相当于约 7.9 倍计算吞吐，第二行约 6.6 倍；这不是端到端字幕或朗读延迟的倍数保证。解码 RTF 为适配器输入/解码/收尾调用累计墙钟时间除以输入音频时长，不含模型加载、稳定等待、HY、TTS 或网络。

首次模型加载分别约 1.690、1.643、1.722 秒。独立测试进程峰值 RSS 约 1.05–1.06 GiB，包含 Python/Web 应用及模型，不能当作生产服务净增内存的精确值。

首个 partial/稳定提交均从开始发送音频计时，不从检测到第一个发音计时。0.85 秒是可变识别文字首次出现，**不意味着 0.85 秒即可播出译音**。本片段首个稳定提交约 10.45 秒，包含无标点前缀积累及稳定保护；随后 60 秒测试共提交 7 个单元，未等到硬切段才全部输出。

“结束后收尾”从最后一块音频发送结束到收到 final，不含用户按下 Stop 的 UI 时间。完整字幕应看 `committed_text`；有 VAD 轮转时 `final.text` 仅代表最后一个识别段。

### 接入现有 HY

相同 32 秒暂停/恢复样本连接现有 `8001` 上的 `tencent/HY-MT1.5-1.8B-GGUF:Q8_0`，使用当前翻译类及未修改的提示词：收到 4 次 `sentence_translation`，无错误；包含剩余翻译的 final 收尾约 0.245 秒。

这是路由和译文输出验证，不是人工标注准确率评测。实际看到的风险包括：

- 无标点的固定长度前缀可能截在语义未结束的位置；一条英文以 “called” 结尾，下一条才出现地名。
- 圣经专名识别错误仍会传递给 HY，出现不符合原文的英文专名或句意。
- 因此暂不声称 XL+HY 英文质量优于 Qwen；建议现场对比后选择。本次不引入新标点模型、热词表或翻译提示词调整。

这次真实模型探针没有启动 Kokoro 合成或连接真机 Listen；朗读链路依赖已有回归覆盖，不能把本结果描述为 iPhone 端到端播放验证。

## 自动化和页面检查

完整测试命令：

```bash
cd /data/Qwen3-ASR/VoxBridge
/data/Qwen3-ASR/.venv/bin/python -m pytest -q
```

结果：**666 passed，178.50 秒**。包含模型延迟加载与并发首次加载、加载失败恢复、私有流、有限且幂等的 EOF、会话选路、Qwen→XL→Qwen、双会话隔离、不兼容方向、禁止采集中换引擎、无标点长句提前提交、VAD 静音后恢复及既有 ASR/字幕/翻译/朗读测试。

真实 Chromium 和 WebKit 运行页面 JavaScript；只在 WebSocket、媒体输入边界提供测试替身，覆盖麦克风及系统音频两个入口、选择记忆、方向约束、加载确认、开始/停止期间锁定和失败后解锁。将两个依赖源代码字符串的旧断言替换为实际页面行为断言，没有删除相应行为覆盖。

另检查了 1440×900 桌面和 390×844 移动布局截图：控件不重叠、无水平溢出、无页面 JavaScript 错误。这里的 WebKit/移动视口不是 iPhone 真机。

## 复现与诊断产物

```bash
cd /data/Qwen3-ASR/VoxBridge
/data/Qwen3-ASR/.venv/bin/python -m tools.benchmark_dual_asr \
  --audio /data/Qwen3-ASR/benchmarks/2026-09-12-zipformer-20260906/original-video-16k.wav \
  --model-dir /data/Qwen3-ASR/models/sherpa-onnx-streaming-zipformer-zh-xlarge-int8-2025-06-30 \
  --start-sec 60 --duration-sec 60 --realtime \
  --output /data/Qwen3-ASR/benchmarks/dual-asr-dev-tools/native-realtime-repeat.json
```

本次产物位于 `/data/Qwen3-ASR/benchmarks/dual-asr-dev-tools/`：

- `native-30s.json`、`native-realtime-60s.json`、`native-pause-resume.json`，及对应事件 trace。
- `pause-resume.wav`，仅生成的测试夹具。
- `native-hy-downstream.json`，实际 HY 输出与计时。

原始媒体与逐句测试字幕不加入 Git。操作方式、可选依赖、模型配置和回退方式见 [README](../../README.md#切换语音识别引擎)。

## 上线验证边界

代码与测试已在 AMD 仓库 main 上分阶段提交；本次不自动推送 GitHub。主要提交为 `5f3c509`（模型适配器）、`4012bd2`（会话选路）、`f286966`（采集页）、`f2c2bf3`（测试及说明）。按用户明确选择，由当前助手顺序实施并自行复核，没有委派子助手。

部署前确认没有 8024 已连接会话，且 `listener_count=0`、`producer_active=false`。新增用户级 `50-zipformer-xl.conf`，保留原有 `memory.conf` 与 `translation.conf`，重载 systemd 并重启原服务。

上线后实际检查：

- `voxbridge-8024.service` 为 active，PID `2670174`，`NRestarts=0`；翻译服务 active。
- `/login` 与 `/listen` 均 HTTP 200；首页仍跳转登录，认证没有被关闭。
- 运行进程读取到预期的 XL 模型目录；尚未选择 XL，Sherpa 原生库未映射，未在启动时抢先加载 XL。
- live status 没有错误，采集者/听众均为空，积压队列为 0。

**尚未完成：** 没有已登录的生产浏览器会话，因此尚未做线上 Qwen→XL→Qwen 真音频切换验收；已请求用户登录以便补测。不能将进程内真实 XL、真实 HY 探针或浏览器边界测试等同于该项验收，也未进行 iPhone 真机录音/朗读验收。
