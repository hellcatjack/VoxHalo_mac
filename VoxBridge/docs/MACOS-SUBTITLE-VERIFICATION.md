# macOS 独立翻译字幕验证

日期：2026-09-14。版本：1.4.0（build 11）。

## 范围

参考 VoxHalo_mac `047ce85dbfc0ee13ca9fb63be36d5ea9edf466fa` 的透明非激活 NSPanel、置顶、鼠标穿透、跨 Space / 全屏辅助及显示器 UUID 设计，独立实现完成译文字幕。保留本机 Qwen 0.6B INT8、HY-MT Q8_0、Kokoro `am_michael` / `zm_029` 和端口 8024。

字幕直接消费原生 WebSocket 的 `sentence_committed`、`sentence_updated`、`sentence_translation`。只有 `is_stable == true`、已知句子及匹配 revision 的完整译文会显示；草稿、增量、汇总消息及旧 revision 不显示。按原文顺序阻止旧句的延迟结果覆盖新句。开始、清空、停止及失败收尾清除字幕；停止期间允许最后一句正常完成。句子 ID / revision 参与分页身份，重复的完整译文重新从第一页显示。

## 已执行验证

- 全量原生源文件以 Swift 5 编译；基础、渲染和真实会话测试使用 `-warnings-as-errors`。
- `SubtitleFoundationChecks.swift`：完成条件、错误类型、旧结果、修订、身份变化、重置、300 条元数据上限；偏好容错解码、保存恢复、独立存储及多屏安全坐标。
- `SubtitleOverlayChecks.swift`：中英与 emoji 分页拼接无损；640×480 和 1470×880 区域下的字号 12/36/144、最大阴影、最小宽度，逐页检查 CoreText 实际可见文本范围；中英渲染图；透明鼠标穿透窗口属性；异步翻页后重复句回到第一页，结束后隐藏清空。
- `NativeSubtitlePipelineChecks.swift`：同一个 NativeSession 顺序运行中文→英文和英文→中文。输入分别为已存测试视频 q5tBWsDc8gI 的 13 秒片段，以及 12.7547 秒英文合成教会文本。按实际时间发送 PCM，无浏览器、无麦克风采集、本机不播放；保留后端翻译和 TTS。显示了 3 / 4 条完整译文，逐条匹配后端完成译文；识别文本先出现时字幕为空；两轮停止后字幕为空，producer 和 listener 全部释放。
- 实际测试报告：`artifacts/macos/subtitle-1.4.0/pipeline.json`；渲染图：同目录 `render.png`。测试用于检查字幕链路，不是 ASR 准确率基准。
- 已安装并打开 `/Applications/教会同声传译.app`，界面显示 1.4.0（build 11）。实际操作字幕设置：开启预览，修改颜色为 #FFE680、字号 42、阴影模糊 6 / 距离 3、顶部位置及另一已安装字体；坐标同步为 10%，重新打开窗口保留设置且预览关闭；独立读取 UserDefaults 确认已持久化。随后恢复默认白字、36 pt、黑色阴影、底部位置。
- 独立代码复核确认后端协议及生命周期一致，重复句分页问题已修复并补回归检查。

基础与渲染检查：

```sh
swiftc -warnings-as-errors -parse-as-library deploy/macos/app/SubtitleState.swift deploy/macos/app/SubtitlePreferences.swift tests/macos/SubtitleFoundationChecks.swift -o /tmp/subtitle-foundation-checks
/tmp/subtitle-foundation-checks
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library -framework AppKit deploy/macos/app/SubtitleState.swift deploy/macos/app/SubtitlePreferences.swift deploy/macos/app/SubtitleOverlay.swift tests/macos/SubtitleOverlayChecks.swift -o /tmp/voxbridge-subtitle-overlay-checks
/tmp/voxbridge-subtitle-overlay-checks
```

构建安装：`../.venv/bin/python tools/build_macos_app.py --desktop-link`。实际外接显示器热插拔和其他 App 全屏切换仍需设备场景实测；目前通过 UUID 选择逻辑、安全几何及窗口属性检查。

安装后 macOS 的 TCC 日志确认新版签名触发了桌面文件夹访问弹窗，App 的服务检查正在等待此授权；已请用户手动允许。此时字幕设置界面可用，完整音频链路的验证来自安装前运行的同版 NativeSession 测试。未代点系统权限，也未修改系统隐私设置。
