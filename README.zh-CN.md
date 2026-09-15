# VoxHalo for macOS · 同声传译

[English](README.md) | **简体中文**

在 Apple Silicon Mac 上独立运行的八语言语音传译系统，提供原生音频采集、译音朗读、与播放同步的字幕，以及局域网听众功能。

**App 版本：**1.6.0，build 18 · **维护者：**[hellcatjack](https://github.com/hellcatjack) · **联系邮箱：**[hellcatjack@gmail.com](mailto:hellcatjack@gmail.com)

App 名称为 **同声传译**，当前界面为中文。识别、翻译和语音合成都在本机完成；首次安装需要下载模型与依赖，日常推理无需云端账号或 API 密钥。

## 文档导航

- [八语言验证与限制](docs/zh-CN/EIGHT-LANGUAGES.md)
- [第一阶段重构验收](docs/zh-CN/PHASE1-VALIDATION.md)
- [架构与通用模块边界](docs/zh-CN/ARCHITECTURE.md)
- [详细安装、更新与故障排查](docs/zh-CN/INSTALLATION.md)
- [模型、量化、提示词与许可证](docs/zh-CN/MODELS.md)
- [English documentation](README.md)
- [版本记录](CHANGELOG.md) · [发布验证](docs/PUBLICATION.md)

## 主要功能

- 中文、英文、日语、法语、西班牙语、意大利语、葡萄牙语和印地语，支持 56 个互译方向；开始前选择源语言与目标语言。
- 原生系统声音采集、只听译音模式、系统默认输入或指定麦克风／声卡。
- 系统默认输出、指定耳机／扬声器，或本机不播放而保留局域网朗读。
- 连续 PCM 播放，按待播量自动调整追赶语速；中文优先整句合成，减少句中重新起调。
- 已完成译文的字幕跟随本机实际朗读；字体、字号、颜色、阴影、显示器、位置和宽度均可调整，支持覆盖 Dock。
- App 负责采集和播放，监控网页的关闭或刷新不会中断传译。
- 自动检测局域网 IP 并提供地址及二维码，手机／平板可收听共享 HLS 音频。

```text
系统声音／麦克风
  → 原生采集 → Qwen3-ASR → 稳定原文 → HY-MT → 完成的译文
  → Kokoro → 本机 PCM 朗读＋同步字幕
           → 局域网听众共享 HLS

网页监控 ← 原文、译文与 TTS 状态
```

## 模型与本机加速

| 环节 | 模型及规模 | 本版本配置 |
|---|---|---|
| 语音识别 | [Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B)，0.6B 型号 | MLX 0.32.2 / mlx-qwen3-asr 0.4.0；INT8 权重、group size 64；Metal GPU |
| 文本翻译 | [HY-MT1.5-1.8B](https://huggingface.co/tencent/HY-MT1.5-1.8B)，18 亿参数 | 官方 Q8_0 GGUF；llama.cpp b10809；Metal GPU；4,096 token 上下文 |
| 七语言朗读 | [Kokoro-82M v1.0](https://huggingface.co/hexgrad/Kokoro-82M)，约 8,200 万参数 | 共享 ONNX Runtime CPU 模型；英文 `am_michael` 及六种语言音色 |
| 中文朗读 | [Kokoro-82M v1.1-zh](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh)，约 8,200 万参数 | ONNX Runtime CPU；男声 `zm_029`；修复浮点语速输入 |
| 语音活动检测 | Silero VAD ONNX | CPU，辅助静音处理和语音边界保护 |

识别与翻译共享 GPU 执行锁，TTS 使用两个 CPU 线程。本版本使用 Metal，没有部署到 Apple Neural Engine。OpenAI 兼容翻译接口实际指向**本地 llama.cpp 服务**，不会请求 OpenAI 云服务。

[模型说明](docs/zh-CN/MODELS.md)列出具体配置、固定版本、校验值和各自许可证。安装器下载约 **4.58 GB** 模型／运行时资源，另需 Python 依赖；中文语速修复会额外生成约 **344 MB** 模型。

## 最低 Mac 配置

**最低建议试用配置：Apple M1、16 GB 统一内存、macOS 14.2 或以上、20 GB 可用空间。** 这是工程估算的试用起点，**不是本项目已经实机验证的配置**。目前完整系统的最低已验证配置为 **MacBook Air M4／24 GB／macOS 26**。能够安装或加载模型，不等于能够持续跟上实时语音。

| 项目 | 最低要求／建议试用起点 | 已验证或建议日常使用配置 |
|---|---|---|
| 芯片 | Apple Silicon M1 或更新，原生 `arm64` | 已测试 M4；其他型号需验证实际表现 |
| 统一内存 | 建议至少 16 GB 试用；8 GB 未验证且不建议 | 24 GB 或以上；已测试 24 GB |
| macOS | 完整功能按 API 和依赖兼容性要求 14.2+ | macOS 26；本次文档核验环境为 26.6.2 |
| 可用空间 | 预留 20 GB，容纳模型、环境、下载缓存和临时文件 | 更新或保存本地测试资料时预留更多空间 |
| 构建工具 | 与系统兼容的 Xcode 命令行工具，SDK 需包含 macOS 14.2 音频 tap API | 已测试 Swift 6.3.3、SDK 26.5 |
| Python | 自动安装原生 Python 3.12.14 | 使用仓库内 `.venv` |
| 网络 | 安装时需要互联网，其他听众设备需要局域网 | 安装后模型推理在本机完成 |

安装器不支持 Intel Mac 或 Rosetta/x86 Python。macOS 14.0–14.1 无法提供“只听译音”采集。较早的 M 系列、16 GB 内存和 macOS 14/15 **尚未完成本项目的整套安装与长时间验收**，用于正式活动前应先完成实际负载测试。

App 的编译目标不能代表整套系统的最低要求，MLX 和 ONNX 包也有独立的系统限制；当前固定 MLX 版本分别提供 macOS 14、15 和 26 的 wheel。具体依据见[兼容性说明](docs/zh-CN/INSTALLATION.md#兼容性依据)。

## 安装

[详细安装指南](docs/zh-CN/INSTALLATION.md)包含安装前检查、逐步安装、权限、验收、更新、迁移及故障恢复。

先安装 Apple 命令行工具，并等待安装窗口完成：

```sh
xcode-select --install
```

将仓库克隆到长期保留的位置，安装并打开 App：

```sh
mkdir -p "$HOME/Projects"
cd "$HOME/Projects"
git clone https://github.com/hellcatjack/VoxHalo_mac.git
cd VoxHalo_mac
./setup.sh
open "$HOME/Applications/同声传译.app"
```

无需预装 Homebrew、Docker、独立 Python、虚拟声卡、付费 API 或远端推理服务器。安装器会建立本地环境、安装固定依赖、核对模型 SHA-256、修复中文语速输入并编译 App；不会自动开始录音。

**请保留整个仓库及其安装路径。** App 会记录该路径，并使用其中的 `.venv`、`runtime` 和 `models`。只复制 `.app` 到另一台 Mac 无法完成迁移。App 使用本机临时签名，未经 Developer ID 公证；当前发布形式为源码与安装脚本，不是通用独立 DMG。

## 使用方法

1. 在 App 中选择**输入来源**、**朗读输出**和**识别 → 译音**的源语言、目标语言。
2. 可选填写少量 ASR 提示词，点击**开始传译**，按 macOS 提示允许音频权限。
3. 采集开始后再讲话或播放源音频。需要查看历史时再点击**打开监控页**。
4. **结束传译**停止采集并收尾；**停止服务**卸载模型；**停止服务并退出**完全退出。

油管只听译音时，选择**系统播放声音 · 只听译音**和输出设备，先开始传译，再播放保持有声的视频。App 在采集期间抑制原声，结束前先暂停视频。采集覆盖其他应用的系统声音，并非只绑定一个 Chrome 标签页，请暂停无关声音源。

使用麦克风时建议搭配耳机，减少声音从空气中回流。系统声音模式会排除本 App 自己的朗读。切换输入、输出或方向前先结束当前传译。关闭控制窗口仍会继续运行，可通过菜单栏图标重新打开。

通过**字幕设置…**调整字幕窗。字幕跟随本机实际播放，后续译文不会提前替换仍在朗读的句子。关闭本机朗读时，字幕显示已完成译文，不再具有本机语音播放时钟。

本机监控地址为 `http://127.0.0.1:8024`。局域网听众使用 App 显示的地址或二维码，打开后点击 **Start Listening**。手机采用 HLS，缓冲等待可能比 Mac 原生播放更长。

## 维护与故障排查

在仓库根目录执行：

```sh
./macos.sh check
./macos.sh status
.venv/bin/python scripts/setup_assets.py --verify-only
```

日志位于 `VoxBridge/logs/`。[故障排查](docs/zh-CN/INSTALLATION.md#故障排查)覆盖权限、设备丢失、下载失败、端口占用、目录迁移、App 启动问题、更新和卸载。

## 限制与验证

- Qwen 使用有界窗口重复解码，约两秒触发一次，配合原文修订和最终复核；不是上游 vLLM 流式实现或原生 KV 缓存增量解码。
- 同时支持一个音频生产者。稳定短句在速度和准确性之间取舍；识别、翻译、合成及排队都会产生延迟。
- 同音词、中英混合专名、代词和从句关系仍可能出错，教会术语提示词无法消除这些问题。
- 已朗读原文的末尾新增内容可以单独补读；已听到的句中改写不会自动重新朗读。
- 局域网音频按同一源句顺序共享，但手机与 Mac 并非逐采样同步。iPhone 后台／锁屏播放需要真机验证。

M4／24 GB 上已测试中文讲道 600 秒和英文音频 609.479 秒。译文完成到首块 PCM 时间**不等于耳机端到端延迟**。具体见[历史长测记录](VoxBridge/docs/MACOS-TRANSLATION-INTEGRITY.md)和[源码发布验证](docs/PUBLICATION.md)。

## 隐私与网络访问

推理在本地运行。默认配置关闭调试文件记录，普通使用不会主动保存源录音。运行日志及主动生成的诊断资料可能包含文本或运行细节；设备选择与字幕外观保存于本机 macOS 偏好设置。

应用服务默认监听 `0.0.0.0:8024`，Mac 配置默认没有开启网页登录。能够访问该端口的设备可能查看监控文本或收听译音，应在可信网络使用，不要通过路由器向公网开放。HY-MT 仅监听 `127.0.0.1:8876`；原生采集／控制使用独立本机凭据。请勿公开 `VoxBridge/artifacts/macos-service/` 及其 token。

## 开发与贡献

欢迎在 [hellcatjack/VoxHalo_mac](https://github.com/hellcatjack/VoxHalo_mac) 提交 Issue 或 Pull Request。请包含 App／系统版本、芯片／内存、输入输出模式、方向、复现步骤和脱敏日志。安全问题或敏感报告请联系 [hellcatjack@gmail.com](mailto:hellcatjack@gmail.com)，不要公开凭据或私人录音。

```sh
# 安装完成后，从仓库根目录执行：
cd VoxBridge
../.venv/bin/python -m pytest -q
cd ..
./build-app.sh --destination "$PWD/dist/同声传译.app"
```

未安装可选浏览器或 ffprobe 工具时，相应检查可能跳过。请阅读 [AGENTS.md](AGENTS.md)，不要提交模型、媒体、虚拟环境和运行状态；修改用户文档时同步维护中英文版本。

```text
README.md / README.zh-CN.md      英文／中文入口
docs/en/ / docs/zh-CN/          安装及模型指南
setup.sh / build-app.sh         本地安装与 App 构建
scripts/runtime-assets.json    固定下载及校验清单
VoxBridge/deploy/macos/app/    原生 App 源码
VoxBridge/voxbridge/           识别、翻译、朗读和网页服务
VoxBridge/tests/               Python 与 Swift 回归测试
models/ runtime/ .venv/        安装生成的资源，不进入 Git
```

## 许可证与致谢

源码采用 [Apache-2.0](LICENSE)。模型权重和第三方依赖保留各自许可证。**HY-MT 使用 Tencent HY Community License，并非 Apache-2.0**；其公布的适用地域不包含欧盟、英国和韩国，另有使用及分发条件。安装或部署该模型前请阅读[固定版本许可证](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/blob/265b2e615a7dc9b06c435dc878829ad99a512ba2/License.txt)。

本项目由 hellcatjack 独立维护，与腾讯不存在关联、赞助或背书关系。感谢 Qwen、腾讯混元、MLX、llama.cpp、Kokoro、sherpa-onnx、Silero VAD，以及[模型与许可证说明](docs/zh-CN/MODELS.md#许可证与署名)中列出的其他依赖。

早期远端字幕客户端保留于 Git 历史、`v1.0.0` 标签和 `backup/pre-local-system-2026-09-14` 分支。当前变更见 [CHANGELOG.md](CHANGELOG.md)。
