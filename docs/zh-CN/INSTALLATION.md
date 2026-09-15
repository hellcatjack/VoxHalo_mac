# 安装与操作指南

[English](../en/INSTALLATION.md) | **简体中文** · [项目首页](../../README.zh-CN.md) · [模型说明](MODELS.md)

本文与仓库的 `setup.sh` 及 App 1.6.0/build 18 对应。命令在“终端”运行；`$HOME` 会自动指向当前用户主目录，不需要替换成原开发者路径。

## 1. 检查 Mac 配置

建议试用起点为 **M1／16 GB／macOS 14.2+／20 GB 可用空间**，根据架构、依赖兼容性和内存预算估算，不是已经验证的实时性能下限。完整系统已在 **MacBook Air M4／24 GB／macOS 26** 测试。日常使用优先选择已验证配置；更早芯片、16 GB 和 macOS 14/15 需要独立验收。

```sh
uname -m
sw_vers -productVersion
sysctl -n hw.memsize
df -h "$HOME"
```

架构应显示 `arm64`。`hw.memsize` 返回字节数，16 GiB 对应 `17179869184`，24 GiB 对应 `25769803776`；磁盘剩余空间见 `Avail` 列。`x86_64` 表示 Intel Mac 或模拟运行的终端，Apple Silicon 用户应使用原生终端；不支持 Intel。

### 兼容性依据

- App 编译目标为 macOS 14.0，但[只听译音采集](../../VoxBridge/deploy/macos/app/SystemAudioTap.swift)明确需要 macOS 14.2 音频 tap API。
- [MLX 安装要求](https://ml-explore.github.io/mlx/build/html/install.html)包括 Apple Silicon 和 macOS 14+。固定的 [MLX 0.32.2](https://pypi.org/project/mlx/0.32.2/#files)及 [mlx-metal 0.32.2](https://pypi.org/project/mlx-metal/0.32.2/#files)分别提供 macOS 14／15／26 wheel；本机选中了 macOS 26 包，不表示只发布了这个包。
- 固定的 [ONNX Runtime 1.30.0](https://pypi.org/project/onnxruntime/1.30.0/#files)包含 macOS 14 arm64 包，所用 llama-server 二进制声明的最低部署系统为 macOS 13.3。
- 完整构建使用 macOS 26.6.2、Swift 6.3.3、SDK 26.5 验证。源码编译目标或 wheel 标签只能证明兼容性依据，不能代替每个旧系统上的实际安装测试。

安装器检查 Apple Silicon 和构建工具，但不对机器做性能基准测试，也不强制 16 GB 内存门槛。不能据此宣称 8 GB 可以稳定实时运行。

## 2. 安装 Apple 命令行工具

```sh
xcode-select --install
```

等待系统安装窗口完成再继续。已经安装时，可检查：

```sh
xcode-select -p
xcrun --find swiftc
xcrun --show-sdk-version
git --version
```

使用与 macOS 兼容、包含 macOS 14.2 音频 tap API 的命令行工具。完整 Xcode 也可以使用，但应选为当前开发工具目录。无需安装 Homebrew。

## 3. 克隆到长期保留的目录

避免临时目录或可能自动移除本地大文件的云同步目录。用户自己拥有的目录通常无需 `sudo`。

```sh
mkdir -p "$HOME/Projects"
cd "$HOME/Projects"
git clone https://github.com/hellcatjack/VoxHalo_mac.git
cd VoxHalo_mac
```

公开仓库的 HTTPS 克隆无需 GitHub 登录。如果已有该仓库，按更新步骤处理，不要在里面重复嵌套克隆。`v1.5.1` 标签保留原始源码发布版本，`main` 包含最新代码和文档。

## 4. 安装环境、模型和 App

```sh
./setup.sh
```

脚本依次完成：

1. 从官方发行页下载 uv **0.12.13**，校验压缩包 SHA-256。
2. 安装托管 Python **3.12.14**，在根目录创建 `.venv`，不使用全局 Python。
3. 安装固定的 Mac 依赖和本地 VoxBridge 包。
4. 为 ONNX 图修复建立独立 `runtime/model-tools` 环境。
5. 下载并核对 `scripts/runtime-assets.json` 中的 Qwen、HY-MT、Kokoro、VAD 和 llama.cpp。
6. 单独生成中文浮点语速模型，核对预期校验值。
7. 检查本地资源，编译并签名 **同声传译.app**，安装到 `~/Applications`。

安装器还会安装 `pyopenjtalk==0.4.1` 和按校验值固定的 OpenJTalk 1.11 日语词典。这项原生依赖需要前面安装的命令行编译工具；开始日语朗读时不会临时联网下载词典。

模型／运行时资源约 4.58 GB，另有 Python 及依赖包，完成时间取决于网络。App 第一次启动服务还需要加载并量化 ASR 模型，请等模型就绪再采集声音。

安装需要访问 GitHub 发行附件、Hugging Face 模型文件和 Python 包索引；脚本只准备本地资源，不会开始录音。模型使用受[各自许可证](MODELS.md#许可证与署名)约束，包括 HY-MT 的自定义条件。

### 可选安装方式

默认 `~/Applications` 为当前用户目录；如果账号有写入权限，也可指定系统“应用程序”目录：

```sh
VOXHALO_APP_PATH="/Applications/同声传译.app" ./setup.sh
```

复用另一份安装的模型时，将下面路径替换为实际工作区根目录：

```sh
VOXHALO_ASSET_CACHE="/absolute/path/to/existing/VoxHalo_mac" ./setup.sh
```

缓存来源只读，文件校验匹配后才复制；运行环境在新仓库创建。校验失败不会静默换模型。不要通过 `sudo` 运行整个安装器来绕过目录权限问题。

## 5. 验证安装结果

在仓库根目录执行：

```sh
.venv/bin/python --version
./macos.sh check
.venv/bin/python scripts/setup_assets.py --verify-only
```

应看到 Python 3.12.x、本地 Python／模型／FFmpeg 齐全提示，以及全部资源 SHA-256 一致的确认。`check` 只检查资源，不启动推理，也不表示已经取得麦克风权限。

可选检查服务就绪状态：

```sh
./macos.sh start
./macos.sh status
```

`app.ready` 和 `translation.ready` 都应为 `true`。这只启动模型，不选择音频设备或开始采集；如暂不使用 App，可执行 `./macos.sh stop` 结束检查。应用端口固定为 **8024**，内部翻译端口为 **8876**，遇到其他进程占用时会报错，不会直接结束对方。

## 6. 打开 App 并授权音频访问

```sh
open "$HOME/Applications/同声传译.app"
```

若安装时选择了 `/Applications`，请从相应路径打开。当前构建使用临时签名，不是 Developer ID 公证应用；macOS 阻止本机构建副本时，按系统打开提示或“隐私与安全性”选项操作，不要全局关闭 Gatekeeper。

| 输入或操作 | 所需处理 |
|---|---|
| 麦克风 | 在“隐私与安全性 → 麦克风”允许“同声传译” |
| 系统播放声音 | 在“屏幕与系统音频录制”或相应系统版本的同类选项中允许 App |
| 工作区位于受保护目录 | 如果确为选择的安装目录，允许对应文件夹访问请求 |
| 局域网听众 | macOS 防火墙提示时允许相应服务接受传入连接 |

临时签名 App 重新编译或更新后，代码签名身份会变化。即使旧条目的权限开关仍显示开启，macOS 也可能再次请求音频访问。系统音频录制与桌面文件夹是独立弹窗，需要分别处理后才能开始采集。

无需“完全磁盘访问权限”。之前拒绝过音频权限，修改后可能需要退出并重开 App；权限属于原生 App，不属于 Chrome。

## 7. 开始第一次传译

| App 控件 | 用途 |
|---|---|
| 输入来源 | 选择系统声音或麦克风等设备 |
| 朗读输出 | 选择本机播放设备，或只保留局域网朗读 |
| 识别 → 译音 | 选择源语言及目标语言，八种语言可选；不允许相同语言 |
| 开始传译／结束传译 | 开始采集或停止采集并收尾 |
| 启动服务／停止服务 | 加载或卸载模型 |
| 打开监控页 | 查看只读监控 |
| 字幕设置… | 配置字幕外观和位置 |
| 停止服务并退出 | 停止采集、播放及服务后退出 |

浏览器只听译音时，输入选择**系统播放声音 · 只听译音**，输出选择**系统默认输出**或具体耳机，方向与源语音一致。点击**开始传译**，等待采集启动后再播放视频，保持视频音量开启。原声抑制由 App 完成，源网页静音可能让采集失去输入。

先用一小段声音检查输入电平、原文、译文和朗读，并分别在监控网页开启及关闭时试用。结束传译前先暂停视频。普通**系统播放声音**模式会保留原声，所以会与译音同时听到。

系统采集覆盖其他应用播放声音并排除本 App 朗读，请暂停其他标签页，避免在同一台 Mac 上播放 HLS 听众页。麦克风输入建议配合耳机，减少声学回流。更改设备或方向前结束传译；明确选择的设备断开后，接回设备或重新选择，再点击**刷新设备**。

## 8. 监控、字幕与局域网听众

- **监控：**Mac 本机访问 `http://127.0.0.1:8024`，其他设备访问 Mac 实际局域网地址。网页不负责控制传译会话。
- **字幕：**在**字幕设置…**启用，调整显示器、字体、字号、颜色、阴影、位置与宽度，底部可以覆盖 Dock。外观修改不改变 TTS 音频。
- **听众：**同一局域网扫描 App 二维码，点击 **Start Listening**。二维码使用检测到的局域网 IP，不使用 `127.0.0.1`。没有可用局域网地址时仍能本机使用，但不提供无效的局域网二维码。

其他设备无法连接时，检查 Wi-Fi／以太网、防火墙和访客网络／终端隔离。默认没有网页登录，请在可信网络中使用 `8024`；手机 HLS 缓冲与本机原生播放时钟不同。

## 9. 更新或重新构建

先停止服务并退出 App，再在已有仓库根目录执行：

```sh
git status --short
git pull --ff-only
./setup.sh
```

拉取前保存或提交本地修改，不要通过强制 reset 丢弃修改。已校验匹配的模型会复用。环境已经安装、只需重建 App 时执行：

```sh
./build-app.sh
```

构建到独立验收目录，避免覆盖已安装 App：

```sh
./build-app.sh --destination "$PWD/dist/同声传译.app"
```

以前选择过自定义 App 位置时，重建时也应明确指定；shell 脚本不会自动记住这个选择。音频及字幕偏好设置则独立保存在 macOS UserDefaults 中。

从旧中文名称升级时，先退出旧 App。新入口为 `同声传译.app`，确认新版正常后移除旧应用副本和桌面快捷方式，避免打开早期构建。应用标识保持一致，可沿用既有偏好设置。

## 10. 更换目录、迁移与卸载

App 保存仓库绝对路径，Python 环境也包含安装路径信息。不要只移动 App、复制 Linux 虚拟环境，或假定目录移动后 `.venv` 仍有效。

迁移时先停止旧安装，在最终目录重新克隆并运行 `setup.sh`，可通过 `VOXHALO_ASSET_CACHE` 复用旧工作区的已校验模型。对新目录重新构建 App、确认正常后再删除旧安装。同一时间只有一份安装能使用 8024／8876。

卸载时先选择**停止服务并退出**，从安装时指定的“应用程序”目录移除 App，确认模型／日志不再需要后再移除仓库。App 关闭时可选重置偏好设置：

```sh
defaults delete org.pccs.voxbridge.console
```

该命令重置本 App 的设备及字幕偏好，不删除模型，也不移除系统音频权限。提示找不到 domain，表示该偏好域不存在。

现有 1.5.x 用户请按更新步骤重新运行 `./setup.sh`。只执行 `git pull` 不会安装新增的日语依赖与词典。

## 故障排查

| 现象 | 检查和恢复 |
|---|---|
| 找不到 `swiftc` 或 SDK | 完成命令行工具安装，检查 `xcode-select -p` 与 `xcrun --find swiftc`，选择有效且兼容的工具目录 |
| 架构被拒绝／没有匹配 wheel | 确认 `uname -m` 为 `arm64`，系统达到文档兼容下限，不随意替换依赖版本 |
| 下载中断 | 恢复网络后重跑 `./setup.sh`；完整且通过校验的资源复用，单个未完成文件可能重新下载 |
| 校验值不一致 | 核对错误中的确切文件路径，先保留／移走该文件再重跑，不要修改清单去接受未知文件 |
| 移动目录后 Python 环境失效 | 在最终目录重新克隆并建立环境，只复用经过校验的资源 |
| `8024` 或 `8876` 被占用 | 停止已确认占用的另一份安装／应用，不盲目结束无关进程 |
| 没有输入电平 | 检查 App 权限、输入设备、源音频音量，确认没有暂停或静音 |
| 仍能听到原声 | 选择**系统播放声音 · 只听译音**，确认采集启动且系统为 14.2+；普通系统声音模式会保留原声 |
| 有译文但无朗读 | 检查输出选择、系统音量、设备连接、本机播放开关、TTS 队列和日志 |
| App 找不到服务文件 | 仓库可能移动或被删除，重建安装并重新编译 App |
| 积压／内存压力持续增加 | 关闭其他高负载应用，参考已验证配置，并用代表性的长音频测试；能加载模型不代表能实时跟上 |
| 手机打不开听众页 | 检查 App 当前局域网 IP、防火墙和网络隔离，手机的 `127.0.0.1` 指向手机自己 |

常用只读检查：

```sh
./macos.sh status
lsof -nP -iTCP:8024 -sTCP:LISTEN
lsof -nP -iTCP:8876 -sTCP:LISTEN
tail -n 80 VoxBridge/logs/macos-app.log
tail -n 80 VoxBridge/logs/macos-translation.log
```

分享前先检查日志，不要把原生控制 token、私人录音或整个运行状态目录上传到公开 Issue。请向 [GitHub Issues](https://github.com/hellcatjack/VoxHalo_mac/issues) 提供 App／系统版本、芯片／内存、方向、设备和脱敏错误信息。
