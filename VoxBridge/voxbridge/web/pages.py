# coding=utf-8
# Copyright 2026 The Alibaba Qwen team.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# Extracted into reusable modules in 2026; see the repository change history.
"""Legacy browser presentation, retained unchanged during core extraction."""

INDEX_HTML_TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>语音识别与翻译</title>
  <style>
    :root{
      --bg-a:#edf4ea;
      --bg-b:#f6f0e6;
      --ink:#243126;
      --muted:#657267;
      --line:#ccd8c7;
      --surface:#f8fbf4;
      --surface-soft:rgba(255, 255, 247, 0.76);
      --surface-strong:#eef5ec;
      --ok:#2f7d55;
      --warn:#9b6b23;
      --err:#b5564b;
      --accent:#527e72;
      --accent-strong:#426c61;
    }

    * { box-sizing: border-box; }
    html, body { height: 100%; overflow: hidden; }
    body{
      margin:0;
      font-family: "Avenir Next", "Segoe UI", "Noto Sans SC", "PingFang SC", sans-serif;
      color:var(--ink);
      background:
        radial-gradient(circle at 16% 14%, rgba(178, 204, 164, 0.36) 0%, transparent 34%),
        radial-gradient(circle at 84% 82%, rgba(225, 203, 165, 0.38) 0%, transparent 36%),
        linear-gradient(160deg, var(--bg-a), var(--bg-b));
    }

    .wrap{
      height: 100%;
      height: 100svh;
      padding: 0;
      display: grid;
      place-items: stretch;
      overflow: hidden;
    }

    .card{
      position: relative;
      width: 100vw;
      height: 100vh;
      height: 100svh;
      border:0;
      border-radius: 0;
      background:
        linear-gradient(180deg, rgba(255, 255, 247, 0.84), rgba(240, 247, 235, 0.95)),
        var(--surface);
      padding: 14px 14px 12px;
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.72), 0 18px 46px rgba(75, 93, 70, 0.18);
      display: grid;
      grid-template-rows: auto auto minmax(0, 1fr);
      gap: 12px;
      overflow: hidden;
    }

    @supports (height: 100dvh){
      .wrap{ height: 100dvh; }
      .card{ height: 100dvh; }
    }

    .card.controls-hidden{
      grid-template-rows: auto minmax(0, 1fr);
      gap: 10px;
    }

    h1{
      margin:0;
      font-size: 16px;
      letter-spacing: .8px;
      font-weight: 700;
      color:#344239;
      padding-right: 80px;
    }

    .row{ display:flex; gap:10px; align-items:center; flex-wrap: wrap; }

    .control-bar{
      align-self: start;
      min-height: 0;
    }

    .card.controls-hidden .control-bar{
      display: none;
    }

    button{
      border:1px solid var(--line);
      border-radius: 10px;
      background: #f7faf3;
      color: #29372e;
      font-weight: 700;
      padding: 9px 15px;
      cursor: pointer;
      transition: background .15s ease, transform .04s ease, box-shadow .15s ease;
      box-shadow: 0 1px 0 rgba(255, 255, 255, 0.82);
    }
    button:hover{ background:#ffffff; box-shadow: 0 4px 14px rgba(82, 126, 114, 0.12); }
    button:active{ transform: translateY(1px); }
    button:disabled{ opacity:.55; cursor:not-allowed; }
    button.primary{ border-color:#4f8173; background:var(--accent); color:#fffdf5; }
    button.primary:hover{ background:var(--accent-strong); }
    button.danger{ border-color:#bf806f; background:#a45f4f; color:#fff8f1; }
    button.danger:hover{ background:#8f4f41; }

    .badge{
      border:1px solid var(--line);
      border-radius: 999px;
      padding: 5px 10px;
      font-size: 12px;
      color: #556257;
      background:#f3f7ee;
    }
    .ok{ color: var(--ok); border-color: #a8c8ae; background:#edf7ec; }
    .warn{ color: var(--warn); border-color: #dac18c; background:#faf3de; }
    .err{ color: var(--err); border-color: #e2aaa1; background:#fff0ec; }

    .direction-select{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      border:1px solid var(--line);
      border-radius: 10px;
      background:var(--surface-soft);
      padding: 6px 10px;
      font-size: 12px;
      color:var(--muted);
    }

    .font-size-control{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      border:1px solid var(--line);
      border-radius: 10px;
      background:var(--surface-soft);
      padding: 6px 10px;
      font-size: 12px;
      color:var(--muted);
    }

    .context-control{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      flex: 1 1 320px;
      min-width: min(320px, 100%);
      border:1px solid var(--line);
      border-radius: 10px;
      background:var(--surface-soft);
      padding: 6px 10px;
      font-size: 12px;
      color:var(--muted);
    }

    .context-control textarea{
      flex: 1 1 auto;
      min-width: 120px;
      height: 30px;
      max-height: 64px;
      resize: vertical;
      border:1px solid #bdcbb7;
      border-radius: 8px;
      background:#fffdf7;
      color:#2f3c33;
      padding: 5px 8px;
      font: inherit;
      line-height: 1.35;
      outline: none;
    }

    .context-control textarea:focus{
      border-color:var(--accent);
      box-shadow: 0 0 0 2px rgba(82, 126, 114, 0.16);
    }

    .source-toggle{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      border:1px solid var(--line);
      border-radius: 10px;
      background:var(--surface-soft);
      padding: 6px 10px;
      font-size: 12px;
      color:var(--muted);
    }

    .listener-link{
      display: inline-flex;
      align-items: center;
      border:1px solid var(--line);
      border-radius: 10px;
      background:#f7faf3;
      padding: 8px 12px;
      font-size: 12px;
      color:#29372e;
      font-weight:700;
      text-decoration:none;
    }

    .listener-qr{
      display:grid;
      grid-template-columns:64px minmax(120px, 1fr);
      align-items:center;
      gap:10px;
      min-width:236px;
      padding:7px 11px 7px 7px;
      border:1px solid rgba(82, 126, 114, 0.28);
      border-radius:12px;
      background:rgba(255, 255, 247, 0.88);
      color:#29372e;
      text-decoration:none;
      box-shadow:0 4px 16px rgba(82, 126, 114, 0.1);
    }

    .listener-qr img{
      display:block;
      width:64px;
      height:64px;
      border-radius:7px;
    }

    .listener-qr span{
      display:grid;
      gap:3px;
      line-height:1.2;
    }

    .listener-qr strong{ font-size:12px; }
    .listener-qr small{ color:var(--muted); font-size:10px; }

    .source-toggle select{
      border:1px solid #bdcbb7;
      border-radius: 8px;
      background:#fffdf7;
      color:#2f3c33;
      padding: 4px 8px;
      font-size: 12px;
      outline: none;
    }

    .direction-select select{
      border:1px solid #bdcbb7;
      border-radius: 8px;
      background:#fffdf7;
      color:#2f3c33;
      padding: 4px 8px;
      font-size: 12px;
      outline: none;
    }

    .font-size-control input{
      width: 58px;
      border:1px solid #bdcbb7;
      border-radius: 8px;
      background:#fffdf7;
      color:#2f3c33;
      padding: 4px 7px;
      font-size: 12px;
      outline: none;
      text-align: center;
    }

    .direction-select select:focus{
      border-color:var(--accent);
      box-shadow: 0 0 0 2px rgba(82, 126, 114, 0.16);
    }

    .source-toggle select:focus{
      border-color:var(--accent);
      box-shadow: 0 0 0 2px rgba(82, 126, 114, 0.16);
    }

    .font-size-control input:focus{
      border-color:var(--accent);
      box-shadow: 0 0 0 2px rgba(82, 126, 114, 0.16);
    }

    .control-reveal{
      position: absolute;
      top: 10px;
      right: 14px;
      z-index: 6;
      display: none;
      border-radius: 999px;
      padding: 6px 11px;
      background: rgba(255, 255, 247, 0.84);
      color: #4f685b;
      border-color: rgba(120, 145, 112, 0.36);
      backdrop-filter: blur(10px);
    }

    .card.controls-hidden .control-reveal{
      display: inline-flex;
      align-items: center;
      justify-content: center;
    }

    .subtitle-stage{
      position: relative;
      border:1px solid rgba(118, 139, 109, 0.24);
      border-radius: 14px;
      overflow: hidden;
      background:
        linear-gradient(180deg, rgba(255, 255, 252, 0.54) 0%, rgba(238, 246, 233, 0.8) 62%, rgba(229, 239, 224, 0.92) 100%),
        radial-gradient(circle at 50% -10%, rgba(255, 255, 255, 0.92), transparent 58%),
        linear-gradient(180deg, #f4f8ef, #e8f0e4);
      min-height: 0;
      height: 100%;
      display: grid;
      grid-template-rows: 2fr 1fr;
      align-items: stretch;
      padding: 0;
      gap: 0;
      box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.72);
    }

    .subtitle-lane{
      position: relative;
      min-height: 0;
      overflow: hidden;
    }

    .subtitle-lane + .subtitle-lane{
      border-top: 1px solid rgba(118, 139, 109, 0.2);
    }

    .subtitle-stack{
      width: 100%;
      height: 100%;
      text-align: center;
      white-space: pre-wrap;
      line-height: 2.3;
      word-break: break-word;
      overflow-wrap: anywhere;
      text-wrap: pretty;
      user-select: text;
      overflow-y: auto;
      overflow-x: hidden;
      scrollbar-width: thin;
      scrollbar-color: rgba(93, 119, 101, 0.28) transparent;
      -ms-overflow-style: none;
      padding: 10px 10px 14px;
    }

    .subtitle-stack::-webkit-scrollbar{
      width: 8px;
      height: 8px;
    }

    .subtitle-stack::-webkit-scrollbar-thumb{
      background: rgba(93, 119, 101, 0.24);
      border-radius: 999px;
    }

    .subtitle-stack::-webkit-scrollbar-track{
      background: transparent;
    }

    .subtitle-line{
      display: block;
      min-height: 1.2em;
    }

    .jump-latest{
      position: absolute;
      right: 12px;
      bottom: 14px;
      z-index: 3;
      border: 1px solid rgba(114, 138, 106, 0.34);
      border-radius: 999px;
      background: rgba(255, 255, 248, 0.88);
      color: #4b6658;
      font-size: 12px;
      font-weight: 700;
      padding: 6px 10px;
      opacity: 0;
      pointer-events: none;
      transform: translateY(6px);
      transition: opacity .16s ease, transform .16s ease, background .16s ease;
      backdrop-filter: blur(8px);
    }

    .jump-latest.is-visible{
      opacity: 1;
      pointer-events: auto;
      transform: translateY(0);
    }

    .jump-latest:hover{
      background: rgba(255, 255, 255, 0.96);
    }

    .line-enter{
      animation: subtitle-rise 220ms cubic-bezier(0.2, 0.9, 0.25, 1.0);
    }

    @keyframes subtitle-rise{
      from{
        opacity: 0;
        transform: translateY(12px);
      }
      to{
        opacity: 1;
        transform: translateY(0);
      }
    }

    #translation{
      min-height: 52px;
      font-family: "Avenir Next", "Segoe UI", "Helvetica Neue", sans-serif;
      font-size: var(--subtitle-top-font-size, clamp(28px, 3.3vw, 42px));
      font-weight: 750;
      color: #1f302b;
      letter-spacing: 0.02em;
      text-shadow: 0 1px 0 rgba(255, 255, 255, 0.76);
    }

    #text{
      min-height: 34px;
      font-family: "Noto Sans SC", "PingFang SC", "Microsoft YaHei", sans-serif;
      font-size: var(--subtitle-bottom-font-size, clamp(16px, 2.25vw, 26px));
      font-weight: 560;
      color: #526644;
      text-shadow: 0 1px 0 rgba(255, 255, 255, 0.78);
    }

    #lang{
      display: none;
    }

    @media (max-width: 720px){
      .card{
        height: 100svh;
        min-height: 100svh;
        padding: 10px;
        gap: 10px;
      }
      h1{
        font-size: 14px;
        letter-spacing: .5px;
        padding-right: 66px;
      }
      .control-bar{
        align-items: stretch;
        gap: 8px;
      }
      .control-bar button,
      .control-bar .listener-link{
        flex: 1 1 calc(50% - 8px);
        justify-content: center;
      }
      .listener-qr{
        flex:1 1 100%;
        min-width:0;
        grid-template-columns:54px minmax(0, 1fr);
        padding:6px;
      }
      .listener-qr img{ width:54px; height:54px; }
      .badge{
        flex: 1 0 100%;
      }
      .source-toggle,
      .direction-select,
      .font-size-control,
      .context-control{
        flex: 1 1 100%;
        min-width: 0;
        justify-content: space-between;
      }
      .source-toggle select,
      .direction-select select{
        max-width: 62%;
      }
      .font-size-control input{
        width: 72px;
      }
      .subtitle-stage{
        min-height: 0;
        height: 100%;
      }
      .subtitle-stack{
        padding: 8px 7px 12px;
        line-height: 2.05;
      }
      #translation{
        font-size: var(--subtitle-top-font-size, clamp(22px, 7vw, 32px));
      }
      #text{
        font-size: var(--subtitle-bottom-font-size, clamp(14px, 4.8vw, 20px));
      }
      .control-reveal{
        top: 8px;
        right: 10px;
        padding: 5px 9px;
      }
    }

    @supports (height: 100dvh){
      @media (max-width: 720px){
        .card{
          height: 100dvh;
          min-height: 100dvh;
        }
      }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div id="appCard" class="card">
      <h1>语音识别与翻译</h1>
      <button id="controlReveal" class="control-reveal" type="button" hidden aria-controls="controlBar" aria-expanded="false">控制</button>

      <div id="controlBar" class="row control-bar">
        <button id="btnStart" class="primary">Start</button>
        <button id="btnStop" class="danger" disabled>Stop</button>
        <span id="status" class="badge warn">Idle</span>
        <label class="source-toggle" for="inputSourceSelect">
          <span id="inputSourceLabel">输入源</span>
          <select id="inputSourceSelect">
            <option value="mic">麦克风</option>
            <option value="system">系统声音</option>
          </select>
        </label>
        <label class="direction-select" for="translationDirectionSelect">
          <span id="translationDirectionLabel">翻译方向</span>
          <select id="translationDirectionSelect">
            <option value="zh2en">中文 -> 英文</option>
            <option value="en2zh">英文 -> 中文</option>
          </select>
        </label>
        <div class="direction-select" aria-label="语音识别引擎">
          <span>语音识别 ASR</span>
          <strong>Qwen3-ASR</strong>
        </div>
        __PUBLIC_LISTENER_CARD__
        <label class="font-size-control" for="subtitleTopFontInput">
          <span>上方字号</span>
          <input id="subtitleTopFontInput" aria-label="上方字幕字号" type="number" min="18" max="72" step="1" inputmode="numeric" placeholder="自动" />
        </label>
        <label class="font-size-control" for="subtitleBottomFontInput">
          <span>下方字号</span>
          <input id="subtitleBottomFontInput" aria-label="下方字幕字号" type="number" min="12" max="56" step="1" inputmode="numeric" placeholder="自动" />
        </label>
        <label class="context-control" for="asrContextInput">
          <span>专业术语 Context</span>
          <textarea
            id="asrContextInput"
            rows="1"
            spellcheck="false"
            autocomplete="off"
            placeholder="术语用逗号、空格或换行分隔"
          ></textarea>
        </label>
      </div>

      <div class="subtitle-stage">
        <div class="subtitle-lane">
          <div id="translation" class="subtitle-stack"></div>
          <button id="jumpLatestEn" class="jump-latest" type="button" hidden>最新</button>
        </div>
        <div class="subtitle-lane">
          <div id="text" class="subtitle-stack"></div>
          <button id="jumpLatestZh" class="jump-latest" type="button" hidden>最新</button>
        </div>
      </div>
      <div id="lang">-</div>
    </div>
  </div>

<script>
(() => {
  const TARGET_SR = 16000;
  const CHUNK_MS = __CHUNK_MS__;
  const CHUNK_SAMPLES = Math.max(1, Math.round(TARGET_SR * CHUNK_MS / 1000));
  const MAX_WS_BUFFERED_BYTES = 1024 * 1024;
  const MAX_SEND_QUEUE_BYTES = 2 * 1024 * 1024;
  const WEBSOCKET_DRAIN_TIMEOUT_MS = 4000;
  const STOP_FINAL_TIMEOUT_MS = 120000;
  const MAX_SUBTITLE_HISTORY = 100;
  const MAX_VISIBLE_ROWS_ZH = 4;
  const MAX_VISIBLE_ROWS_EN = MAX_VISIBLE_ROWS_ZH + 2;
  const SUBTITLE_SCROLL_BOTTOM_EPSILON_PX = 24;
  const SUBTITLE_TOP_FONT_KEY = "voxbridge_subtitle_top_font_px";
  const SUBTITLE_BOTTOM_FONT_KEY = "voxbridge_subtitle_bottom_font_px";
  const ASR_CONTEXT_MAX_TERMS = __ASR_CONTEXT_MAX_TERMS__;
  const ASR_CONTEXT_MAX_CHARS = __ASR_CONTEXT_MAX_CHARS__;
  const ASR_CONTEXT_STORAGE_KEY = "voxbridge_asr_context_terms";
  const AUDIO_GATE_FRAME_MS = 20;
  const AUDIO_GATE_SPEECH_START_MS = 120;
  const AUDIO_GATE_SILENCE_MS = 700;
  const AUDIO_GATE_PRE_ROLL_MS = 400;
  const AUDIO_GATE_END_TAIL_MS = 400;
  const AUDIO_GATE_HEARTBEAT_MS = 1000;
  const USE_COMMITTED_SENTENCE_EVENTS = true;
  const SUBTITLE_TRACE_DEFAULT = __SUBTITLE_TRACE__;
  const SUBTITLE_TRACE_MAX_EVENTS = __SUBTITLE_TRACE_MAX_EVENTS__;

  const $ = (id) => document.getElementById(id);
  const appCard = $("appCard");
  const controlBar = $("controlBar");
  const controlReveal = $("controlReveal");
  const btnStart = $("btnStart");
  const btnStop = $("btnStop");
  const statusEl = $("status");
  const langEl = $("lang");
  const textEl = $("text");
  const translationEl = $("translation");
  const jumpLatestEn = $("jumpLatestEn");
  const jumpLatestZh = $("jumpLatestZh");
  const inputSourceSelect = $("inputSourceSelect");
  const inputSourceLabel = $("inputSourceLabel");
  const translationDirectionSelect = $("translationDirectionSelect");
  const translationDirectionLabel = $("translationDirectionLabel");
  const asrEngine = $("asrEngine");
  const asrEngineHint = $("asrEngineHint");
  const subtitleTopFontInput = $("subtitleTopFontInput");
  const subtitleBottomFontInput = $("subtitleBottomFontInput");
  const asrContextInput = $("asrContextInput");
  const rawTextEl = $("rawText");
  const languageSelect = $("languageSelect");
  const toggleEchoCancellation = $("toggleEchoCancellation");
  const toggleNoiseSuppression = $("toggleNoiseSuppression");
  const toggleAutoGainControl = $("toggleAutoGainControl");

  let running = false;
  let ws = null;
  let audioCtx = null;
  let mediaStream = null;
  let source = null;
  let processor = null;
  let workletNode = null;
  let sinkGain = null;
  let workletModuleUrl = null;
  let audioActivityGate = null;
  let pending = new Float32Array(0);
  let sendQueue = [];
  let queuedBytes = 0;
  let currentSegmentText = "";
  let subtitleSentencePairs = [];
  let currentTextTail = "";
  let currentTranslationTail = "";
  let zhLineNodes = new Map();
  let enLineNodes = new Map();
  let rawAsrText = "";
  let rawAsrLastSnapshot = "";
  let lastPartialSeq = 0;
  let awaitingFinal = false;
  let pendingFinalResolve = null;
  let pendingFinalReject = null;
  let finalTimer = null;
  let pendingStartResolve = null;
  let pendingStartReject = null;
  let pendingStartTimer = null;
  let watchdogTimer = null;
  let sessionStartedAt = 0;
  let lastCaptureAt = 0;
  let lastChunkSentAt = 0;
  let lastPartialAt = 0;
  let controlAutoHideTimer = null;
  let subtitleTraceEnabled = false;
  let subtitleTraceSeq = 0;
  let subtitleTraceEvents = [];
  let lastPartialTraceSeq = -1;
  let inputSource = "mic";
  let translationDirection = "zh2en";
  let activeContextMetadata = null;
  let asrEngineDescriptors = null;
  let controlsLocked = false;
  const autoScrollRaf = new WeakMap();
  const scrollFollowState = {
    zh: { follow: true, autoScrolling: false },
    en: { follow: true, autoScrolling: false },
  };

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  (() => {
    let enabled = !!SUBTITLE_TRACE_DEFAULT;
    try {
      const params = new URLSearchParams(location.search || "");
      const queryFlag = String(params.get("subtitle_trace") || params.get("trace") || "").trim().toLowerCase();
      if (["1", "true", "on", "yes"].includes(queryFlag)) enabled = true;
      if (["0", "false", "off", "no"].includes(queryFlag)) enabled = false;
      const saved = String(localStorage.getItem("subtitle_trace") || "").trim().toLowerCase();
      if (["1", "true", "on", "yes"].includes(saved)) enabled = true;
      if (["0", "false", "off", "no"].includes(saved)) enabled = false;
    } catch (err) {}
    subtitleTraceEnabled = enabled;
  })();

  (() => {
    let initial = "mic";
    try {
      const saved = String(localStorage.getItem("subtitle_input_source") || "").trim().toLowerCase();
      if (saved) initial = saved;
    } catch (err) {}
    applyInputSource(initial, { silent: true });
  })();

  (() => {
    let initial = "zh2en";
    try {
      const saved = String(localStorage.getItem("subtitle_translation_direction") || "").trim().toLowerCase();
      if (saved) initial = saved;
    } catch (err) {}
    applyTranslationDirection(initial, { silent: true });
  })();

  (() => {
    applySubtitleFontSizes(readSubtitleFontConfig(), { persist: false, silent: true });
  })();

  (() => {
    let initial = "qwen3-asr";
    try { initial = localStorage.getItem("voxbridge_asr_engine") || initial; } catch (err) {}
    applyAsrEngine(initial);
  })();

  (() => {
    if (!asrContextInput) return;
    try {
      asrContextInput.value = String(localStorage.getItem(ASR_CONTEXT_STORAGE_KEY) || "");
    } catch (err) {
      asrContextInput.value = "";
    }
  })();

  function traceSubtitle(event, payload = {}, force = false){
    if (!subtitleTraceEnabled && !force) return;
    const cap = Math.max(200, Number(SUBTITLE_TRACE_MAX_EVENTS || 1200));
    const row = Object.assign(
      {
        idx: ++subtitleTraceSeq,
        ts: Date.now(),
        event: String(event || ""),
      },
      (payload && typeof payload === "object") ? payload : { value: payload },
    );
    subtitleTraceEvents.push(row);
    if (subtitleTraceEvents.length > cap) {
      subtitleTraceEvents.splice(0, subtitleTraceEvents.length - cap);
    }
    if (subtitleTraceEnabled) {
      try {
        console.debug("[subtitle-trace]", row);
      } catch (err) {}
    }
  }

  function clearControlAutoHideTimer(){
    if (controlAutoHideTimer) {
      clearTimeout(controlAutoHideTimer);
      controlAutoHideTimer = null;
    }
  }

  function setControlBarHidden(hidden, reason = ""){
    if (!appCard || !controlBar) return;
    const next = !!hidden;
    const prev = appCard.classList.contains("controls-hidden");
    clearControlAutoHideTimer();
    appCard.classList.toggle("controls-hidden", next);
    controlBar.setAttribute("aria-hidden", next ? "true" : "false");
    if (controlReveal) {
      controlReveal.hidden = !next;
      controlReveal.setAttribute("aria-expanded", next ? "false" : "true");
      controlReveal.setAttribute("aria-hidden", next ? "false" : "true");
    }
    if (prev !== next) {
      traceSubtitle("controls_hidden_changed", {
        hidden: next,
        reason: String(reason || ""),
      });
    }
  }

  function scheduleControlBarAutoHide(delayMs = 5200){
    clearControlAutoHideTimer();
    if (!running || awaitingFinal) return;
    controlAutoHideTimer = setTimeout(() => {
      controlAutoHideTimer = null;
      if (!running || awaitingFinal) return;
      if (controlBar && controlBar.contains(document.activeElement)) {
        scheduleControlBarAutoHide(1800);
        return;
      }
      setControlBarHidden(true, "auto_timeout");
    }, Math.max(1200, Number(delayMs || 0)));
  }

  function revealControlBarTemporarily(reason = "manual_reveal"){
    setControlBarHidden(false, reason);
    scheduleControlBarAutoHide(6200);
  }

  function clearCommittedTentativeTailNow(){
    if (currentTextTail) {
      traceSubtitle("tail_cleared", { by: "clearCommittedTentativeTailNow", prevLen: currentTextTail.length });
    }
    currentTextTail = "";
  }

  function readBackendStability(msg){
    const source = msg && typeof msg === "object" ? msg : {};
    const meta = source.stability && typeof source.stability === "object" ? source.stability : {};
    const metaStable = typeof meta.is_stable === "boolean" ? meta.is_stable : null;
    const msgStable = typeof source.is_stable === "boolean" ? source.is_stable : null;
    const hasSignal = metaStable !== null || msgStable !== null;
    return {
      hasSignal,
      isStable: metaStable !== null ? metaStable : (msgStable === true),
      phase: String(meta.phase || ""),
      reason: String(meta.reason || ""),
      unstableChars: Number(meta.unstable_chars || 0),
    };
  }

  function updateCommittedTentativeTailFromBackend(tailText, stability){
    const nextTail = String(tailText || "").trim();
    const signal = stability && typeof stability === "object" ? stability : { hasSignal: false, isStable: false, phase: "" };
    if (nextTail) {
      if (nextTail !== currentTextTail) {
        traceSubtitle("tail_set", {
          by: "updateCommittedTentativeTailFromBackend",
          nextLen: nextTail.length,
          stable: !!signal.isStable,
          phase: String(signal.phase || ""),
        });
      }
      currentTextTail = nextTail;
      return;
    }
    if (!currentTextTail) {
      currentTextTail = "";
      return;
    }

    if (!signal.hasSignal || signal.isStable || signal.phase === "solidified" || signal.phase === "final") {
      traceSubtitle("tail_cleared", {
        by: "backend_stability",
        prevLen: currentTextTail.length,
        stable: !!signal.isStable,
        phase: String(signal.phase || ""),
        reason: String(signal.reason || ""),
      });
      currentTextTail = "";
      return;
    }
    traceSubtitle("tail_kept_unstable", {
      prevLen: currentTextTail.length,
      phase: String(signal.phase || ""),
      reason: String(signal.reason || ""),
      unstableChars: Number(signal.unstableChars || 0),
    });
  }

  function isLocalhost(){
    return (
      location.hostname === "localhost" ||
      location.hostname === "127.0.0.1" ||
      location.hostname === "::1"
    );
  }

  function setStatus(msg, cls){
    const prev = String(statusEl.textContent || "");
    statusEl.textContent = msg;
    statusEl.className = "badge " + (cls || "");
    if (prev !== msg) {
      traceSubtitle("status_changed", { prev, next: String(msg || ""), cls: String(cls || "") });
    }
  }

  function listeningStatus(sourceMode, started = activeContextMetadata){
    let base = "Listening / 识别中";
    if (sourceMode === "system") {
      base = "Listening (system audio) / 识别中(系统声音)";
    } else if (processor) {
      base = "Listening (fallback) / 识别中(兼容模式)";
    }
    const contextSuffix = started && started.asr_context_active
      ? ` · Context 已启用 · ${Number(started.asr_context_term_count || 0)} 个术语`
      : "";
    const engineSuffix = started && started.asr_engine === "zipformer-xl"
      ? " · Zipformer XL" : " · Qwen3-ASR";
    return base + engineSuffix + contextSuffix;
  }

  function normalizeTranslationDirection(raw){
    const text = String(raw || "").trim().toLowerCase();
    if (text === "en2zh" || text === "en->zh") return "en2zh";
    return "zh2en";
  }

  function normalizeInputSource(raw){
    const text = String(raw || "").trim().toLowerCase();
    return text === "system" ? "system" : "mic";
  }

  function parseAsrContextTerms(raw){
    const terms = [];
    const seen = new Set();
    for (const part of String(raw || "").split(/[\s,，]+/u)) {
      const term = String(part || "").trim();
      if (!term) continue;
      const key = term.toLocaleLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      terms.push(term);
    }
    return terms;
  }

  function asrContextTermHasSentencePunctuation(term){
    const value = String(term || "");
    if (/[。！？!?；;:：]/u.test(value)) return true;
    if (!/\.["'”’)\]）】》]*$/u.test(value)) return false;
    return !/^(?:[A-Z]\.){2,}$/u.test(value);
  }

  function readAsrContextTerms(){
    if (selectedAsrEngine() === "zipformer-xl") return [];
    const terms = parseAsrContextTerms(asrContextInput ? asrContextInput.value : "");
    const invalidIndex = terms.findIndex(asrContextTermHasSentencePunctuation);
    if (invalidIndex >= 0) {
      throw new Error(`Context 第 ${invalidIndex + 1} 个术语包含句子标点`);
    }
    if (terms.length > ASR_CONTEXT_MAX_TERMS) {
      throw new Error(`Context 最多允许 ${ASR_CONTEXT_MAX_TERMS} 个术语`);
    }
    const chars = terms.join(" ").length;
    if (chars > ASR_CONTEXT_MAX_CHARS) {
      throw new Error(`Context 最多允许 ${ASR_CONTEXT_MAX_CHARS} 个字符`);
    }
    return terms;
  }

  function persistAsrContextInput(){
    if (!asrContextInput) return;
    const raw = String(asrContextInput.value || "");
    try {
      if (raw.trim()) localStorage.setItem(ASR_CONTEXT_STORAGE_KEY, raw);
      else localStorage.removeItem(ASR_CONTEXT_STORAGE_KEY);
    } catch (err) {}
  }

  function selectedInputSource(){
    if (!inputSourceSelect) return inputSource;
    return normalizeInputSource(inputSourceSelect.value);
  }

  function applyInputSource(source, options = {}){
    const normalized = normalizeInputSource(source);
    const prev = inputSource;
    inputSource = normalized;
    if (inputSourceSelect) {
      inputSourceSelect.value = normalized;
    }
    if (inputSourceLabel) {
      inputSourceLabel.textContent = normalized === "system" ? "系统声音" : "麦克风";
    }
    try {
      localStorage.setItem("subtitle_input_source", normalized);
    } catch (err) {}
    const silent = !!(options && options.silent);
    if (!silent && prev !== normalized) {
      traceSubtitle("input_source_ui_set", { prev, next: normalized });
    }
    return normalized;
  }

  function selectedTranslationDirection(){
    if (!translationDirectionSelect) return translationDirection;
    return normalizeTranslationDirection(translationDirectionSelect.value);
  }

  function selectedAsrEngine(){
    return "qwen3-asr";
  }

  function syncAsrControls(){
    if (asrContextInput) asrContextInput.disabled = controlsLocked;
  }

  function applyAsrEngine(value){
    syncAsrControls();
    try { localStorage.setItem("voxbridge_asr_engine", selectedAsrEngine()); } catch (err) {}
  }

  function applyTranslationDirection(direction, options = {}){
    const normalized = normalizeTranslationDirection(direction);
    const prev = translationDirection;
    translationDirection = normalized;
    if (translationDirectionSelect) {
      translationDirectionSelect.value = normalized;
    }
    if (translationDirectionLabel) {
      translationDirectionLabel.textContent = "翻译方向";
    }
    syncAsrControls();
    try {
      localStorage.setItem("subtitle_translation_direction", normalized);
    } catch (err) {}
    const silent = !!(options && options.silent);
    if (!silent && prev !== normalized) {
      traceSubtitle("translation_direction_ui_set", { prev, next: normalized });
    }
    return normalized;
  }

  function sendTranslationDirection(direction){
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    const next = normalizeTranslationDirection(direction);
    try {
      ws.send(JSON.stringify({ type: "set_translation_direction", translation_direction: next }));
      traceSubtitle("translation_direction_sent", { next });
    } catch (err) {
      traceSubtitle("translation_direction_send_failed", { next, error: String(err || "") });
    }
  }

  function normalizeSubtitleFontPx(raw, minPx, maxPx){
    const text = String(raw == null ? "" : raw).trim();
    if (!text) return "";
    const value = Number(text);
    if (!Number.isFinite(value)) return "";
    return Math.max(Number(minPx || 12), Math.min(Number(maxPx || 72), Math.round(value)));
  }

  function readSubtitleFontConfig(){
    let top = "";
    let bottom = "";
    try {
      top = normalizeSubtitleFontPx(localStorage.getItem(SUBTITLE_TOP_FONT_KEY), 18, 72);
      bottom = normalizeSubtitleFontPx(localStorage.getItem(SUBTITLE_BOTTOM_FONT_KEY), 12, 56);
    } catch (err) {}
    return { top, bottom };
  }

  function writeSubtitleFontConfig(config){
    const next = config && typeof config === "object" ? config : {};
    const top = normalizeSubtitleFontPx(next.top, 18, 72);
    const bottom = normalizeSubtitleFontPx(next.bottom, 12, 56);
    try {
      if (top) localStorage.setItem(SUBTITLE_TOP_FONT_KEY, String(top));
      else localStorage.removeItem(SUBTITLE_TOP_FONT_KEY);
      if (bottom) localStorage.setItem(SUBTITLE_BOTTOM_FONT_KEY, String(bottom));
      else localStorage.removeItem(SUBTITLE_BOTTOM_FONT_KEY);
    } catch (err) {}
    return { top, bottom };
  }

  function subtitleComputedFontPx(element){
    if (!element || typeof getComputedStyle !== "function") return "";
    const value = Number.parseFloat(getComputedStyle(element).fontSize || "");
    if (!Number.isFinite(value)) return "";
    return String(Math.round(value));
  }

  function syncSubtitleFontInputs(config){
    const next = config && typeof config === "object" ? config : {};
    if (subtitleTopFontInput) {
      subtitleTopFontInput.value = next.top ? String(next.top) : "";
      subtitleTopFontInput.placeholder = subtitleComputedFontPx(translationEl) || "自动";
    }
    if (subtitleBottomFontInput) {
      subtitleBottomFontInput.value = next.bottom ? String(next.bottom) : "";
      subtitleBottomFontInput.placeholder = subtitleComputedFontPx(textEl) || "自动";
    }
  }

  function applySubtitleFontSizes(config, options = {}){
    const next = config && typeof config === "object" ? config : {};
    const top = normalizeSubtitleFontPx(next.top, 18, 72);
    const bottom = normalizeSubtitleFontPx(next.bottom, 12, 56);
    const rootStyle = document.documentElement.style;
    if (top) rootStyle.setProperty("--subtitle-top-font-size", `${top}px`);
    else rootStyle.removeProperty("--subtitle-top-font-size");
    if (bottom) rootStyle.setProperty("--subtitle-bottom-font-size", `${bottom}px`);
    else rootStyle.removeProperty("--subtitle-bottom-font-size");
    const normalized = { top, bottom };
    if (options && options.persist) {
      writeSubtitleFontConfig(normalized);
    }
    syncSubtitleFontInputs(normalized);
    if (!(options && options.silent)) {
      traceSubtitle("subtitle_font_config_set", {
        top: top || "auto",
        bottom: bottom || "auto",
        persist: !!(options && options.persist),
      });
    }
    return normalized;
  }

  function applySubtitleFontInputs(){
    applySubtitleFontSizes(
      {
        top: subtitleTopFontInput ? subtitleTopFontInput.value : "",
        bottom: subtitleBottomFontInput ? subtitleBottomFontInput.value : "",
      },
      { persist: true }
    );
  }

  function lockUI(active){
    controlsLocked = !!active;
    btnStart.disabled = active;
    btnStop.disabled = !active;
    if (inputSourceSelect) inputSourceSelect.disabled = active;
    if (translationDirectionSelect) translationDirectionSelect.disabled = active;
    syncAsrControls();
  }

  function lockUIFinishing(){
    controlsLocked = true;
    btnStart.disabled = true;
    btnStop.disabled = true;
    if (inputSourceSelect) inputSourceSelect.disabled = true;
    if (translationDirectionSelect) translationDirectionSelect.disabled = true;
    if (asrContextInput) asrContextInput.disabled = true;
    syncAsrControls();
  }

  function laneForContainer(container){
    if (container === textEl) return "zh";
    if (container === translationEl) return "en";
    return "unknown";
  }

  function containerForLane(lane){
    if (lane === "zh") return textEl;
    if (lane === "en") return translationEl;
    return null;
  }

  function buttonForLane(lane){
    if (lane === "zh") return jumpLatestZh;
    if (lane === "en") return jumpLatestEn;
    return null;
  }

  function isNearSubtitleBottom(container){
    if (!container) return true;
    const remaining = Math.max(
      0,
      Number(container.scrollHeight || 0) - Number(container.clientHeight || 0) - Number(container.scrollTop || 0)
    );
    return remaining <= SUBTITLE_SCROLL_BOTTOM_EPSILON_PX;
  }

  function updateJumpLatestButtons(){
    for (const lane of ["en", "zh"]) {
      const button = buttonForLane(lane);
      const container = containerForLane(lane);
      const state = scrollFollowState[lane];
      if (!button || !container || !state) continue;
      const hasOverflow = Number(container.scrollHeight || 0) > (Number(container.clientHeight || 0) + SUBTITLE_SCROLL_BOTTOM_EPSILON_PX);
      const visible = !state.follow && hasOverflow;
      button.hidden = !visible;
      button.classList.toggle("is-visible", visible);
      button.setAttribute("aria-hidden", visible ? "false" : "true");
      button.disabled = !visible;
      button.title = lane === "en" ? "滚动到最新英文字幕" : "滚动到最新中文字幕";
    }
  }

  function pauseSubtitleAutoFollow(lane, options = {}){
    const state = scrollFollowState[lane];
    if (!state || !state.follow) return false;
    state.follow = false;
    traceSubtitle("scroll_follow_paused", {
      lane,
      reason: String(options.reason || "user_scroll"),
      scrollTop: Math.round(Number(options.scrollTop || 0)),
    });
    updateJumpLatestButtons();
    return true;
  }

  function resumeSubtitleAutoFollow(lane, options = {}){
    const state = scrollFollowState[lane];
    if (!state) return false;
    const wasFollowing = !!state.follow;
    state.follow = true;
    if (!wasFollowing) {
      traceSubtitle("scroll_follow_resumed", {
        lane,
        reason: String(options.reason || "bottom_reached"),
      });
    }
    updateJumpLatestButtons();
    if (options.pin !== false) {
      pinScrollToBottom(containerForLane(lane), { force: true });
    }
    return !wasFollowing;
  }

  function bindSubtitleScrollTracking(container){
    if (!container || container.dataset.scrollBound === "1") return;
    const lane = laneForContainer(container);
    if (lane === "unknown") return;
    container.dataset.scrollBound = "1";
    container.addEventListener("scroll", () => {
      const state = scrollFollowState[lane];
      if (!state || state.autoScrolling) return;
      if (isNearSubtitleBottom(container)) {
        resumeSubtitleAutoFollow(lane, { reason: "user_bottom", pin: false });
        return;
      }
      pauseSubtitleAutoFollow(lane, {
        reason: "user_scroll",
        scrollTop: Number(container.scrollTop || 0),
      });
    }, { passive: true });
  }

  function resetSubtitleAutoFollow(){
    scrollFollowState.zh.follow = true;
    scrollFollowState.zh.autoScrolling = false;
    scrollFollowState.en.follow = true;
    scrollFollowState.en.autoScrolling = false;
    updateJumpLatestButtons();
  }

  function pinScrollToBottom(container, options = {}){
    if (!container) return;
    const lane = laneForContainer(container);
    const state = scrollFollowState[lane];
    const force = !!(options && options.force);
    if (state && !state.follow && !force) return;
    if (state) state.autoScrolling = true;
    container.scrollTop = container.scrollHeight;
    if (typeof requestAnimationFrame !== "function") {
      if (state) state.autoScrolling = false;
      return;
    }
    const prevHandle = autoScrollRaf.get(container);
    if (prevHandle) {
      cancelAnimationFrame(prevHandle);
    }
    const handle = requestAnimationFrame(() => {
      container.scrollTop = container.scrollHeight;
      if (state) state.autoScrolling = false;
      autoScrollRaf.delete(container);
    });
    autoScrollRaf.set(container, handle);
  }

  function setRawAsrText(text, options = {}){
    if (options && options.resetCurrent) {
      rawAsrLastSnapshot = "";
      if (rawTextEl) {
        rawTextEl.textContent = rawAsrText;
        pinScrollToBottom(rawTextEl);
      }
      return;
    }

    const next = String(text || "").trim();
    if (!next) return;
    const prev = String(rawAsrLastSnapshot || "");

    if (!rawAsrText) {
      rawAsrText = next;
    } else if (!prev) {
      rawAsrText = `${rawAsrText}\n${next}`;
    } else if (next.startsWith(prev)) {
      if (rawAsrText.endsWith(prev)) {
        rawAsrText = rawAsrText.slice(0, rawAsrText.length - prev.length) + next;
      } else {
        rawAsrText = `${rawAsrText}\n${next}`;
      }
    } else if (prev.startsWith(next)) {
      // Ignore temporary shrink rewrite from unstable partials.
      if (rawTextEl) {
        rawTextEl.textContent = rawAsrText;
        pinScrollToBottom(rawTextEl);
      }
      return;
    } else {
      rawAsrText = `${rawAsrText}\n${next}`;
    }

    rawAsrLastSnapshot = next;
    if (rawTextEl) {
      rawTextEl.textContent = rawAsrText;
      pinScrollToBottom(rawTextEl);
    }
  }

  function setCurrentSegmentText(nextText){
    currentSegmentText = String(nextText || "");
  }

  function combineSegments(segments){
    const parts = [];
    for (const seg of segments) {
      const text = String(seg || "").trim();
      if (!text) continue;
      parts.push(text);
    }
    return parts.join(" ").trim();
  }

  function resolveTentativeTail(nextText, committedText, tentativeText){
    const tentative = String(tentativeText || "").trim();
    if (tentative) return tentative;
    const full = String(nextText || "").trim();
    if (!full) return "";
    const committed = String(committedText || "").trim();
    if (!committed) return full;
    if (!full.startsWith(committed)) return "";
    const tail = full.slice(committed.length).trim();
    return tail;
  }

  function trimSubtitleHistory(){
    const maxKeep = Math.max(1, Number(MAX_SUBTITLE_HISTORY || 100));
    const overflow = Math.max(0, subtitleSentencePairs.length - maxKeep);
    if (overflow <= 0) return;
    const droppedIds = subtitleSentencePairs.slice(0, overflow).map((item) => String(item.sid || "")).slice(0, 8);
    subtitleSentencePairs = subtitleSentencePairs.slice(overflow);
    traceSubtitle("history_trimmed", {
      drop: overflow,
      remaining: subtitleSentencePairs.length,
      maxKeep,
      droppedIds,
    });
  }

  function upsertCommittedSentence(sentenceId, text, tsMs, options = {}){
    const zhText = String(text || "").trim();
    if (!zhText) return false;
    const allowOverwrite = options.allowOverwrite !== false;
    const sliceCommit = !!options.sliceCommit;
    const sid = String(sentenceId || "").trim();
    const now = Number(tsMs || Date.now());
    if (sid) {
      const foundIndex = subtitleSentencePairs.findIndex((item) => item.sid === sid);
      const found = foundIndex >= 0 ? subtitleSentencePairs[foundIndex] : null;
      if (found) {
        if (!allowOverwrite) {
          traceSubtitle("sentence_skip_overwrite", { sid, nextLen: zhText.length });
          return false;
        }
        if (found.zh === zhText) {
          if (sliceCommit && !found.sliceCommit) found.sliceCommit = true;
          traceSubtitle("sentence_noop", { sid, len: zhText.length, sliceCommit: !!sliceCommit });
          return false;
        }
        const prevLen = String(found.zh || "").length;
        found.zh = zhText;
        found.ts = Math.max(Number(found.ts || now), now);
        if (sliceCommit && !found.sliceCommit) found.sliceCommit = true;
        traceSubtitle("sentence_updated_local", { sid, prevLen, nextLen: zhText.length, sliceCommit: !!sliceCommit });
        return true;
      }
    }
    subtitleSentencePairs.push({
      sid: sid || `local-${now}-${subtitleSentencePairs.length + 1}`,
      zh: zhText,
      en: "",
      ts: now,
      sliceCommit,
    });
    traceSubtitle("sentence_insert_local", {
      sid: sid || `local-${now}-${subtitleSentencePairs.length}`,
      len: zhText.length,
      count: subtitleSentencePairs.length,
      sliceCommit: !!sliceCommit,
    });
    return true;
  }

  function updateCommittedSentenceTranslation(sentenceId, text){
    const sid = String(sentenceId || "").trim();
    const enText = String(text || "").trim();
    if (!sid) return;
    if (!enText) {
      traceSubtitle("translation_skip_empty", { sid });
      return;
    }
    const found = subtitleSentencePairs.find((item) => item.sid === sid);
    if (!found) {
      traceSubtitle("translation_skip_missing_sentence", { sid, len: enText.length });
      return;
    }
    const cur = String(found.en || "").trim();
    if (cur === enText) {
      traceSubtitle("translation_noop", { sid, len: enText.length });
      return;
    }
    found.en = enText;
    if (cur) {
      traceSubtitle("translation_updated_local", {
        sid,
        prevLen: cur.length,
        len: enText.length,
      });
      return;
    }
    traceSubtitle("translation_set_local", { sid, len: enText.length });
  }

  function renderTranscript(){
    const rows = buildSubtitleRows();
    zhLineNodes = patchSubtitleContainer(
      textEl,
      rows,
      (row) => row.zh,
      zhLineNodes
    );
  }

  function renderTranslation(){
    const rows = buildSubtitleRows();
    enLineNodes = patchSubtitleContainer(
      translationEl,
      rows,
      (row) => row.en || " ",
      enLineNodes
    );
  }

  function buildSubtitleRows(){
    const committedRows = [];
    for (const item of subtitleSentencePairs) {
      const sid = String(item.sid || `row-${committedRows.length + 1}`);
      const zh = String(item.zh || "").trim();
      const en = String(item.en || "").trim();
      if (!zh && !en) continue;
      committedRows.push({ sid, zh, en });
    }
    const tail = String(currentTextTail || "").trim();

    if (USE_COMMITTED_SENTENCE_EVENTS) {
      const rows = committedRows.slice();
      if (tail || (running && committedRows.length > 0)) {
        rows.push({ sid: "__tail__", zh: tail, en: "" });
      }
      return rows;
    }

    const rows = committedRows.slice();
    if (tail) {
      rows.push({ sid: "__tail__", zh: tail, en: "" });
    }
    return rows;
  }

  function clearSubtitleDom(){
    if (textEl) textEl.replaceChildren();
    if (translationEl) translationEl.replaceChildren();
  }

  function subtitleChars(rows, pickText){
    let total = 0;
    for (const row of rows) {
      const text = String((pickText(row) || "")).trim();
      if (!text) continue;
      total += text.length;
    }
    return total;
  }

  function patchSubtitleContainer(container, rows, pickText, prevNodes){
    const keep = new Set(rows.map((row) => String(row.sid || "")));
    let removed = 0;
    const removedIds = [];
    for (const [sid, node] of prevNodes.entries()) {
      if (!keep.has(sid)) {
        node.remove();
        removed += 1;
        if (removedIds.length < 8) removedIds.push(String(sid || ""));
      }
    }

    const nextNodes = new Map();
    const orderedNodes = [];
    let created = 0;
    let changedText = 0;
    for (const row of rows) {
      const sid = String(row.sid || "");
      const text = String((pickText(row) || "")).trim() || " ";
      let node = prevNodes.get(sid);
      if (!node) {
        node = document.createElement("div");
        node.className = "subtitle-line line-enter";
        node.addEventListener("animationend", () => {
          node.classList.remove("line-enter");
        }, { once: true });
        created += 1;
      }
      if (node.textContent !== text) {
        node.textContent = text;
        changedText += 1;
      }
      node.dataset.sid = sid;
      nextNodes.set(sid, node);
      orderedNodes.push(node);
    }

    for (let i = 0; i < orderedNodes.length; i++) {
      const node = orderedNodes[i];
      const refNode = container.children[i] || null;
      if (refNode !== node) {
        container.insertBefore(node, refNode);
      }
    }
    pinScrollToBottom(container);
    const lane = container === textEl ? "zh" : (container === translationEl ? "en" : "unknown");
    if (removed > 0 || created > 0 || changedText > 0) {
      traceSubtitle("patch_container", {
        lane,
        rows: rows.length,
        prevRows: prevNodes.size,
        removed,
        created,
        changedText,
        removedIds,
        keepTail: !!currentTextTail,
        follow: lane !== "unknown" ? !!scrollFollowState[lane].follow : true,
      });
    }
    updateJumpLatestButtons();
    return nextNodes;
  }

  function clearPendingStartTimer(){
    if (pendingStartTimer !== null) clearTimeout(pendingStartTimer);
    pendingStartTimer = null;
  }

  function resolvePendingStart(msg){
    const resolve = pendingStartResolve;
    pendingStartResolve = null;
    pendingStartReject = null;
    clearPendingStartTimer();
    if (resolve) resolve(msg);
  }

  function rejectPendingStart(err){
    const reject = pendingStartReject;
    pendingStartResolve = null;
    pendingStartReject = null;
    clearPendingStartTimer();
    if (reject) reject(err instanceof Error ? err : new Error(String(err)));
  }

  function waitForStarted(timeoutMs = 10000){
    if (pendingStartResolve) throw new Error("start already pending");
    return new Promise((resolve, reject) => {
      pendingStartResolve = resolve;
      pendingStartReject = reject;
      pendingStartTimer = setTimeout(() => {
        rejectPendingStart(new Error("start acknowledgement timeout"));
      }, Math.max(1000, Number(timeoutMs) || 10000));
    });
  }

  function resetFinalWait(){
    if (finalTimer) {
      clearTimeout(finalTimer);
      finalTimer = null;
    }
    pendingFinalResolve = null;
    pendingFinalReject = null;
  }

  function rejectPendingFinal(err){
    if (!pendingFinalReject) return;
    const reject = pendingFinalReject;
    resetFinalWait();
    reject(err);
  }

  async function sendFinishAndAwaitFinal(mode, timeoutMs, reason = ""){
    if (!ws || ws.readyState !== WebSocket.OPEN) return null;
    if (pendingFinalResolve) {
      throw new Error("finish already pending");
    }
    return new Promise((resolve, reject) => {
      pendingFinalResolve = resolve;
      pendingFinalReject = reject;
      traceSubtitle("finish_sent", {
        mode: String(mode || ""),
        timeoutMs: Number(timeoutMs || 0),
        queuedBytes,
        sendQueueLen: sendQueue.length,
      });
      finalTimer = setTimeout(() => {
        rejectPendingFinal(new Error("final timeout"));
      }, timeoutMs);
      try {
        const payload = {type: "finish", mode};
        if (reason) payload.reason = String(reason);
        ws.send(JSON.stringify(payload));
      } catch (err) {
        rejectPendingFinal(err instanceof Error ? err : new Error(String(err)));
      }
    });
  }

  function resetSessionFlags(keepSubtitles = true){
    traceSubtitle("reset_session_flags", {
      keepSubtitles: !!keepSubtitles,
      committedCount: subtitleSentencePairs.length,
      tailLen: String(currentTextTail || "").length,
    });
    rejectPendingStart(new Error("session reset"));
    running = false;
    awaitingFinal = false;
    activeContextMetadata = null;
    resetFinalWait();
    sendQueue = [];
    queuedBytes = 0;
    pending = new Float32Array(0);
    if (audioActivityGate) audioActivityGate.reset();
    audioActivityGate = null;
    if (!keepSubtitles) {
      subtitleSentencePairs = [];
      clearSubtitleDom();
      zhLineNodes = new Map();
      enLineNodes = new Map();
      clearCommittedTentativeTailNow();
      currentTranslationTail = "";
      setCurrentSegmentText("");
    }
    sessionStartedAt = 0;
    lastCaptureAt = 0;
    lastChunkSentAt = 0;
    lastPartialAt = 0;
    if (watchdogTimer) {
      clearInterval(watchdogTimer);
      watchdogTimer = null;
    }
    lockUI(false);
    setControlBarHidden(false, "reset_session");
  }

  function startWatchdog(){
    if (watchdogTimer) clearInterval(watchdogTimer);
    watchdogTimer = setInterval(() => {
      if (!running) return;
      const now = Date.now();
      if (sessionStartedAt && now - sessionStartedAt > 8000 && lastCaptureAt === 0) {
        setStatus("No audio input / 未检测到音频输入", "warn");
        return;
      }
      if (
        sessionStartedAt &&
        now - sessionStartedAt > 8000 &&
        lastCaptureAt > 0 &&
        lastChunkSentAt === 0
      ) {
        setStatus("Upstream blocked / 上行拥塞", "warn");
        return;
      }
      if (
        ws &&
        ws.readyState === WebSocket.OPEN &&
        ws.bufferedAmount > MAX_WS_BUFFERED_BYTES &&
        lastPartialAt > 0 &&
        now - lastPartialAt > 10000
      ) {
        setStatus("Server busy / 识别延迟", "warn");
      }
    }, 1000);
  }

  function concatFloat32(a, b){
    const out = new Float32Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  function resampleLinear(input, srcSr, dstSr){
    if (srcSr === dstSr) return input;
    const ratio = dstSr / srcSr;
    const outLen = Math.max(0, Math.round(input.length * ratio));
    const out = new Float32Array(outLen);
    for (let i = 0; i < outLen; i++) {
      const x = i / ratio;
      const x0 = Math.floor(x);
      const x1 = Math.min(x0 + 1, input.length - 1);
      const t = x - x0;
      out[i] = input[x0] * (1 - t) + input[x1] * t;
    }
    return out;
  }

  function float32ToPcm16(samples){
    const out = new Int16Array(samples.length);
    for (let i = 0; i < samples.length; i++) {
      const s = Math.max(-1, Math.min(1, samples[i]));
      out[i] = s < 0 ? Math.round(s * 32768) : Math.round(s * 32767);
    }
    return out.buffer;
  }

  class AudioActivityGate {
    constructor(options = {}){
      this.sampleRate = Math.max(100, Number(options.sampleRate || TARGET_SR));
      this.frameMs = Math.max(5, Number(options.frameMs || AUDIO_GATE_FRAME_MS));
      this.frameSamples = Math.max(1, Math.round(this.sampleRate * this.frameMs / 1000));
      this.speechStartSamples = Math.max(
        this.frameSamples,
        Math.round(this.sampleRate * Number(options.speechStartMs || AUDIO_GATE_SPEECH_START_MS) / 1000)
      );
      this.silenceGateSamples = Math.max(
        this.frameSamples,
        Math.round(this.sampleRate * Number(options.silenceGateMs || AUDIO_GATE_SILENCE_MS) / 1000)
      );
      this.preRollSamples = Math.max(
        this.frameSamples,
        Math.round(this.sampleRate * Number(options.preRollMs || AUDIO_GATE_PRE_ROLL_MS) / 1000)
      );
      this.endTailSamples = Math.max(
        this.frameSamples,
        Math.round(this.sampleRate * Number(options.endTailMs || AUDIO_GATE_END_TAIL_MS) / 1000)
      );
      this.heartbeatSamples = Math.max(
        this.silenceGateSamples,
        Math.round(this.sampleRate * Number(options.heartbeatMs || AUDIO_GATE_HEARTBEAT_MS) / 1000)
      );
      this.onAudio = typeof options.onAudio === "function" ? options.onAudio : () => {};
      this.onControl = typeof options.onControl === "function" ? options.onControl : () => {};
      this.reset();
    }

    reset(){
      this.active = false;
      this.hasReportedSilence = false;
      this.captureSampleIndex = 0;
      this.speechRunSamples = 0;
      this.unreportedSilenceSamples = 0;
      this.noiseFloorDb = -55.0;
      this.framePending = new Float32Array(0);
      this.preRoll = new Float32Array(0);
      this.heldQuiet = new Float32Array(0);
    }

    _appendLimited(current, addition, limit){
      const combined = concatFloat32(current, addition);
      if (combined.length <= limit) return combined;
      return combined.slice(combined.length - limit);
    }

    _dbfs(frame){
      let sumSquares = 0.0;
      for (let i = 0; i < frame.length; i++) {
        const value = Number(frame[i] || 0);
        sumSquares += value * value;
      }
      const rms = Math.sqrt(sumSquares / Math.max(1, frame.length));
      return 20 * Math.log10(Math.max(rms, 1e-9));
    }

    _isCertainSilence(frame){
      const db = this._dbfs(frame);
      const threshold = Math.min(-50.0, this.noiseFloorDb + 6.0);
      const silent = db <= threshold;
      if (silent) {
        const boundedNoiseDb = Math.max(-75.0, db);
        this.noiseFloorDb = (0.98 * this.noiseFloorDb) + (0.02 * boundedNoiseDb);
      }
      return silent;
    }

    _emitAudio(samples){
      if (!samples || samples.length <= 0) return;
      this.onAudio(samples);
    }

    _emitSilence(){
      const samples = Math.max(0, Math.round(this.unreportedSilenceSamples));
      if (samples <= 0) return;
      this.onControl({
        type: "audio_silence",
        duration_ms: Math.max(1, Math.round(samples * 1000 / this.sampleRate)),
        capture_sample_index: Math.round(this.captureSampleIndex),
      });
      this.unreportedSilenceSamples = 0;
      this.hasReportedSilence = true;
    }

    _processFrame(frame){
      this.captureSampleIndex += frame.length;
      const certainSilence = this._isCertainSilence(frame);

      if (this.active) {
        if (certainSilence) {
          this.heldQuiet = concatFloat32(this.heldQuiet, frame);
          if (this.heldQuiet.length >= this.silenceGateSamples) {
            const endpointTail = this.heldQuiet.slice(
              0,
              Math.min(this.endTailSamples, this.heldQuiet.length)
            );
            this.active = false;
            this.speechRunSamples = 0;
            this.preRoll = this._appendLimited(
              new Float32Array(0),
              this.heldQuiet,
              this.preRollSamples
            );
            // Preserve a bounded low-energy sentence ending. The backend decodes
            // this tail once at finalization, while the remaining silence stays suppressed.
            this._emitAudio(endpointTail);
            this.unreportedSilenceSamples += this.heldQuiet.length;
            this.heldQuiet = new Float32Array(0);
            this._emitSilence();
          }
          return;
        }

        if (this.heldQuiet.length > 0) {
          const resumed = concatFloat32(this.heldQuiet, frame);
          this.heldQuiet = new Float32Array(0);
          this._emitAudio(resumed);
          return;
        }
        this._emitAudio(frame);
        return;
      }

      this.preRoll = this._appendLimited(this.preRoll, frame, this.preRollSamples);
      if (certainSilence) {
        this.speechRunSamples = 0;
        this.unreportedSilenceSamples += frame.length;
        const reportAt = this.hasReportedSilence
          ? this.heartbeatSamples
          : this.silenceGateSamples;
        if (this.unreportedSilenceSamples >= reportAt) this._emitSilence();
        return;
      }

      this.speechRunSamples += frame.length;
      if (this.speechRunSamples < this.speechStartSamples) return;

      this.active = true;
      this.speechRunSamples = 0;
      this.unreportedSilenceSamples = 0;
      const replay = this.preRoll;
      this.preRoll = new Float32Array(0);
      this.onControl({
        type: "audio_speech_start",
        capture_sample_index: Math.round(this.captureSampleIndex),
        preroll_samples: replay.length,
      });
      this._emitAudio(replay);
    }

    feed(samples){
      if (!samples || samples.length <= 0) return;
      const incoming = samples instanceof Float32Array
        ? samples
        : new Float32Array(samples);
      this.framePending = concatFloat32(this.framePending, incoming);
      while (this.framePending.length >= this.frameSamples) {
        const frame = this.framePending.slice(0, this.frameSamples);
        this.framePending = this.framePending.slice(this.frameSamples);
        this._processFrame(frame);
      }
    }

    finish(){
      if (this.framePending.length > 0) {
        const remainder = this.framePending;
        this.framePending = new Float32Array(0);
        this._processFrame(remainder);
      }
      if (!this.active && this.speechRunSamples > 0 && this.preRoll.length > 0) {
        const replay = this.preRoll;
        this.preRoll = new Float32Array(0);
        this.unreportedSilenceSamples = 0;
        this.onControl({
          type: "audio_speech_start",
          capture_sample_index: Math.round(this.captureSampleIndex),
          preroll_samples: replay.length,
        });
        this._emitAudio(replay);
        this.speechRunSamples = 0;
        this.active = true;
      }
      if (this.active && this.heldQuiet.length > 0) {
        this._emitAudio(this.heldQuiet);
        this.heldQuiet = new Float32Array(0);
      } else if (!this.active && this.unreportedSilenceSamples > 0) {
        this._emitSilence();
      }
    }
  }

  const audioGateDebugInstances = new Map();
  let nextAudioGateDebugId = 1;
  window.__audioActivityGateDebug = {
    create(options = {}) {
      const events = [];
      const gate = new AudioActivityGate({
        ...options,
        onAudio: (samples) => events.push({ type: "audio", samples: samples.length }),
        onControl: (message) => events.push({ type: "control", message: { ...message } }),
      });
      const id = nextAudioGateDebugId++;
      audioGateDebugInstances.set(id, {
        feedConstant(amplitude, durationMs) {
          const sampleCount = Math.max(0, Math.round(gate.sampleRate * Number(durationMs || 0) / 1000));
          gate.feed(new Float32Array(sampleCount).fill(Number(amplitude || 0)));
        },
        finish() { gate.finish(); },
        drainEvents() { return events.splice(0, events.length); },
      });
      return id;
    },
    get(id) { return audioGateDebugInstances.get(Number(id)); },
  };

  function describeStartError(err){
    const name = (err && err.name) ? err.name : "Error";
    const msg = (err && err.message) ? err.message : String(err || "unknown");
    if (name === "NotAllowedError" || name === "SecurityError") {
      return "音频采集权限被拒绝，请允许麦克风或屏幕共享音频。";
    }
    if (name === "NotFoundError") {
      return "未检测到可用音频源，请检查麦克风或共享源是否包含音频。";
    }
    if (name === "NotReadableError") {
      return "音频输入不可读，可能被其他应用占用或共享被系统阻止。";
    }
    if (name === "OverconstrainedError") {
      return "音频参数不兼容，已建议改用默认采集配置。";
    }
    if (name === "AbortError") {
      return "音频采集初始化被中断，请重试。";
    }
    if (name === "InvalidStateError") {
      return "请通过用户手势启动采集（点击 Start），然后重新选择输入源。";
    }
    return `${name}: ${msg}`;
  }

  function selectedLanguage(){
    if (!languageSelect) return "";
    return String(languageSelect.value || "").trim();
  }

  function selectedAsrLanguage(){
    const explicitLanguage = selectedLanguage();
    if (explicitLanguage) return explicitLanguage;
    return selectedTranslationDirection() === "en2zh" ? "English" : "Chinese";
  }

  function buildAudioConstraints(){
    return {
      channelCount: { ideal: 1 },
      echoCancellation: !!(toggleEchoCancellation && toggleEchoCancellation.checked),
      noiseSuppression: !!(toggleNoiseSuppression && toggleNoiseSuppression.checked),
      autoGainControl: !!(toggleAutoGainControl && toggleAutoGainControl.checked)
    };
  }

  async function openMicrophone(){
    if (!window.isSecureContext && !isLocalhost()) {
      throw new Error("远程访问麦克风需要 HTTPS。请确认通过 Caddy 的 https 地址访问。");
    }

    const modernGetUserMedia =
      navigator.mediaDevices &&
      typeof navigator.mediaDevices.getUserMedia === "function"
        ? navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices)
        : null;
    const legacyGetUserMedia =
      navigator.getUserMedia ||
      navigator.webkitGetUserMedia ||
      navigator.mozGetUserMedia ||
      navigator.msGetUserMedia;

    if (!modernGetUserMedia && !legacyGetUserMedia) {
      throw new Error(
        "当前页面环境不支持麦克风采集，请使用最新版 Chrome/Edge/Safari，并避免在受限内嵌 WebView 中打开。"
      );
    }

    const getUserMediaCompat = (constraints) => {
      if (modernGetUserMedia) {
        return modernGetUserMedia(constraints);
      }
      return new Promise((resolve, reject) => {
        legacyGetUserMedia.call(navigator, constraints, resolve, reject);
      });
    };

    const preferredConstraints = {
      audio: buildAudioConstraints(),
      video: false
    };
    try {
      return await getUserMediaCompat(preferredConstraints);
    } catch (err) {
      // Fallback for devices/browsers that reject advanced constraints.
      if (err && err.name === "OverconstrainedError") {
        return await getUserMediaCompat({ audio: true, video: false });
      }
      throw err;
    }
  }

  async function openSystemAudio(){
    if (!window.isSecureContext && !isLocalhost()) {
      throw new Error("远程访问系统声音需要 HTTPS。请确认通过 Caddy 的 https 地址访问。");
    }

    const getDisplayMedia =
      navigator.mediaDevices &&
      typeof navigator.mediaDevices.getDisplayMedia === "function"
        ? navigator.mediaDevices.getDisplayMedia.bind(navigator.mediaDevices)
        : null;
    if (!getDisplayMedia) {
      throw new Error("当前浏览器不支持系统声音采集，请使用最新版 Chrome/Edge。");
    }

    const preferredConstraints = {
      video: {
        displaySurface: "monitor",
      },
      audio: {
        suppressLocalAudioPlayback: false,
      },
      systemAudio: "include",
      preferCurrentTab: false,
      selfBrowserSurface: "exclude",
      surfaceSwitching: "include",
      monitorTypeSurfaces: "include",
    };

    let stream = null;
    try {
      stream = await getDisplayMedia(preferredConstraints);
    } catch (err) {
      if (err && (err.name === "OverconstrainedError" || err.name === "TypeError")) {
        stream = await getDisplayMedia({ video: true, audio: true });
      } else {
        throw err;
      }
    }

    const audioTracks = stream ? stream.getAudioTracks() : [];
    if (!audioTracks || audioTracks.length === 0) {
      if (stream) {
        for (const track of stream.getTracks()) {
          try { track.stop(); } catch (err) {}
        }
      }
      throw new Error("未检测到共享音频。请选择整屏共享并勾选系统音频后重试。");
    }

    const audioTrack = audioTracks[0];
    audioTrack.addEventListener("ended", () => {
      traceSubtitle("system_audio_track_ended", {});
      if (running && btnStop && !btnStop.disabled) {
        btnStop.click();
      }
    }, { once: true });
    return stream;
  }

  async function stopPipeline(resetPending = true){
    try {
      if (processor) {
        processor.disconnect();
        processor.onaudioprocess = null;
      }
      if (workletNode) {
        workletNode.port.onmessage = null;
        workletNode.disconnect();
      }
      if (sinkGain) sinkGain.disconnect();
      if (source) source.disconnect();
      if (audioCtx) await audioCtx.close();
      if (mediaStream) mediaStream.getTracks().forEach((t) => t.stop());
    } catch (err) {
      console.error(err);
    }
    processor = null;
    workletNode = null;
    sinkGain = null;
    source = null;
    audioCtx = null;
    mediaStream = null;
    if (workletModuleUrl) {
      try { URL.revokeObjectURL(workletModuleUrl); } catch (err) {}
      workletModuleUrl = null;
    }
    if (resetPending) {
      if (audioActivityGate) audioActivityGate.reset();
      audioActivityGate = null;
      pending = new Float32Array(0);
      sendQueue = [];
      queuedBytes = 0;
    }
  }

  function enqueueSendBuffer(frame){
    if (!frame || !(frame instanceof ArrayBuffer)) return;
    if (frame.byteLength <= 0) return;
    sendQueue.push({ payload: frame, bytes: frame.byteLength, droppable: true });
    queuedBytes += frame.byteLength;
    while (queuedBytes > MAX_SEND_QUEUE_BYTES && sendQueue.length > 1) {
      const dropIndex = sendQueue.findIndex((item) => item && item.droppable);
      if (dropIndex < 0) break;
      const dropped = sendQueue.splice(dropIndex, 1)[0];
      queuedBytes -= Number(dropped.bytes || 0);
    }
  }

  function flushPendingToQueue(force = false){
    while (pending.length >= CHUNK_SAMPLES) {
      const chunk = pending.slice(0, CHUNK_SAMPLES);
      pending = pending.slice(CHUNK_SAMPLES);
      enqueueSendBuffer(float32ToPcm16(chunk));
    }
    if (force && pending.length > 0) {
      enqueueSendBuffer(float32ToPcm16(pending));
      pending = new Float32Array(0);
    }
  }

  function enqueueAudioControl(message){
    if (!message || typeof message !== "object") return;
    flushPendingToQueue(true);
    const payload = JSON.stringify(message);
    sendQueue.push({
      payload,
      bytes: payload.length,
      droppable: false,
    });
    queuedBytes += payload.length;
  }

  function createLiveAudioActivityGate(){
    return new AudioActivityGate({
      sampleRate: TARGET_SR,
      frameMs: AUDIO_GATE_FRAME_MS,
      speechStartMs: AUDIO_GATE_SPEECH_START_MS,
      silenceGateMs: AUDIO_GATE_SILENCE_MS,
      preRollMs: AUDIO_GATE_PRE_ROLL_MS,
      endTailMs: AUDIO_GATE_END_TAIL_MS,
      heartbeatMs: AUDIO_GATE_HEARTBEAT_MS,
      onAudio(samples) {
        pending = concatFloat32(pending, samples);
        flushPendingToQueue();
        pump();
      },
      onControl(message) {
        enqueueAudioControl(message);
        traceSubtitle("audio_activity_control", {
          type: String(message.type || ""),
          durationMs: Number(message.duration_ms || 0),
          prerollSamples: Number(message.preroll_samples || 0),
          captureSampleIndex: Number(message.capture_sample_index || 0),
        });
        pump();
      },
    });
  }

  function onCapturedSamples(samples, srcSr){
    if (!running) return;
    if (!samples || samples.length === 0) return;
    lastCaptureAt = Date.now();
    const rs = resampleLinear(samples, srcSr, TARGET_SR);
    // The client suppresses only confirmed transport silence. Sentence and
    // segment boundaries remain exclusively controlled by the backend.
    if (!audioActivityGate) audioActivityGate = createLiveAudioActivityGate();
    audioActivityGate.feed(rs);
  }

  async function drainSendQueue(timeoutMs){
    const deadline = Date.now() + timeoutMs;
    while (ws && ws.readyState === WebSocket.OPEN && Date.now() < deadline) {
      pump();
      if (sendQueue.length === 0 && ws.bufferedAmount < 16384) {
        return true;
      }
      await sleep(20);
    }
    return sendQueue.length === 0;
  }

  async function buildCaptureGraph(){
    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    if (audioCtx.state === "suspended") {
      await audioCtx.resume();
    }
    source = audioCtx.createMediaStreamSource(mediaStream);

    if (audioCtx.audioWorklet && typeof AudioWorkletNode !== "undefined") {
      const moduleCode = `
        class MicCaptureProcessor extends AudioWorkletProcessor {
          process(inputs) {
            const input = inputs[0];
            if (input && input[0] && input[0].length > 0) {
              this.port.postMessage(input[0].slice(0));
            }
            return true;
          }
        }
        registerProcessor("mic-capture-processor", MicCaptureProcessor);
      `;
      workletModuleUrl = URL.createObjectURL(
        new Blob([moduleCode], { type: "application/javascript" })
      );
      await audioCtx.audioWorklet.addModule(workletModuleUrl);
      workletNode = new AudioWorkletNode(audioCtx, "mic-capture-processor", {
        numberOfInputs: 1,
        numberOfOutputs: 1,
        outputChannelCount: [1],
        channelCount: 1,
        channelCountMode: "explicit"
      });
      workletNode.port.onmessage = (evt) => {
        const frame = evt.data instanceof Float32Array ? evt.data : new Float32Array(evt.data || []);
        onCapturedSamples(frame, audioCtx.sampleRate);
      };
      sinkGain = audioCtx.createGain();
      sinkGain.gain.value = 0.0;
      source.connect(workletNode);
      workletNode.connect(sinkGain);
      sinkGain.connect(audioCtx.destination);
      return;
    }

    processor = audioCtx.createScriptProcessor(4096, 1, 1);
    processor.onaudioprocess = (evt) => {
      const in0 = evt.inputBuffer.getChannelData(0);
      onCapturedSamples(in0, audioCtx.sampleRate);
    };
    source.connect(processor);
    processor.connect(audioCtx.destination);
    setStatus("Listening (fallback) / 识别中(兼容模式)", "warn");
  }

  function handleServerMessage(evt){
    let msg = {};
    try {
      msg = JSON.parse(evt.data);
    } catch (err) {
      console.error("invalid json", err);
      return;
    }
    if (msg.type === "ready") {
      if (Array.isArray(msg.asr_engines)) asrEngineDescriptors = msg.asr_engines;
      syncAsrControls();
      const localDirectionBeforeStart = selectedTranslationDirection();
      if (msg.translation_direction) {
        const serverDirection = normalizeTranslationDirection(msg.translation_direction);
        if (serverDirection !== localDirectionBeforeStart) {
          traceSubtitle("ws_ready_direction_ignored", {
            serverDirection,
            localDirection: localDirectionBeforeStart,
          });
        }
      }
      traceSubtitle("ws_ready", {
        translationDirection: localDirectionBeforeStart,
      });
      setStatus("Connected / 已连接", "ok");
      return;
    }
    if (msg.type === "asr_loading") {
      setStatus("Loading Zipformer XL / 首次加载中文识别模型，请稍候", "warn");
      return;
    }
    if (msg.type === "started") {
      if (selectedAsrEngine() === "zipformer-xl" && msg.asr_engine !== "zipformer-xl") {
        rejectPendingStart(new Error("服务端未确认 Zipformer XL，请刷新页面或检查服务版本"));
        return;
      }
      if (msg.asr_engine) applyAsrEngine(msg.asr_engine);
      activeContextMetadata = {
        asr_engine: String(msg.asr_engine || "qwen3-asr"),
        asr_context_active: !!msg.asr_context_active,
        asr_context_term_count: Number(msg.asr_context_term_count || 0),
        asr_context_chars: Number(msg.asr_context_chars || 0),
      };
      resolvePendingStart(msg);
      if (msg.translation_direction) {
        applyTranslationDirection(msg.translation_direction);
      }
      traceSubtitle("ws_started", {
        language: String(msg.language || ""),
        translationDirection: String(msg.translation_direction || selectedTranslationDirection()),
        contextActive: !!msg.asr_context_active,
        contextTermCount: Number(msg.asr_context_term_count || 0),
        contextChars: Number(msg.asr_context_chars || 0),
      });
      if (msg.language) {
        if (langEl) langEl.textContent = msg.language;
      } else {
        if (langEl) langEl.textContent = "-";
      }
      setCurrentSegmentText("");
      setRawAsrText("", { resetCurrent: true });
      resetSubtitleAutoFollow();
      clearCommittedTentativeTailNow();
      currentTranslationTail = "";
      renderTranscript();
      renderTranslation();
      return;
    }
    if (msg.type === "translation_direction") {
      const direction = applyTranslationDirection(msg.translation_direction);
      traceSubtitle("ws_translation_direction", { direction });
      return;
    }
    if (msg.type === "sentence_committed") {
      if (!USE_COMMITTED_SENTENCE_EVENTS) return;
      lastPartialAt = Date.now();
      traceSubtitle("ws_sentence_committed", {
        sid: String(msg.sentence_id || ""),
        len: String(msg.text || "").trim().length,
        sliceCommit: !!msg.slice_commit,
        beforeCount: subtitleSentencePairs.length,
      });
      const changed = upsertCommittedSentence(
        msg.sentence_id,
        msg.text || "",
        msg.ts_ms || Date.now(),
        { sliceCommit: !!msg.slice_commit }
      );
      if (!changed) return;
      trimSubtitleHistory();
      renderTranscript();
      renderTranslation();
      if (running) {
        setStatus("Listening / 识别中", "ok");
      }
      return;
    }
    if (msg.type === "sentence_updated") {
      if (!USE_COMMITTED_SENTENCE_EVENTS) return;
      lastPartialAt = Date.now();
      const sid = String(msg.sentence_id || "").trim();
      const nextText = String(msg.text || "").trim();
      const current = sid ? subtitleSentencePairs.find((item) => String(item.sid || "") === sid) : null;
      const prevText = current ? String(current.zh || "").trim() : "";
      const allowOverwrite = true;
      traceSubtitle("ws_sentence_updated", {
        sid,
        len: nextText.length,
        prevLen: prevText.length,
        allowOverwrite,
      });
      const changed = upsertCommittedSentence(
        sid,
        nextText,
        msg.ts_ms || Date.now(),
        { allowOverwrite, sliceCommit: !!msg.slice_commit }
      );
      if (!changed) return;
      trimSubtitleHistory();
      renderTranscript();
      renderTranslation();
      return;
    }
    if (msg.type === "sentence_translation") {
      if (!USE_COMMITTED_SENTENCE_EVENTS) return;
      lastPartialAt = Date.now();
      traceSubtitle("ws_sentence_translation", {
        sid: String(msg.sentence_id || ""),
        len: String(msg.translation || "").trim().length,
      });
      updateCommittedSentenceTranslation(msg.sentence_id, msg.translation || "");
      renderTranslation();
      return;
    }
    if (msg.type === "sentence_reset") {
      if (!USE_COMMITTED_SENTENCE_EVENTS) return;
      lastPartialAt = Date.now();
      traceSubtitle("ws_sentence_reset", {
        reason: String(msg.reason || ""),
        beforeCount: subtitleSentencePairs.length,
      });
      subtitleSentencePairs = [];
      setCurrentSegmentText("");
      setRawAsrText("", { resetCurrent: true });
      resetSubtitleAutoFollow();
      clearSubtitleDom();
      zhLineNodes = new Map();
      enLineNodes = new Map();
      clearCommittedTentativeTailNow();
      currentTranslationTail = "";
      renderTranscript();
      renderTranslation();
      return;
    }
    if (msg.type === "partial") {
      lastPartialAt = Date.now();
      lastPartialSeq = Number(msg.seq || lastPartialSeq || 0);
      if (langEl) langEl.textContent = msg.language || "-";
      const nextText = String(msg.text || "");
      setRawAsrText(nextText);
      if (USE_COMMITTED_SENTENCE_EVENTS) {
        setCurrentSegmentText(nextText);
        const committedText = String(msg.committed_text || "").trim();
        const tentativeTail = resolveTentativeTail(
          nextText,
          committedText,
          msg.tentative_text || ""
        );
        const stability = readBackendStability(msg);
        if (lastPartialSeq <= 5 || (lastPartialSeq % 20 === 0 && lastPartialTraceSeq !== lastPartialSeq)) {
          traceSubtitle("ws_partial", {
            seq: lastPartialSeq,
            textLen: nextText.trim().length,
            tailLen: tentativeTail.length,
            committedCount: subtitleSentencePairs.length,
            stable: !!stability.isStable,
            stabilityPhase: String(stability.phase || ""),
          });
          lastPartialTraceSeq = lastPartialSeq;
        }
        updateCommittedTentativeTailFromBackend(tentativeTail, stability);
        currentTranslationTail = "";
        renderTranscript();
        renderTranslation();
        if (running) {
          setStatus(listeningStatus(selectedInputSource()), "ok");
          pump();
        }
        return;
      }
      return;
    }
    if (msg.type === "final") {
      lastPartialAt = Date.now();
      if (langEl) langEl.textContent = msg.language || "-";
      const finalText = msg.text || "";
      setRawAsrText(finalText);
      const mode = "stop";
      traceSubtitle("ws_final", {
        mode,
        finalLen: String(finalText || "").trim().length,
        tentativeLen: String(msg.tentative_text || "").trim().length,
        committedCount: subtitleSentencePairs.length,
      });
      const resolve = pendingFinalResolve;
      resetFinalWait();

      setCurrentSegmentText("");
      updateCommittedTentativeTailFromBackend(String(msg.tentative_text || "").trim(), readBackendStability(msg));
      currentTranslationTail = "";
      renderTranscript();
      renderTranslation();
      awaitingFinal = false;
      lockUI(false);
      setControlBarHidden(false, "final");
      setStatus("Stopped / 已停止", "");
      if (resolve) resolve(msg);
      if (ws && ws.readyState === WebSocket.OPEN) {
        try { ws.close(); } catch (err) {}
      }
      return;
    }
    if (msg.type === "processing") {
      setStatus("Processing / 服务器处理中", "warn");
      return;
    }
    if (msg.type === "error") {
      rejectPendingStart(new Error(msg.message || "websocket server error"));
      rejectPendingFinal(new Error(msg.message || "websocket server error"));
      resetSessionFlags();
      stopPipeline();
      setControlBarHidden(false, "server_error");
      setStatus("Error / 错误: " + (msg.message || "unknown"), "err");
      if (ws && ws.readyState === WebSocket.OPEN) {
        try { ws.close(); } catch (err) {}
      }
      return;
    }
  }

  async function openSocket(timeoutMs = 8000){
    return new Promise((resolve, reject) => {
      let timer = null;
      let done = false;
      const finish = (fn, value) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        fn(value);
      };
      const scheme = location.protocol === "https:" ? "wss" : "ws";
      const sock = new WebSocket(`${scheme}://${location.host}/ws`);
      ws = sock;
      sock.binaryType = "arraybuffer";

      sock.onmessage = (evt) => {
        if (sock !== ws) return;
        handleServerMessage(evt);
        try {
          const msg = JSON.parse(evt.data);
          if (msg.type === "ready") {
            finish(resolve);
            return;
          }
          if (msg.type === "error" && !running && !awaitingFinal) {
            finish(reject, new Error(msg.message || "websocket server error"));
          }
        } catch (err) {}
      };
      sock.onerror = () => {
        if (sock !== ws) return;
        const err = new Error("websocket failed");
        rejectPendingStart(err);
        finish(reject, err);
      };
      sock.onclose = (evt) => {
        if (sock !== ws) return;
        const err = new Error(`websocket closed (${evt.code})`);
        rejectPendingStart(err);
        if (!done) {
          finish(reject, err);
        }
        rejectPendingFinal(err);
        if (running) {
          resetSessionFlags();
          stopPipeline();
          setStatus("Disconnected / 连接断开", "warn");
        } else if (awaitingFinal) {
          resetSessionFlags();
          stopPipeline();
          setStatus("Disconnected before final / 收尾前连接断开", "err");
        }
      };
      timer = setTimeout(() => {
        finish(reject, new Error("websocket ready timeout"));
      }, timeoutMs);
    });
  }

  function pump(){
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    while (sendQueue.length > 0) {
      if (ws.bufferedAmount > MAX_WS_BUFFERED_BYTES) break;
      const item = sendQueue.shift();
      if (!item) continue;
      queuedBytes -= Number(item.bytes || 0);
      try {
        ws.send(item.payload);
        lastChunkSentAt = Date.now();
      } catch (err) {
        console.error(err);
        resetSessionFlags();
        stopPipeline();
        setStatus("Send failed / 音频发送失败", "err");
        return;
      }
    }
  }

  if (translationDirectionSelect) {
    translationDirectionSelect.addEventListener("change", () => {
      const next = selectedTranslationDirection();
      applyTranslationDirection(next);
      sendTranslationDirection(next);
    });
  }

  if (asrEngine) {
    asrEngine.addEventListener("change", () => applyAsrEngine(selectedAsrEngine()));
  }

  if (inputSourceSelect) {
    inputSourceSelect.addEventListener("change", () => {
      const next = selectedInputSource();
      applyInputSource(next);
    });
  }

  if (subtitleTopFontInput) {
    subtitleTopFontInput.addEventListener("input", applySubtitleFontInputs);
    subtitleTopFontInput.addEventListener("change", applySubtitleFontInputs);
  }

  if (subtitleBottomFontInput) {
    subtitleBottomFontInput.addEventListener("input", applySubtitleFontInputs);
    subtitleBottomFontInput.addEventListener("change", applySubtitleFontInputs);
  }

  if (asrContextInput) {
    asrContextInput.addEventListener("input", persistAsrContextInput);
    asrContextInput.addEventListener("change", persistAsrContextInput);
  }

  bindSubtitleScrollTracking(textEl);
  bindSubtitleScrollTracking(translationEl);

  if (jumpLatestEn) {
    jumpLatestEn.addEventListener("click", () => {
      traceSubtitle("jump_latest_clicked", { lane: "en" });
      resumeSubtitleAutoFollow("en", { reason: "button_click", pin: true });
    });
  }

  if (jumpLatestZh) {
    jumpLatestZh.addEventListener("click", () => {
      traceSubtitle("jump_latest_clicked", { lane: "zh" });
      resumeSubtitleAutoFollow("zh", { reason: "button_click", pin: true });
    });
  }

  if (controlReveal) {
    controlReveal.addEventListener("click", () => {
      traceSubtitle("control_reveal_clicked", {});
      revealControlBarTemporarily("reveal_button");
    });
  }

  if (controlBar) {
    controlBar.addEventListener("focusin", () => {
      if (running && !awaitingFinal) clearControlAutoHideTimer();
    });
    controlBar.addEventListener("focusout", () => {
      scheduleControlBarAutoHide(2600);
    });
    controlBar.addEventListener("pointerenter", () => {
      if (running && !awaitingFinal) clearControlAutoHideTimer();
    });
    controlBar.addEventListener("pointerleave", () => {
      scheduleControlBarAutoHide(2600);
    });
  }

  btnStart.onclick = async () => {
    if (running || awaitingFinal) return;
    let asrContextTerms = [];
    try {
      asrContextTerms = readAsrContextTerms();
    } catch (err) {
      setControlBarHidden(false, "start_failed");
      lockUI(false);
      setStatus("Start failed / 启动失败: " + describeStartError(err), "err");
      return;
    }
    subtitleSentencePairs = [];
    setCurrentSegmentText("");
    resetSubtitleAutoFollow();
    clearSubtitleDom();
    zhLineNodes = new Map();
    enLineNodes = new Map();
    clearCommittedTentativeTailNow();
    currentTranslationTail = "";
    renderTranscript();
    renderTranslation();
    if (langEl) langEl.textContent = "-";
    pending = new Float32Array(0);
    if (audioActivityGate) audioActivityGate.reset();
    audioActivityGate = null;
    sendQueue = [];
    queuedBytes = 0;
    resetFinalWait();
    sessionStartedAt = 0;
    lastCaptureAt = 0;
    lastChunkSentAt = 0;
    lastPartialAt = 0;
    lockUI(true);
    setStatus("Starting / 启动中", "warn");

    try {
      const sourceMode = selectedInputSource();
      traceSubtitle("capture_source_starting", { source: sourceMode });
      if (sourceMode === "system") {
        setStatus("Share full screen + system audio / 请选择整屏共享并勾选系统音频", "warn");
      }
      // Request media inside the click activation; no samples are read or sent until started.
      mediaStream = sourceMode === "system" ? await openSystemAudio() : await openMicrophone();
      await openSocket();
      if (!ws || ws.readyState !== WebSocket.OPEN) {
        throw new Error("websocket is not open");
      }
      const startedPromise = waitForStarted(selectedAsrEngine() === "zipformer-xl" ? 120000 : 10000);
      ws.send(
        JSON.stringify({
          type: "start",
          language: selectedAsrLanguage(),
          asr_engine: selectedAsrEngine(),
          translation_direction: selectedTranslationDirection(),
          asr_context_terms: asrContextTerms,
        })
      );
      const started = await startedPromise;

      await buildCaptureGraph();

      running = true;
      sessionStartedAt = Date.now();
      startWatchdog();
      setStatus(listeningStatus(sourceMode, started), "ok");
      setControlBarHidden(true, "start_success");
    } catch (err) {
      console.error(err);
      rejectPendingStart(err);
      activeContextMetadata = null;
      await stopPipeline();
      if (ws) {
        try { ws.close(); } catch (closeErr) {}
      }
      ws = null;
      running = false;
      lockUI(false);
      setControlBarHidden(false, "start_failed");
      setStatus("Start failed / 启动失败: " + describeStartError(err), "err");
    }
  };

  btnStop.onclick = async () => {
    if (!running) return;
    // Stop microphone first, then flush queued PCM before sending finish.
    running = false;
    awaitingFinal = true;
    setControlBarHidden(false, "stop_requested");
    lockUIFinishing();
    setStatus("Finishing / 收尾中", "warn");
    await stopPipeline(false);

    try {
      if (ws && ws.readyState === WebSocket.OPEN) {
        if (audioActivityGate) audioActivityGate.finish();
        audioActivityGate = null;
        flushPendingToQueue(true);
        const drained = await drainSendQueue(WEBSOCKET_DRAIN_TIMEOUT_MS);
        if (!drained) {
          setStatus("Finishing (network backlog) / 收尾中(网络积压)", "warn");
        }
        await sendFinishAndAwaitFinal("stop", STOP_FINAL_TIMEOUT_MS);
      } else {
        awaitingFinal = false;
        lockUI(false);
        setStatus("Stopped / 已停止", "");
      }
    } catch (err) {
      const msg = String((err && err.message) ? err.message : (err || ""));
      if (msg.includes("final timeout")) {
        traceSubtitle("stop_wait_final_timeout", { timeoutMs: STOP_FINAL_TIMEOUT_MS });
        // Backend final flush can be slow after long meetings; keep waiting on the same WS.
        setStatus("Finishing (slow backend) / 收尾中(后端较慢)", "warn");
        return;
      }
      console.error(err);
      rejectPendingFinal(err instanceof Error ? err : new Error(String(err)));
      awaitingFinal = false;
      lockUI(false);
      if (ws && ws.readyState === WebSocket.OPEN) {
        try { ws.close(); } catch (closeErr) {}
      }
      setStatus("Stop failed / 停止失败", "err");
    }
  };

  if (typeof window !== "undefined") {
    const _resetDebugSubtitleState = () => {
      subtitleSentencePairs = [];
      resetSubtitleAutoFollow();
      setCurrentSegmentText("");
      setRawAsrText("", { resetCurrent: true });
      clearSubtitleDom();
      zhLineNodes = new Map();
      enLineNodes = new Map();
      clearCommittedTentativeTailNow();
      currentTranslationTail = "";
      resetFinalWait();
      renderTranscript();
      renderTranslation();
      if (langEl) langEl.textContent = "-";
    };

    const _base64ToUint8 = (value) => {
      let src = String(value || "").trim();
      if (!src) return new Uint8Array(0);
      const marker = "base64,";
      const idx = src.indexOf(marker);
      if (idx >= 0) src = src.slice(idx + marker.length);
      src = src.replace(/\\s+/g, "");
      const bin = atob(src);
      const out = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    };

    const _waitUntil = async (predicate, timeoutMs) => {
      const timeout = Math.max(1000, Number(timeoutMs) || 1000);
      const begin = Date.now();
      while (Date.now() - begin < timeout) {
        if (predicate()) return true;
        await sleep(20);
      }
      return false;
    };

    window.__subtitleDebug = {
      feed(msg){
        handleServerMessage({ data: JSON.stringify(msg || {}) });
        return this.getState();
      },
      setState(next){
        const state = (next && typeof next === "object") ? next : {};
        const hasOwn = (name) => Object.prototype.hasOwnProperty.call(state, name);
        if (hasOwn("running")) running = !!state.running;
        if (hasOwn("currentTextTail")) currentTextTail = String(state.currentTextTail || "");
        if (hasOwn("currentSegmentText")) setCurrentSegmentText(String(state.currentSegmentText || ""));
        if (hasOwn("currentTranslationTail")) currentTranslationTail = String(state.currentTranslationTail || "");
        if (state.render !== false) {
          renderTranscript();
          renderTranslation();
        }
        return this.getState();
      },
      async wait(ms){
        await sleep(Math.max(0, Number(ms) || 0));
        return this.getState();
      },
      getTrace(limit){
        const rows = subtitleTraceEvents.slice();
        const n = Number(limit || 0);
        if (n > 0 && n < rows.length) {
          return rows.slice(rows.length - n);
        }
        return rows;
      },
      clearTrace(){
        subtitleTraceEvents = [];
        subtitleTraceSeq = 0;
        return true;
      },
      setTraceEnabled(enabled){
        subtitleTraceEnabled = !!enabled;
        try {
          localStorage.setItem("subtitle_trace", subtitleTraceEnabled ? "1" : "0");
        } catch (err) {}
        traceSubtitle("trace_toggle", { enabled: subtitleTraceEnabled }, true);
        return subtitleTraceEnabled;
      },
      async streamPcmFromUrl(url, options){
        const src = String(url || "").trim();
        if (!src) throw new Error("streamPcmFromUrl requires url");
        const resp = await fetch(src, { cache: "no-store" });
        if (!resp.ok) {
          throw new Error(`fetch pcm failed: ${resp.status}`);
        }
        const bytes = new Uint8Array(await resp.arrayBuffer());
        if (bytes.length === 0) {
          throw new Error("fetched empty pcm bytes");
        }
        let bin = "";
        const step = 0x8000;
        for (let i = 0; i < bytes.length; i += step) {
          const chunk = bytes.subarray(i, Math.min(bytes.length, i + step));
          bin += String.fromCharCode.apply(null, chunk);
        }
        const cfg = (options && typeof options === "object") ? { ...options } : {};
        cfg.base64 = btoa(bin);
        return await this.streamPcm16Base64(cfg);
      },
      async streamPcm16Base64(options){
        const cfg = (options && typeof options === "object") ? options : {};
        const pcmB64 = String(cfg.base64 || "").trim();
        if (!pcmB64) {
          throw new Error("streamPcm16Base64 requires {base64}");
        }
        const bytes = _base64ToUint8(pcmB64);
        if (bytes.length === 0) {
          throw new Error("empty pcm payload");
        }

        const asrContextTerms = readAsrContextTerms();
        const language = String(cfg.language || selectedAsrLanguage() || "auto");
        const timeoutMs = Math.max(5000, Number(cfg.timeoutMs || 120000));
        const paceMs = Math.max(0, Number(cfg.paceMs || 0));
        let chunkBytes = Number(cfg.chunkBytes || 0);
        if (!(chunkBytes > 0)) {
          const chunkMs = Math.max(20, Number(cfg.chunkMs || 200));
          chunkBytes = Math.round(16000 * 2 * (chunkMs / 1000.0));
        }
        chunkBytes = Math.max(320, Math.floor(chunkBytes));
        if (chunkBytes % 2 === 1) chunkBytes += 1;

        _resetDebugSubtitleState();
        running = true;
        awaitingFinal = false;
        setStatus("Debug stream / 调试流式", "warn");

        const scheme = location.protocol === "https:" ? "wss" : "ws";
        const sock = new WebSocket(`${scheme}://${location.host}/ws`);
        ws = sock;
        sock.binaryType = "arraybuffer";

        const events = [];
        let ready = false;
        let startAccepted = false;
        let startedMetadata = null;
        let finished = false;
        let errorMessage = "";

        sock.onmessage = (evt) => {
          try {
            const msg = JSON.parse(evt.data);
            events.push(msg);
            if (msg.type === "ready") ready = true;
            if (msg.type === "started") {
              startAccepted = true;
              startedMetadata = msg;
            }
            if (msg.type === "error") {
              errorMessage = String(msg.message || "websocket server error");
              finished = true;
            } else if (msg.type === "final") {
              finished = true;
            }
          } catch (err) {}
          handleServerMessage(evt);
        };
        sock.onerror = () => {
          if (!errorMessage) errorMessage = "websocket failed";
          finished = true;
        };
        sock.onclose = (evt) => {
          if (!finished && !errorMessage && evt.code !== 1000) {
            errorMessage = `websocket closed (${evt.code})`;
            finished = true;
          }
        };

        const readyOk = await _waitUntil(() => ready || !!errorMessage, timeoutMs);
        if (!readyOk || errorMessage) {
          if (sock.readyState === WebSocket.OPEN || sock.readyState === WebSocket.CONNECTING) {
            try { sock.close(); } catch (closeErr) {}
          }
          throw new Error(errorMessage || "websocket ready timeout");
        }

        sock.send(
          JSON.stringify({
            type: "start",
            language,
            asr_engine: selectedAsrEngine(),
            translation_direction: selectedTranslationDirection(),
            asr_context_terms: asrContextTerms,
          })
        );
        const startOk = await _waitUntil(
          () => startAccepted || !!errorMessage,
          timeoutMs,
        );
        if (!startOk || errorMessage) {
          throw new Error(errorMessage || "start acknowledgement timeout");
        }
        for (let i = 0; i < bytes.length; i += chunkBytes) {
          if (sock.readyState !== WebSocket.OPEN) {
            errorMessage = errorMessage || "websocket closed during stream";
            break;
          }
          const chunk = bytes.subarray(i, Math.min(bytes.length, i + chunkBytes));
          if (chunk.length > 0) {
            sock.send(chunk);
          }
          if (paceMs > 0) await sleep(paceMs);
        }

        if (!errorMessage && sock.readyState === WebSocket.OPEN) {
          sock.send(JSON.stringify({type: "finish", mode: "stop"}));
        }
        if (!errorMessage) {
          const doneOk = await _waitUntil(() => finished, timeoutMs);
          if (!doneOk) errorMessage = "finish timeout";
        }
        if (sock.readyState === WebSocket.OPEN) {
          try { sock.close(); } catch (closeErr) {}
        }

        const committedById = new Map();
        let finalText = "";
        for (const msg of events) {
          if (!msg || typeof msg !== "object") continue;
          const t = String(msg.type || "");
          if (t === "sentence_reset") {
            committedById.clear();
          } else if (t === "sentence_committed") {
            const sid = String(msg.sentence_id || `local-${committedById.size + 1}`);
            committedById.set(sid, String(msg.text || "").trim());
          } else if (t === "sentence_updated") {
            const sid = String(msg.sentence_id || "");
            if (sid && committedById.has(sid)) {
              committedById.set(sid, String(msg.text || "").trim());
            }
          } else if (t === "final") {
            finalText = String(msg.text || "").trim();
          }
        }

        const committedTexts = [];
        for (const text of committedById.values()) {
          const s = String(text || "").trim();
          if (s) committedTexts.push(s);
        }
        const eventCounts = {};
        for (const msg of events) {
          const key = String((msg && msg.type) || "");
          if (!key) continue;
          eventCounts[key] = Number(eventCounts[key] || 0) + 1;
        }

        return {
          ok: !errorMessage,
          error: String(errorMessage || ""),
          eventCounts,
          started: startedMetadata ? {
            asr_context_active: !!startedMetadata.asr_context_active,
            asr_context_term_count: Number(startedMetadata.asr_context_term_count || 0),
            asr_context_chars: Number(startedMetadata.asr_context_chars || 0),
          } : null,
          committedTexts,
          committedJoined: committedTexts.join(" ").trim(),
          finalText,
          state: this.getState(),
        };
      },
      getState(){
        const toRows = (container) => container ? Array.from(container.children).map((node) => String(node.textContent || "")) : [];
        return {
          running,
          controlsHidden: !!(appCard && appCard.classList.contains("controls-hidden")),
          subtitleTopFontPx: subtitleComputedFontPx(translationEl),
          subtitleBottomFontPx: subtitleComputedFontPx(textEl),
          subtitleTraceEnabled,
          subtitleTraceCount: subtitleTraceEvents.length,
          currentTextTail: String(currentTextTail || ""),
          currentSegmentText: String(currentSegmentText || ""),
          historyCount: subtitleSentencePairs.length,
          scrollFollowState: {
            zh: { ...scrollFollowState.zh },
            en: { ...scrollFollowState.en },
          },
          zhScrollTop: textEl ? Number(textEl.scrollTop || 0) : 0,
          zhScrollHeight: textEl ? Number(textEl.scrollHeight || 0) : 0,
          zhClientHeight: textEl ? Number(textEl.clientHeight || 0) : 0,
          enScrollTop: translationEl ? Number(translationEl.scrollTop || 0) : 0,
          enScrollHeight: translationEl ? Number(translationEl.scrollHeight || 0) : 0,
          enClientHeight: translationEl ? Number(translationEl.clientHeight || 0) : 0,
          jumpLatestZhVisible: !!(jumpLatestZh && !jumpLatestZh.hidden),
          jumpLatestEnVisible: !!(jumpLatestEn && !jumpLatestEn.hidden),
          zhRows: toRows(textEl),
          enRows: toRows(translationEl),
        };
      },
    };
  }

})();
</script>
</body>
</html>
"""
