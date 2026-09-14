# VoxHalo for macOS · 教会同声传译

在 Apple Silicon Mac 上独立运行的中文 ↔ 英文同声传译系统。原生 App 完成声音采集、模型服务管理、翻译朗读和字幕显示，关闭浏览器不会中断业务。

当前 App 版本：**1.5.1（build 16）**。发布维护：**hellcatjack · hellcatjack@gmail.com**。

## 能做什么

- 中英、英中两个方向切换，使用同一套采集、翻译、朗读与字幕流程。
- 输入可选系统播放声音、只听译音的系统声音模式、默认输入或具体麦克风／声卡。
- 输出可选系统默认设备、具体耳机／扬声器，或本机不播放而保留局域网听众。
- 原生 PCM 连续播放，依据实际待播量调整朗读速度；中文优先整句合成，避免逗号处频繁重新起调。
- 字幕跟随本机实际朗读，可调整颜色、字体、字号、阴影、显示器、位置和宽度，支持覆盖 Dock。
- 网页显示原文、译文和 TTS 状态；手机扫描自动使用局域网 IP 的二维码即可收听共享 HLS。
- 推理在本机完成；首次安装下载依赖及模型，日常不依赖云端识别或翻译服务。

## 已验证的配置

| 环节 | 默认设置 |
|---|---|
| 识别 | Qwen3-ASR 0.6B，MLX INT8，Apple Metal GPU |
| 翻译 | HY-MT1.5-1.8B Q8_0，llama.cpp b10809，Metal GPU |
| 英文朗读 | Kokoro v1.0，`am_michael` |
| 中文朗读 | Kokoro v1.1-zh，`zm_029` 男声，已修复浮点语速 |
| TTS 计算 | ONNX Runtime CPU，2 线程；基础语速 1.05 + Auto 追赶 |
| 原生 App | Swift / AppKit / Core Audio / ScreenCaptureKit |
| 服务 | 应用端口 `8024`；内部翻译端口 `8876` |

Qwen 在本实现中使用约 2 秒触发的有界窗口重复解码，配合原文修订和最终复核，并非原生 KV 缓存增量流式。识别和翻译仍可能出现同音词、代词指向及长句关系错误。验证详情见[双向长测与优化记录](VoxBridge/docs/MACOS-TRANSLATION-INTEGRITY.md)。

## 安装

需要 Apple Silicon Mac、可用的 Xcode 命令行工具及首次下载所需网络。已验证机器为 **MacBook Air M4 / 24 GB / macOS 26 / Python 3.12.14**；建议使用这一等级或更高的内存配置并预留 **20 GB** 磁盘空间。原生 App 编译目标为 macOS 14；“只听译音”模式需要 14.2+，整套固定依赖在旧 macOS 上尚未验收。

先安装命令行工具（已安装可跳过）：

```sh
xcode-select --install
```

将仓库放在长期保留的位置，然后安装：

```sh
git clone https://github.com/hellcatjack/VoxHalo_mac.git
cd VoxHalo_mac
./setup.sh
open "$HOME/Applications/教会同声传译.app"
```

脚本自动准备项目内 Python 3.12.14、固定依赖、约 4.6 GB 模型及运行时下载，校验 SHA-256，生成中文语速修复模型，最后在本机编译 App。不会使用系统全局 Python，也不会自动开始录音。安装失败后可重试；已有文件校验失败时会报出路径并保留原文件，移走该文件后再重试。

默认安装到 `~/Applications/教会同声传译.app`。要指定位置：

```sh
VOXHALO_APP_PATH="/Applications/教会同声传译.app" ./setup.sh
```

App 使用本机构建的临时签名，未做 Developer ID 公证。**App 会记录仓库的安装路径；请保留整个仓库、`.venv`、`runtime` 和 `models`。单独复制 `.app` 到另一台 Mac 不构成完整安装。** 移动目录后需重建环境并重新构建 App。

模型来源、固定版本及中文模型历史副本说明见[模型与依赖](docs/MODELS.md)。

## 使用

1. 打开 App，选择输入、输出和翻译方向。
2. 点击 **开始传译**，等待模型就绪并按 macOS 提示授权麦克风或系统音频。
3. 播放源音频或对着所选麦克风讲话。监控网页可按需打开。
4. 点击 **结束传译**，停止采集并收尾；**停止服务**卸载模型；菜单 **停止服务并退出** 完全退出。

听油管译音时，选择 **系统播放声音 · 只听译音 → 系统默认输出（或耳机）**。先开始传译，再播放视频，视频本身保持有声；App 在采集中抑制原声。结束时先暂停视频再结束传译。该模式采集其他应用的系统声音，并非只绑定一个 Chrome 标签页；请暂停无关声音源。

系统声音权限位于“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”；使用麦克风时另需麦克风权限。控制面板关闭后业务继续，通过菜单栏图标重新打开。更改输入、输出或方向前先结束传译。

本机监控入口：`http://127.0.0.1:8024`。局域网听众使用 App 显示的地址或二维码；手机与 Mac 应在同一网络，允许 macOS 防火墙接收入站连接。默认未开启网页登录，监控文本和听众音频对可访问 `8024` 的网络设备开放，请在可信局域网使用；原生业务控制使用独立的本机凭据。

完整操作说明见 [Mac 使用指南](VoxBridge/docs/MACOS.md)。

## 维护与验证

```sh
./macos.sh check                 # 检查本地资源
./macos.sh status                # 查询服务状态
./macos.sh start                 # 仅启动模型服务
./macos.sh stop                  # 停止本安装拥有的服务
./build-app.sh                   # 退出 App 后重新构建
.venv/bin/python scripts/setup_assets.py --verify-only
cd VoxBridge
../.venv/bin/python -m pytest -q
```

更新前先停止服务并退出 App，再在仓库根目录运行 `git pull --ff-only` 和 `./setup.sh`。已有模型通过校验后直接复用。首次安装也可用 `VOXHALO_ASSET_CACHE=/path/to/existing/workspace ./setup.sh` 从另一份本地工作区复制匹配校验值的资源；原工作区不会被修改。

运行日志位于 `VoxBridge/logs/`，状态、锁与原生控制凭据位于 `VoxBridge/artifacts/macos-service/`，均不提交到 Git。排错时可在 App 点击 **查看日志**。卸载时先在 App 选择 **停止服务并退出**，再移除该 App 及不再需要的整个安装目录。

## 项目结构

```text
setup.sh / build-app.sh / macos.sh    安装、构建及命令行管理入口
scripts/                            固定资源清单与下载校验
VoxBridge/deploy/macos/app/          原生 App 源码
VoxBridge/voxbridge/                 ASR、翻译、TTS、监控与听众服务
VoxBridge/tests/                    Python 与 Swift 回归测试
VoxBridge/docs/                     协议、操作及历史验证记录
models/ runtime/ .venv/              首次安装生成，不进入 Git
```

本次发布完整替换了旧的远端字幕客户端；旧版本保留在 Git 历史、`v1.0.0` 标签和 `backup/pre-local-system-2026-09-14` 分支。当前版本无需连接原 Linux 主机。上游 Linux 服务端代码和参考文档保留于 `VoxBridge/`，Mac 用户按本页安装。

项目源码采用 [Apache-2.0](LICENSE)。模型及第三方组件各自保留其许可，见[第三方来源](docs/THIRD_PARTY.md)。测试视频、录音、模型权重、运行凭据和本机配置不随源码发布。
