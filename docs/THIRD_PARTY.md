# 第三方来源与许可

[English](en/MODELS.md#licenses-and-attribution) | [中文模型与许可指南](zh-CN/MODELS.md#许可证与署名)

发布维护：hellcatjack <hellcatjack@gmail.com>。本仓库的 VoxBridge 与 Mac 集成源码以根目录 [Apache-2.0](../LICENSE) 发布；保留源码中的现有署名和第三方许可文件。

模型与依赖的许可独立于本仓库代码。安装脚本从固定来源下载资源，不将全部模型重新声明为本项目许可。

| 组件 | 来源及许可入口 |
|---|---|
| Qwen3-ASR | [Qwen 官方模型说明，Apache-2.0](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) |
| MLX | [ml-explore/mlx](https://github.com/ml-explore/mlx)，MIT |
| mlx-qwen3-asr | 通过固定 Python 依赖安装；参见所安装发行包的许可与元数据 |
| HY-MT1.5 | [腾讯模型许可](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/blob/265b2e615a7dc9b06c435dc878829ad99a512ba2/License.txt)，Tencent HY Community License；安装器保留该 `License.txt` |
| llama.cpp | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)，MIT |
| Kokoro 模型 | [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M)、[Kokoro-82M-v1.1-zh](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh)，Apache-2.0 |
| kokoro-onnx | [thewh1teagle/kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx)，MIT；中文图修改见[模型说明](MODELS.md) |
| Silero VAD / sherpa-onnx | [snakers4/silero-vad](https://github.com/snakers4/silero-vad)、[k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)，参见各项目许可 |
| ONNX Runtime | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime)，MIT |
| uv / 托管 Python | [astral-sh/uv](https://github.com/astral-sh/uv)、[python-build-standalone](https://github.com/astral-sh/python-build-standalone)，保留所下载发行包的各自许可 |
| hls.js | 随源码保留于 `VoxBridge/voxbridge/tts/vendor/`，许可文件同目录 |
| FFmpeg / eSpeak NG / Misaki | 由固定运行依赖提供，许可与第三方通知见各安装包；不内嵌进已提交的 App 二进制 |

旧版 VoxHalo 原生字幕客户端是本 App 字幕窗设计的参考；它的源代码保留在本仓库历史及备份分支。本次没有上传测试视频、测试录音、用户字幕记录或本机运行凭据。

日语发音使用 [pyopenjtalk 0.4.1](https://pypi.org/project/pyopenjtalk/0.4.1/)（MIT）及固定的 [OpenJTalk UTF-8 1.11 词典](https://github.com/r9y9/open_jtalk/releases/download/v1.11.1/open_jtalk_dic_utf_8-1.11.tar.gz)。词典的 BSD 3-clause `COPYING` 保留 NAIST、UniDic Consortium、OpenJTalk/HTS 署名；原生组件按安装包内各自许可分发。
