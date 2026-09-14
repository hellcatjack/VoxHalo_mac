# 中文 TTS 小数语速修复

> 名称说明：当前项目中文名称为“同声传译”。本文保留验证当时使用的应用名称与路径。

日期：2026-09-14。版本：1.4.2（build 13），基线 `69867eb`。

## 根因与范围

原中文 `kokoro-v1.1-zh.onnx` 将 speed 输入声明为 INT32，唯一使用它的节点 `/Cast_3` 随后转换为 FLOAT。本机固定的 kokoro-onnx 0.5.0 对 `input_ids` 模型也把 speed 转为 `np.int32`。因此界面与 Auto 策略即使正确选择 1.575，实际进入中文模型的仍是 1。上游亦记录了[同一缺陷](https://github.com/thewh1teagle/kokoro-onnx/issues/155)。

本次创建独立的 `kokoro-v1.1-zh-float-speed.onnx`，只改 speed 输入的类型声明，并用 `FloatSpeedKokoro` 为此类浮点输入模型传入 float32。保留固定 0.5.0 的 tokenizer、截断、首尾 padding、`voice[len(tokens)]`、分批及 trim；未全局升级依赖。英文仍走原 Kokoro 类。中文仍用 zm_029 男声，英文仍用 am_michael。

模型修复工具会确认所有 speed 消费节点直接转 FLOAT、ONNX 检查通过，并将改动字段还原后与原模型的完整序列化内容对比。原文件不覆盖，输出和报告均以无覆盖方式发布。模型权重、节点、词表、音色文件均未改动；TTS 自动追赶阈值、基础 speed 1.05、分句、300 ms 句末停顿、PCM / HLS 和字幕观察逻辑未改动。没有增加音频后处理加速。

## 实际音频时长

同一中文句子：“我们今天一起学习神的话语，愿主赐给大家平安与力量。”使用 zm_029、CPU 2 线程，通过生产 KokoroOnnxSynthesizer 合成。

| 传入 speed | 修复前 | 修复后 |
|---|---:|---:|
| 0.9 | 未测 | 5.675 s |
| 1.0 | 5.184 s | 5.184 s |
| 1.05（基础） | 5.184 s | 5.013 s |
| 1.26（Auto 1.2×） | 未测 | 4.117 s |
| 1.47（Auto 1.4×） | 未测 | 3.392 s |
| 1.575（Auto 1.5×） | 5.184 s | 3.221 s |

正常档到最高追赶档的音频时长减少约 35.7%。模型按音素帧预测时长，实测比例不要求精确等于 speed 比。固定 1.0 时长保持一致；模型自身含随机计算，不据此宣称重复生成的 PCM 逐字节相同。

原模型 SHA-256：`eefec708cbc7aba8e8129b5c2f7cb92e1fe7d281af1e1dd451592d9ff0714a0d`。

修复模型 SHA-256：`047e20ff94e676c7ed62b6f68778acc63a4922c194fe62c8708402b46da633d6`。

原始 WAV、before.json、after.json 和 model-repair.json 位于 `artifacts/macos/chinese-speed-1.4.2/`。

## 回归验证

- ONNX 边界回归先复现 int32 截断，修复后验证 0.9、1.05、1.26、1.47、1.575 全部以 float32 传入。
- 中英文逐调用语速及基础语速恢复、原 TTS / HLS 测试：104 passed、5 skipped（可选 FFmpeg 集成项）。
- Mac 启动、状态、原生 PCM 路由、分块测试：34 passed。
- 独立模型修复测试：8 passed，包含拒绝错误图、覆盖目标及报告别名覆盖模型的回归。
- 重新启动的 8024 服务已确认使用修复模型、zm_029、基础 speed 1.05 和 CPU 2 线程。
- NativeSubtitleAudioChecks 实播中文→英文、英文→中文，每轮源音频不超过 13 秒，均有 4 个完整语音段、4 次字幕切换并正常排空。字幕未抢先，各相邻 PCM 调度边界额外空档均为 0 ms；字幕更新落后该段输出起点约 8.1–49.5 ms。播放过程中持续调整字幕样式，原有字幕观察逻辑无需改动。报告为同目录 `native.json`。
- 已构建、签名校验并安装 `/Applications/教会同声传译.app`，界面版本确认为 1.4.2（build 13）。
- 测试结束后模型服务就绪，未留下采集或播放。新签名触发 macOS 桌面文件夹授权，系统 TCC 日志确认正在提示该权限；App 的服务检查等待用户响应。自动操作工具不能处理此系统窗口，需要用户点击“允许”后完成 App 内检查。

## 重新生成本机资源

已部署机器不需要重复生成。新部署先准备原始模型，再在 VoxBridge 根目录执行下列一次性命令。onnx 仅安装在隔离的工具目录，不加入服务运行时；目标文件和报告必须尚不存在。

```bash
../.venv/bin/python -m pip install --target artifacts/kokoro-repair-deps 'onnx==1.22.0'
PYTHONPATH=artifacts/kokoro-repair-deps ../.venv/bin/python tools/repair_kokoro_speed.py \
  ../models/kokoro/kokoro-v1.1-zh.onnx \
  ../models/kokoro/kokoro-v1.1-zh-float-speed.onnx \
  --report artifacts/kokoro-speed-repair.json
../.venv/bin/python tools/macos_service.py check
```

Mac 启动配置明确选择修复模型。已有服务必须停止后重新启动才能载入；仅重新打开监控网页不会更换已加载的模型。
