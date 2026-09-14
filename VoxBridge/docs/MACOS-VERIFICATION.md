# MacBook Air 本地移植验收记录

日期：2026-09-12。本机 Apple M4、24GB、macOS26 arm64。源项目只读克隆自 `上游 Linux VoxBridge 项目`，基线 `8b4fdaa`。本地分支 `macos-local`，应用端口8024，翻译端口8876。

## 模型与完整链路

沿用此前本机的 Qwen3-ASR0.6B MLX affine INT8 group64 / FP16 激活，以及 HY-MT1.5-1.8B Q8_0 / llama.cpp b10809 Metal。HY-MT 的 temperature0、top_p0.6、top_k20、repeat_penalty1.05、repeat_last_n64、max_tokens256、cache_prompt=false 保持一致；保留源项目教会翻译提示词、双向语言约束、术语、句子修订和朗读稳定等待。

Kokoro 的5个模型、音色、中文词表文件来自源项目并逐个 SHA-256 校验通过。中英文分别在禁用 socket.connect 的进程中成功合成为24kHz WAV，未依赖网络下载。Silero 使用原本机的 ONNX 文件，以 NumPy 和 CPU ONNX Runtime 运行，无需 PyTorch。

## 真实推理与共享朗读

`tools/macos_e2e.py` 以每100ms一包的实时节奏，经生产 WebSocket 发送16kHz单声道PCM16；调用真实 Qwen、HY-MT、Kokoro 与 FFmpeg，两个本地听众租约同时加入。读取并解码实际 HLS/AAC 音频，全程静默，不驱动扬声器。

| 场景 | 输入含1秒尾静音 | 最终事件时间 | HLS解码音频长度 | 结果 |
|---|---:|---:|---:|---|
| 通用中英混说（最终冻结版本） | 23.84秒 | 25.55秒 | 31.02秒 | 英文词保留；无多余尾静音文字；全链路通过 |
| 用户原视频讲道片段（最终冻结版本） | 36秒 | 38.01秒 | 52.01秒 | 识别、翻译、朗读、停止收尾通过 |
| 英文欢迎和祝福→中文（最终冻结版本） | 5.18秒 | 7.29秒 | 13.01秒 | 两句完整识别、翻译及中文朗读 |

原视频来源为用户指定 `https://www.youtube.com/watch?v=CeN8I93cOOo`，复用已有录音 `../benchmarks/youtube-CeN8I93cOOo/capture.f32` 的第10.5至45.5秒，未再次播放视频。整份录音 SHA-256：`72b36779dcabf91de725525a0c0d5bd64750f6e87de25b7b183a757bb13e834e`。

通用样本复用此前空术语的三段官方混说音频（always、Monday/Today、frequently），未为样本添加专用纠错词。英文反向样本为本机 Kokoro 生成的 “Welcome to Pittsburgh Christian Church South. May the Lord bless you.”，最终中文是“欢迎来到匹兹堡基督教南教会。愿主祝福你。”

每场测试均确认两听众共享一个语音 epoch、移除第一听众后第二听众继续使用同一编码器、最后听众退出后 listener_count=0、encoder_active=false、队列归零。解码音频包含实际非零语音，不能把载波静音误判为朗读通过。HLS长度包含载波/排队时间，不等于纯语音时长；这些数据不是严格性能 A/B 或人工标注准确率评测。

原始证据在 `artifacts/macos/e2e-mixed/`、`e2e-sermon-final/`、`e2e-reverse-final/` 的 report.json、events.json、after.json 和 shared-audio.wav。首个修正前版本保留在 `e2e-mixed-before-continuity-fix/`。

## 自动回归

最终冻结版本执行下列命令完成：**687 passed, 2 skipped, 1 warning in141.78s**。此前基线为680通过；新增边界回归已包含在最终结果。

```bash
PATH="$PWD/../.venv/bin:$PATH" ../.venv/bin/python -m pytest -q \
  --ignore=tests/test_main_page_asr_engine_browser.py \
  --ignore=tests/test_main_page_audio_gate_browser.py \
  --ignore=tests/test_tts_listener_page_browser.py \
  --disable-warnings --tb=short
```

最终日志：`artifacts/macos/pytest-final-frozen.log`；此前基线日志为 `artifacts/macos/pytest-final.log`。两项跳过依赖未安装的 ffprobe；真实 HLS 已由本地 FFmpeg 成功解码。浏览器测试不通过 shell Playwright 执行，由原生 Chrome/CUA 验证实际页面与操作。

独立代码复核发现并要求处理的边界见 `docs/macos-review.md`：持续空识别结果时仍需滚动有界音频，以及带空格路径的进程所有权判断。网页及最终修复的补充验收如下。

## 已知限制

这是本地完整功能移植，不等于模型准确率升级。讲道录音里仍出现“收进典礼”等错词和分段重复，译文会受到影响；术语提示应按实际场景使用，默认留空。MLX采用有界窗口重复识别，非原生缓存增量流式。手机锁屏与跨设备实际延迟尚未真机验收；两个本地听众租约只能证明共享服务器流及资源清理。

## 新指定视频的真实网页验收

用户随后指定 [教会成长的契机](https://www.youtube.com/watch?v=op4SjGpqBuk)。在原生 Chrome 中为主页面选择“系统声音”，在共享选择器里限定为该 YouTube 标签页并开启音轨。已观察到 Listening(system audio)、Qwen3-ASR、方向与术语锁定、控制栏自动隐藏。

播放/采集片段约为0:15至0:30，共约15秒；站点加载后曾自动播放开头约15秒，随后已暂停，不能将整次有声操作说成仅15秒。结束测试时关闭该播放标签页，主页面自动停止并释放共享，显示 Stopped / 已停止、Start可用、Stop禁用。未播放完整41分钟视频。

实际页面识别到牧师向听众提问、谈到现场椅子与风扇。问题片段识别为“煤浆的椅子”，对应英文包含 “chairs made of coal slurry”。

“煤浆”及其直译需要人工核对。本次没有人工全文参考或保存该次输入PCM，不提供CER/WER；也没有加入只针对该视频的纠错词。这个结果证明浏览器捕获→本机ASR→HY-MT→双语显示实际运行，不能证明准确率已足够用于无人审核的讲道翻译。页面另有片头残句和“嗯。”，片段从句中开始，不能仅凭截图断言每一处都是模型错误。

独立 `/listen` 页面可从本机链接打开；Start Listening后显示Connected、1 listening、Auto1.0x，并显示实际流字幕“Mm.”。这是短语级浏览器播放验证，长句语音有效性由前述真实HLS解码验证。随后 Stop Listening成功，显示Stopped、Not joined，主页面采集与视频播放均已结束。正常使用建议先在朗读页启动监听，再开始主页面采集，避免在讲完后才加入而错过之前的句子。

## 最终修复与运行检查

独立复核的4项P2均已关闭：带空格路径的进程所有权、空识别窗口的有界重置、小音量Silero确认的人声保留、延迟音频与静音控制消息的顺序。修复验证包括64秒空输入后恢复讲话、短句Stop收尾、零音频不产生字幕、静音后续段不沿用旧人声证据，以及繁忙合批时标记音频顺序和样本计数。

代码冻结后重新执行正常 `macos.sh stop` / `start` 成功。最终混说真实链路保留英文且无此前的多余尾音“嗯。”；模型精度与HY-MT采样参数未改。冻结文件哈希保存在 `artifacts/macos/final-code.sha256`，最后核对通过。完整冻结版本回归日志为 `artifacts/macos/pytest-final-frozen.log`。

## 局域网二维码修正验收

同日按用户要求将 Mac 启动器的应用监听改为 `0.0.0.0:8024`，二维码使用
`--public-listener-url auto`。每次加载主页面时检测活动的物理局域网 IPv4，
链接与内嵌 SVG 使用同一个检测结果；断网显示连接提示，不回退到回环地址。
二维码接口和主页面均不缓存。Qwen、HY-MT 与朗读参数保持不变。

相关回归：**140 passed, 297 deselected, 1 warning in 2.54s**，覆盖 IP 变化、
VPN/回环/失效接口排除、无默认路由的局域网、断网提示、页面与二维码一致性、
既有访问控制和 Mac 启动配置。

```bash
../.venv/bin/python -m pytest -q tests/test_lan_address.py \
  tests/test_public_listener.py tests/test_macos_runtime.py \
  tests/test_demo_streaming_ws_utils.py tests/test_demo_streaming_ws_protocol.py \
  tests/test_release_docs.py \
  -k 'listener or lan or service_ or port_probe or macos or sampling or auth or index_template or parse_args' \
  --disable-warnings --tb=short
```

正常停止并重启后，`lsof` 确认应用监听 `*:8024`，内部翻译服务仍监听
`127.0.0.1:8876`。分别通过本机回环与 `192.0.2.10:8024` 获取主页面，
两者的链接及内嵌二维码都指向 `http://192.0.2.10:8024/listen`。
从另一台局域网主机 `192.0.2.31` 发起只读 HTTP 请求，朗读页面和二维码接口
均返回 **200**。原生 Chrome 刷新后已确认正确 LAN 链接和可见二维码。
本次没有启动音频采集或播放；手机扫码、锁屏播放仍需手机真机验收。
