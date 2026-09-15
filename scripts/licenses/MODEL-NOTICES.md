# Model and component notices / 模型与组件许可

VoxHalo is independently maintained by hellcatjack. It is not affiliated with, sponsored by, or endorsed by Tencent or the other model authors. Free public availability of the application does not change third-party license terms.

VoxHalo 由 hellcatjack 独立维护，不隶属于腾讯或其他模型作者，也不代表其赞助或认可。应用公开免费不改变第三方许可证。

| Component / 组件 | Version and attribution / 版本与署名 | License text in this folder / 本目录许可全文 |
|---|---|---|
| Qwen3-ASR | Qwen3-ASR-0.6B, Qwen; commit 5eb144179a02acc5e5ba31e748d22b0cf3e303b0 | Apache-2.0.txt |
| HY-MT | HY-MT1.5-1.8B Q8_0, Tencent Hunyuan; commit 265b2e615a7dc9b06c435dc878829ad99a512ba2 | HY-MT-LICENSE.txt |
| Kokoro | Kokoro-82M v1.0 and v1.1-zh, hexgrad and contributors | Apache-2.0.txt |
| llama.cpp | b10809, commit 5266f24da75dc449bd56cbed7addb9c8e4a6a73e; Georgi Gerganov and contributors | llama.cpp-LICENSE.txt |
| Silero VAD | Silero contributors | Silero-VAD-LICENSE.txt |
| eSpeak NG (downloaded component) | eSpeak NG contributors | eSpeak-NG-COPYING.txt |
| Japanese dictionary / 日语词典 | OpenJTalk UTF-8 1.11; NAIST, UniDic Consortium, OpenJTalk/HTS contributors | OpenJTalk-Dictionary-COPYING.txt |
| Python and bundled libraries / Python 与内置库 | See python-distributions.json and Python-LICENSE.txt, generated in the App build | python-packages/ and Python-LICENSE.txt |

HY-MT's Territory excludes the European Union, United Kingdom and South Korea; review its complete conditions in HY-MT-LICENSE.txt before use. HY-MT 的许可地域不含欧盟、英国和韩国，请在使用前阅读其完整条款。

The model files and two speech-component wheels are downloaded during first-run installation from pinned upstream URLs, validated by SHA-256. The App itself does not include model weights, FFmpeg binaries or eSpeak NG binaries. 第一次安装从固定上游地址下载模型及两个语音组件 wheel，并验证 SHA-256；App 安装包不内嵌模型权重、FFmpeg 或 eSpeak NG 二进制文件。

The Chinese Kokoro ONNX graph receives the documented floating-point speed-input repair; its weights are unchanged. Qwen weights are quantized to INT8 in memory at load time. 中文 Kokoro 的 ONNX 图进行了浮点语速输入修复，权重不变；Qwen 在加载时在内存中量化为 INT8。

Upstream references / 上游链接:

- Qwen: https://huggingface.co/Qwen/Qwen3-ASR-0.6B/tree/5eb144179a02acc5e5ba31e748d22b0cf3e303b0
- HY-MT: https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/tree/265b2e615a7dc9b06c435dc878829ad99a512ba2
- Kokoro: https://huggingface.co/hexgrad/Kokoro-82M and https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh
- llama.cpp: https://github.com/ggml-org/llama.cpp/tree/5266f24da75dc449bd56cbed7addb9c8e4a6a73e
- Dictionary: https://github.com/r9y9/open_jtalk/releases/tag/v1.11.1
- Silero VAD: https://github.com/snakers4/silero-vad (MIT), distributed model from https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models
- imageio-ffmpeg 0.6.0: https://pypi.org/project/imageio-ffmpeg/0.6.0/ (BSD wrapper); downloaded FFmpeg 7.1 binary includes GPL components; see its build configuration and https://ffmpeg.org/legal.html
- eSpeak NG: https://github.com/espeak-ng/espeak-ng (GPL-3.0-or-later); downloaded by https://pypi.org/project/espeakng-loader/0.2.4/

Downloaded components retain their own notices and conditions. Their licenses are not replaced by the application's Apache license. 下载组件保留自身许可，不能以应用程序的 Apache 许可替代。
