# 传译模块与代码边界

[English](../en/ARCHITECTURE.md) | **简体中文** · [项目首页](../../README.zh-CN.md)

App 1.6.0 在第一阶段模块拆分的基础上开放八种语言、56 个互译方向。模型、中英提示词和语音切分、句子固化及原子音频提交算法沿用已验证配置。

## 模块分工

| 模块 | 职责 |
|---|---|
| `voxbridge/language_catalog.json` + `languages.py` | Python 与 Swift 共享同一目录资源；不可变语言配置与语言对；严格拒绝未开放语言或相同源/目标语言 |
| `interpretation/contracts.py` | 不可变翻译请求、会话独享的有界队列和最新修订索引 |
| `interpretation/translation_queue.py` | 翻译任务并行限制、等待和取消清理 |
| `interpretation/transcript.py` | 原文切分策略接口；保留中英策略，新增句子、缩写和 Unicode 字符规则 |
| `streaming/sentence_rules.py` | 已验证的句子、从句、缩写及未完句边界规则 |
| `translation/prompts.py` | 已验证提示词及领域策略，独立于网络请求 |
| `translation/backends.py` | 本地 Transformers 与 OpenAI 兼容 HTTP 客户端；本机使用后者访问本地 HY-MT |
| `translation/service.py` | 异步翻译、语言检查、重试、错误回调和诊断事件；不依赖 FastAPI |
| `tts/policy.py` | 目标语言的分块、发音语言标识与初始朗读时长估算 |
| `tts/output.py` | 准备、发布、状态及新会话代次的明确语音输出接口 |
| `tts/hls.py` | 既有合成调度与原子 PCM/HLS 提交，实现保持连续播放所需的先后约束 |
| `web/pages.py` | 从业务入口移出的历史网页模板，供兼容入口使用 |

核心模块可以独立导入，无需构造 Web 应用或打开浏览器。已有 CLI 导入名称继续可用，测试及外部工具可以逐步迁移。

## 一条句子的处理

原生 App 提交音频；ASR 修订原文；原文策略确定候选边界；现有提交状态机管理句子身份和修订。翻译请求携带句子 ID、修订、源文本、识别语言、序号、会话代次及语言对。翻译前后均保留过期结果检查。

完成的译文可以提前合成，但只有稳定缓冲确认的当前修订可以发布。共享语音发布器继续以同一提交点暴露本机 PCM 和 HLS 音频。播放器以真实播放进度驱动字幕，实际缓冲反馈继续影响固化等待；浏览器监控只读取状态。

## 复用方式

以下代码访问本机已经启动的 HY-MT 服务。它只翻译文本，不拥有 ASR、朗读或字幕状态。

```python
from voxbridge.interpretation.contracts import TranslationRequest
from voxbridge.translation.backends import OpenAIAPITranslator
from voxbridge.translation.service import TranslationService

backend = OpenAIAPITranslator(
    "http://127.0.0.1:8876", "hy-mt",
    max_new_tokens=256, sampling_profile="mac-verified",
)
service = TranslationService(backend)
request = TranslationRequest(
    sentence_id="example-1", revision=1, source_text="Welcome to PCCS.",
    language="English", seq=1, generation=1,
    source_language="English", target_language="Chinese", direction="en2zh",
)
# 在异步函数中执行：
translated_text = await service.translate(request)
```

请求使用模型语言字符串；`TranslationService` 会在推理前严格检查语言对与方向的一致性，拒绝未开放语言。创建用户会话时也可使用 `translation_pair(source, target)` 提前验证配置。显式配置的旧版中英文标签会保留原有提示词措辞。历史默认方向仅保留在 CLI 协议兼容入口。

## 后续扩展的边界

原生 App 从共同 JSON 目录构造语言对，保存 `zh2en`、`en2zh` 等字符串以兼容旧偏好。源/目标菜单不允许相同语言，结束采集后才能切换。`/api/languages` 返回八种语言与 56 个方向；明确传入无效方向时在修改会话前拒绝。

复杂 ASR 修订状态机和既有语音发布器继续由现有编排层管理，尚未将完整 WebSocket 会话拆成完全独立的通用会话类。

新增语言应实现对应文本与语音策略，验证读音、数字、混说、分句和输出语言检查，再更新后端能力声明及原生握手。中英特有的正则和教会术语不能直接套用于其他语言。拆分发布器时必须保留过期修订检查、取消后的提交屏障、已发布语音防重播以及连续 PCM 时间线。

## 验证

在 `VoxBridge/` 目录执行 `../.venv/bin/python -m pytest -q -rs`。核心测试直接调用独立服务；现有协议、修订、预翻译、TTS、播放器和字幕测试继续验证外部行为。

`tests/macos/NativeFileReplayChecks.swift` 是需要本机模型服务的人工集成测试入口：以每 100 ms 一帧回放至少十分钟的 16 kHz 单声道 PCM16，并使用生产 `NativeSession` 和 `NativeSpeechPlayer` 输出。它绕过麦克风采集设备，验证模型到实际播放的链路；不能代替系统音频录制权限测试。测试录音、PCM 和运行日志不进入 Git。

[八语言验证](EIGHT-LANGUAGES.md) · [第一阶段验收记录](PHASE1-VALIDATION.md)
