# 原生 Mac App 验收

> 名称说明：当前项目中文名称为“同声传译”。本文保留验证当时使用的应用名称与路径。

2026-09-13，Apple M4 / macOS 26.6.2，端口固定 8024。

## 浏览器独立运行版 1.1

启动器现在直接选择系统声音/麦克风、朗读输出、翻译方向及 ASR 提示词。ScreenCaptureKit / AVAudioEngine 采集，原生 WebSocket 连接已有 ASR/翻译流水线，原生 AVPlayer 播放共享 HLS。Mac 启动不自动打开网页；根页面只读监控，不能开启采集或占用识别连接。局域网听众只消费音频。

模型、量化、HY-MT 教会提示词、分句策略及 Kokoro 音色和 CPU 线程数均保持不变。

## 已执行的验证

- 最终原工作区完整 Python 回归：**717 passed, 8 skipped, 1 warning**，130.65 秒。警告为既有 Starlette/AnyIO 弃用提示。HLS 模块另测 **72 passed, 5 skipped**；其中跳过项为未从 PATH 找到外部 FFmpeg 的测试，真实链路使用环境自带的 FFmpeg。
- 原生音频转换：连续 16/44.1/48/96 kHz 转 16 kHz、立体声平均、削波、精确时长、最终不足块、缓冲区拷贝/上限和停止排空均通过。
- 实机只读设备枚举：BuiltInMicrophoneDevice / MacBook Air Microphone，BuiltInSpeakerDevice / MacBook Air Speakers。App 下拉列表、选择保存、就绪按钮、局域网地址和二维码已通过界面检查。
- 原生状态测试：明确选择的输出消失时，即使监控 HTTP 一直正常也会停止并释放资源；采集启动未完成时停止不会被晚到的启动复活；同时调用停止都会等待清理完成。
- 真实 **Swift NativeSession** 注入本地 24 秒讲道 PCM，按 100 ms 块实时发送；Qwen → HY-MT → Kokoro → HLS 完成。第一次测试不启动浏览器，51 次监控请求没有改变语音 epoch 或额外创建听众；结束后生产者、原生听众、编码器全部释放。
- 首次 HLS 输出解码为 27.008 秒音频，峰值 0.522、RMS 0.0217，确认实际有语音而非仅静音载流。源和译文保留在 `artifacts/macos/native-pipeline/report.json`。
- 真实 AVPlayer 输出另测通过：`output_uid=default`，采集结束前播放器已推进 24.35 秒，完整会话含最后朗读共 39.93 秒。播放期间实际打开、刷新、关闭监控页，原生会话继续且 epoch 不变；随后正常等待朗读结束并清理。证据：`artifacts/macos/native-playback/report.json`。
- 原生权限拒绝已实测：系统声音被 macOS 拒绝时，显示操作指引，释放连接，回到可重新开始的状态。没有绕过 TCC。
- 审查修复：监控版本改为单调计数；旧后台不能被误认作原生服务；设备错误不再被正常网络轮询冲掉；新 HLS epoch 清理历史错误，单句合成错误作为可恢复提示；修正布局约束的共同祖先顺序和应用委托生命周期。

## 最终安装

已合并到原工作区 `macos-local`，修复版安装到 `/Applications/教会同声传译.app`，桌面入口仍指向该路径；最新版本 1.1.0 / build 7，arm64。应用配置绑定原 `VoxBridge` 路径，没有指向测试工作树。

初次安装时的桌面访问授权等待已由用户处理；随后才复现并修复下列两处启动故障。新构建的授权状态单独记录在本节后。

## 2026-09-13 启动故障修复

- 实机复现麦克风启动约 0.1 秒即退出。原因是把 AVAudioEngine 的所有配置变更通知都当成设备断开，包括启动过程中正常晚到的通知。现按设备 UID 检查连接；引擎仍运行时继续采集，因格式变化停止时在主线程重建 tap 并恢复。真实断开或恢复失败仍显示错误。
- 修复后安装 build 3，MacBook Air Microphone 已实际采到讲话，界面显示中文识别与英文翻译。PCM 转换测试、4 类麦克风恢复检查及 18 项服务管理测试通过。
- 另复现冷启动 HLS 只有一个 1.024 秒片段时，AVPlayer 保持 unknown、30 秒内不播放。等待播放列表积累三个 target duration 后再创建播放器，实测立即就绪并连续推进。已有足够片段的音频流无需额外等待；不在本机播放时跳过这一准备步骤。
- 最终代码的 NativeSession 实测持续 80 秒，第 65 秒后注入约 5.1 秒混合语音，识别成功，明确选择 BuiltInSpeakerDevice 的播放器推进 80.91 秒，随后正常释放资源。浏览器不参与测试。证据位于 `artifacts/macos/native-startup-fix/longrun-final.log`。
- 最终代码另用 24 秒讲道 PCM 完成识别、HY-MT 翻译、Kokoro 朗读和正常停止，共 42.81 秒；停止前播放器推进 25.43 秒，最后两句译文非空，停止后监听数为 0、生产者与编码器均关闭。50 次监控请求未改变 epoch。报告：`artifacts/macos/native-startup-fix/pipeline/report.json`。
- 新增冷启动缓冲阶段停止的回归检查通过：覆盖直接停止及与 App 相同的先取消启动任务再停止；停止后迟到的播放列表请求不能留下监听租约，清理请求不受调用任务取消影响。设备丢失、采集启动取消、并发停止检查也通过。

build 4 初次安装后，17:24 的 TCC 日志记录桌面访问授权提示，随后检查时 Mac 已锁定。用户再次要求打包启动后，已在解锁状态重新编译、安装并从原生 App 开始传译：Qwen/HY-MT 服务就绪，8024 正常监听，麦克风输入持续产生中文识别文本，原生音频监听数为 1，无会话或 TTS 错误。原先等待的桌面授权已处理，App 的启动验收通过。输入保留 MacBook Air Microphone，输出保留 MacBook Air Speakers。

## 2026-09-13 持续运行断开修复（build 5）

用户继续运行后报告断开与无法重启，进一步测试发现 build 4 的 80 秒状态检查不充分：Foundation 可以在底层 WebSocket 已失败后仍让异步发送/接收和 UI 保持运行，不能仅靠 phase 或已有识别文字判断长连接健康。

- 原代码持续语音实测：WebSocket 的 `didCompleteWithError` 在约 60 秒报告 `NSURLErrorTimedOut`；它错误地复用了 HTTP 的 60 秒资源总时限。现在每次会话独立创建 WebSocket URLSession，保留 Foundation 的长资源时限，短 HTTP 请求保持有界超时；连接完成代理及时把意外断开反馈给会话，停止时销毁该传输，重启使用新连接。
- 单独延长时限仍复现 AVPlayer 卡住。播放列表诊断记录服务端静音压缩把媒体序号从 0 跳至 80、再跳至 137；第二次跳跃时播放器停在 134.33 秒，随后 CoreMedia 清空缓冲并触发停滞。原生请求现在使用 `continuous=true` 保留连续时间线，浏览器听众默认的静音压缩行为不变。正常结束期间仍会刷新监听租约。
- 提示词 `尼希米 同工` 原先被作为一个含内部空白的术语发送，服务端拒绝启动。现在按空格、制表符及换行拆分，再检查 24 项/160 字上限；界面明确提示空格或逗号均可分隔。
- 最终 Swift/真实模型回归：重复最多 24 秒的讲道片段并加入 3 秒间隔，共运行 180 秒；播放器推进 182.59 秒，每 10 秒检查一次识别/翻译与播放进度。随后正常完成最后朗读，再在同一 NativeSession 上立即启动/停止两次，总测试时间 212.78 秒。最终监听数、队列和待输出均为 0，生产者与编码器关闭，无错误。
- 受控故障测试：只终止本次测试所属的后端进程，原生会话在 0.073 秒内发现连接重置并停止；后端恢复后，同一控制器成功重连并停止。生命周期测试（冷启动取消、设备丢失、等待采集时取消、并发停止）通过。
- 完整 Python 回归：**718 passed, 8 skipped, 1 warning**，130.45 秒；警告仍是 Starlette/AnyIO 弃用提示。HLS 与原生监控专项为 **82 passed, 5 skipped**。新增提示词回归先失败后通过，连续播放列表回归先失败后通过。
- Chrome 监控页已实际刷新、关闭、重开，后台会话不依赖它且能重新读取状态。故障注入时的最终浏览器重连和 build 5 原生窗口重开检查遇到 Mac 锁屏，需要用户解锁后继续。全部测试音频已停止，模型服务保持就绪；安装后原 build 4 进程仍需退出并重开。

证据目录：`artifacts/macos/disconnect-fix/`，包括原始失败日志、播放列表跳跃诊断、`sustained-fixed.json`、`forced-disconnect.log` 和完整 Python 回归结果。

## 2026-09-13 长测与原生载流静音压缩（build 6）

指定视频 `q5tBWsDc8gI` 前 10 分钟按实时节奏完成识别、翻译和原生朗读：87 句，25 次载流静音跳转全部成功，累计跳过 28.831 秒，最大跳转耗时 169 ms。正常结束及资源释放通过；下一句尚未生成或未进入可播放窗口时仍会等待。原生连续 HLS 时间线保留，未恢复会导致卡死的服务端媒体序号跳跃。详细指标、限制和复现方法见 [长测报告](MACOS-PLAYBACK-LONG-TEST.md)。

build 6 的 App 麦克风启动触发 macOS 重新授权（TCC 日志确认签名变化），并暴露未回复授权时 async 请求无法取消、停止也受阻的问题。build 7 改为可取消的权限回调等待，覆盖允许/拒绝/取消/晚到回复/再次请求，PCM、麦克风恢复和原生生命周期复测通过。最终 App 已安装并重开；21:53 的 TCC 日志确认系统当前仍询问桌面项目访问权限，真实录音界面验收等待用户授权。真实模型的 10 分钟测试与 60 秒复测通过，Python 专项回归为 100 passed、6 skipped。

## 实机权限边界

真实麦克风录音已在上述 build 3 通过。真实 ScreenCaptureKit 系统声源采集及排除自身朗读的效果尚未完成验收；文件注入测试不能替代这部分录音设备验收。

请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”允许 **教会同声传译**；若使用麦克风，在“麦克风”中允许。完成后重启 App。新构建采用临时签名，macOS 可能重新询问访问桌面项目；只需要相关目录/录音权限，不需要完全磁盘访问。

## 构建与测试入口

- `tools/build_macos_app.py --desktop-link`：原生编译、签名、安装，并保留桌面入口。
- `tests/macos/AudioCaptureChecks.swift`：PCM 转换和缓冲区测试，不请求录音权限。
- `tests/macos/NativeSessionChecks.swift`：设置持久化与有界发送队列。
- `tests/macos/NativeLifecycleChecks.swift`：真实本地后端配合可控采集源测试停止与设备状态。
- `tests/macos/MicrophoneRecoveryChecks.swift`：正常配置通知、停止引擎恢复、设备断开和恢复失败。
- `tests/macos/HLSPlaybackBootstrapChecks.swift`：按 target duration 验证冷启动播放窗口。
- `tests/macos/NativeLongRunChecks.swift ROOT OUTPUT_UID PCM16_16KHZ_MONO_FILE`：80 秒运行，第 65 秒才注入最长 7 秒的语音片段，验证持续接收和原生播放；运行前应停止 App 的传译会话。
- `tests/macos/NativeSustainedChecks.swift ROOT PCM16_16KHZ_MONO_FILE REPORT_JSON OUTPUT_UID`：3 分钟持续语音、每 10 秒检查播放推进、正常结束和同一控制器的两次立即重启；开始前停止其他传译会话。
- `tests/macos/NativeDisconnectChecks.swift ROOT SIGNAL_FILE_PREFIX`：真实后端意外退出和恢复；测试本身不终止服务，由操作者在 `.ready` 出现后写入 `.down` 的 Unix 时间并终止本次所属进程，再启动后端。
- `tests/macos/NativePipelineChecks.swift ROOT PCM16_FILE REPORT_DIR [OUTPUT_UID]`：注入 PCM 的原生端到端测试；默认不在本机播放，可传 `default` 或具体设备 UID 验证 AVPlayer。

App 复用 `pccsInterpretation` 的模型和环境。临时签名不是 Developer ID 公证，不是任意 Mac 的独立分发包。既有按钮闪动修复保留：后台健康查询沿用上次状态，不临时禁用操作控件。
