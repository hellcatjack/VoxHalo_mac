# 字幕位置与 TTS 同步修复

日期：2026-09-14。版本：1.4.1（build 12），基线 `95b5cf8`。

## 根因与修复

旧字幕使用 `NSScreen.visibleFrame`，并额外限制上下 20 pt，不能进入 Dock 区域。现使用整块屏幕的 `frame`，垂直 100% 和“底部居中”均到达屏幕底边，保持透明、置顶和鼠标穿透。

旧字幕按翻译完成到达顺序更新，并使用独立阅读计时器翻页，因而可能领先音频。现以 50 ms 的独立观察任务读取既有 PCM 调度记录及实际输出进度，扣除节点报告的输出呈现延迟；只显示当前输出的语音段。后续语音排队时不抢字幕，音频等待时保留上一段。朗读字幕整段排版，空间不足时缩小渲染字号，不再定时翻页。本机不播放时保留最新完成译文及分页；旧 HLS 本机播放兼容路径读取已有节目时间和 caption 数据，不添加音频请求。

## TTS 不变约束

`voxbridge/` 后端和 `tools/macos_service.py` 没有变化。没有修改模型、提示词、翻译生成、Kokoro 音色（am_michael / zm_029）、语速、分块、PCM 字节、合成参数、缓存、调度、句间停顿、反馈或 HLS 跳过静音逻辑。`NativeSpeechPlayer` 唯一生产变更是新增只读 `subtitlePresentedFrame` 属性；音频启停、缓冲、回调和调度代码均未改动。字幕设置和观察任务不调用音频控制方法。

## 验证结果

- 修复前，底边断言失败；修复后实际 NSPanel 底边等于物理屏幕底边，覆盖 Dock 的窗口层级和鼠标穿透保持不变。
- `SubtitlePlaybackChecks`：音频排队、未开始、同一播放位置、下一段边界、缺后续音频、重复文本、新会话无字幕。
- `SubtitleOverlayChecks`：完整语音段在超过原翻页时限后仍不变化；CoreText 可见范围覆盖整段；原中英 / emoji 分页和极端字号 / 阴影检查通过。
- `SubtitleFoundationChecks`：完成条件、版本、乱序、清除、偏好持久化及全屏位置通过。
- 原 `NativeSpeechPlayerChecks`：连续调度、完整帧、序号、epoch、设备选择、重启隔离、播放进度和排空通过。
- `NativeSubtitleAudioChecks`：同一 NativeSession 依次实播中文→英文和英文→中文；每轮源音频不超过 13 秒。播放中每 250 ms 调整字幕字号、颜色和位置。每轮 4 个音频段对应 4 次字幕切换，无遗漏，全部正常排空。
- 两轮都验证了下一段已排队时当前字幕保持。字幕在该段输出起点后约 **6.8–40.1 ms** 更新，没有提前；两轮各 3 个相邻音频边界的额外空档全部为 **0 ms**。每段调度帧数等于原始 PCM 帧数，并保存 PCM SHA-256 供复核。

实播报告：`artifacts/macos/subtitle-sync-1.4.1/audio.json`；渲染图：同目录 `render.png`。这是本机默认输出设备下的样本验证，未对所有蓝牙设备的硬件延迟做实测；字幕不会反向调整 TTS 来追赶画面。

Apple 官方依据：[visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)、[输出呈现延迟](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency)。

已安装并打开 `/Applications/教会同声传译.app`，界面确认 1.4.1（build 12）。实际将“底部居中”设为垂直 100%，保留原有字号、阴影和宽度；返回主界面后服务检查正常，“启动服务 / 开始传译”均可用。测试服务已停止，未留下采集或播放。旧 HLS 静音跳过检查与新增 caption 文本解码断言也通过。
