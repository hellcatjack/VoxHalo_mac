"""Standalone browser UI for live translated-speech listeners."""

from pathlib import Path

from voxbridge.web.localization import embedded_localization


HLS_JS_PATH = Path(__file__).with_name("vendor") / "hls.min.js"


TTS_LISTENER_HTML = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
  <title data-i18n="listener.title">VoxHalo · Live Interpretation</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #17243c;
      --muted: #5f6d83;
      --blue: #245ee5;
      --line: #e0e6ef;
      --paper: #ffffff;
    }
    * { box-sizing: border-box; }
    html, body {
      width: 100%; height: 100%; height: 100dvh;
      margin: 0; overflow: hidden; overscroll-behavior: none;
    }
    body {
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", sans-serif;
      background: #edf1f7;
      display: grid; place-items: center;
      padding: max(16px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right))
        max(16px, env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left));
    }
    main {
      width: min(1040px, 100%); height: min(780px, 100%); min-height: 0;
      padding: 28px; border: 1px solid #dce3ed; border-radius: 28px;
      background: var(--paper); box-shadow: 0 20px 64px #18335a0d;
      display: grid; grid-template-columns: minmax(0, .82fr) minmax(0, 1.18fr);
      grid-template-rows: auto auto minmax(72px, 1fr) auto;
      gap: 20px 24px; overflow: hidden;
    }
    .brand {
      grid-column: 1 / -1; display: flex; align-items: center;
      min-width: 0; gap: 12px; padding-bottom: 8px;
    }
    .brand-mark {
      width: 42px; height: 42px; flex: 0 0 auto;
      display: grid; place-items: center; color: white;
      background: var(--blue); border-radius: 13px;
    }
    .brand-mark svg { width: 28px; height: 28px; }
    .brand-copy { display: flex; align-items: baseline; flex-wrap: wrap; gap: 5px 10px; }
    .brand-copy strong { font-size: 23px; font-weight: 750; letter-spacing: -.8px; }
    .brand-copy span { color: var(--muted); font-size: 12px; letter-spacing: .12em; }
    .live-tag {
      margin-left: auto; padding: 7px 10px; border: 1px solid var(--line);
      border-radius: 7px; color: var(--muted); font-size: 10px; font-weight: 650;
      letter-spacing: .1em; white-space: nowrap;
    }
    .hero {
      grid-column: 1; grid-row: 2 / 5; min-width: 0; min-height: 0;
      padding: clamp(22px, 3vw, 32px); border-radius: 20px;
      color: #fff; background: #162b4d;
      display: flex; flex-direction: column; overflow: hidden;
    }
    .eyebrow {
      margin: 0 0 20px; color: #a4c8ff; font-size: 10px;
      font-weight: 650; letter-spacing: .12em; line-height: 1.4;
    }
    h1 { margin: 0; font-size: clamp(32px, 4vw, 48px); font-weight: 650;
      line-height: 1.1; letter-spacing: -1.8px; text-wrap: balance; }
    .intro { margin: 20px 0; color: #c0cde1; font-size: 14px; line-height: 1.65; }
    .language-panel { margin-top: auto; padding-top: 20px; }
    .language-summary { margin: 0 0 12px; color: #c0cde1; font-size: 11px; line-height: 1.5; }
    .language-list {
      display: grid; grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 8px; list-style: none; margin: 0; padding: 0;
    }
    .language-list li {
      min-width: 0; padding: 8px 11px; border: 1px solid #ffffff26;
      border-radius: 7px; font-size: 12px; line-height: 1.4; color: #e8effa;
    }
    .channel-note { margin: 14px 0 0; color: #c0cde1; font-size: 11px; line-height: 1.5; }
    .status-grid {
      grid-column: 2; grid-row: 2; min-width: 0;
      display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px;
    }
    .status-card {
      min-width: 0; min-height: 58px; padding: 10px 12px;
      border: 1px solid var(--line); border-radius: 10px;
      display: grid; align-content: center; gap: 5px;
    }
    .status-card span { color: var(--muted); font-size: 9px; letter-spacing: .06em; font-weight: 600; text-transform: uppercase; }
    .status-card strong { font-size: 12px; font-weight: 600; min-width: 0; white-space: normal; overflow-wrap: anywhere; line-height: 1.35; }
    .status-card[data-state="ok"] strong { color: #12634d; }
    .status-card[data-state="warn"] strong { color: #725323; }
    .status-card[data-state="error"] strong { color: #b03a36; }
    .now-playing {
      grid-column: 2; grid-row: 3; min-width: 0; min-height: 0;
      padding: 24px; border: 1px solid var(--line); border-radius: 16px;
      background: #f6f8fc; display: flex; gap: 14px; overflow: hidden;
    }
    .now-playing-copy {
      min-width: 0; min-height: 0; flex: 1 1 auto; align-self: stretch;
      display: grid; grid-template-rows: auto minmax(min-content, 1fr) auto; gap: 12px;
    }
    .now-playing small { display: block; color: var(--muted); font-size: 10px; font-weight: 650; letter-spacing: .09em; }
    .now-playing strong {
      display: block; min-width: 0; align-self: center;
      color: var(--ink); font-size: clamp(20px, 2.8vw, 30px); font-weight: 500;
      line-height: 1.4; overflow-wrap: anywhere; text-wrap: pretty;
    }
    .now-playing[data-caption-fitting="compact"] { padding: 8px; }
    .now-playing[data-caption-fitting="compact"] small,
    .now-playing[data-caption-fitting="compact"] .playback-state,
    .now-playing[data-caption-fitting="compact"] .pulse { display: none; }
    .now-playing[data-caption-fitting="compact"] .now-playing-copy { gap: 0; }
    .playback-state {
      min-width: 0; align-self: end; color: var(--muted);
      font-size: 11px; line-height: 1.4; overflow-wrap: anywhere;
    }
    .pulse { display: none; }
    .controls { grid-column: 2; grid-row: 4; min-width: 0; display: grid; gap: 12px; }
    .interface-picker { display: flex; align-items: center; justify-content: space-between; gap: 8px; color: var(--muted); font-size: 12px; }
    .interface-picker select { min-width: 0; max-width: 54%; padding: 5px 8px; font: inherit; color: var(--ink); background: white; border: 1px solid #c7d1e0; border-radius: 6px; }
    .interface-picker select:focus-visible { outline: 3px solid #83afff; outline-offset: 2px; }
    .playback-settings { display: flex; align-items: center; justify-content: space-between; gap: 12px; min-height: 24px; }
    .playback-settings > span { color: var(--muted); font-size: 12px; }
    .playback-settings strong { color: var(--ink); font-size: 12px; font-weight: 600; font-variant-numeric: tabular-nums; }
    .actions { display: grid; grid-template-columns: 1.4fr 1fr; gap: 10px; }
    button {
      min-width: 0; min-height: 50px; padding: 12px 10px;
      border: 1px solid transparent; border-radius: 10px; font: inherit;
      font-size: 13px; font-weight: 650; cursor: pointer;
      transition: background 140ms ease, border-color 140ms ease;
    }
    button:focus-visible { outline: 3px solid #83afff; outline-offset: 3px; }
    button:disabled { cursor: default; opacity: .5; }
    #startListening { color: white; background: var(--blue); }
    #startListening:hover:not(:disabled) { background: #194fc9; }
    #stopListening { color: var(--ink); background: white; border-color: #c7d1e0; }
    #stopListening:hover:not(:disabled) { background: #edf2fa; }
    #resumeListening { grid-column: 1 / -1; color: white; background: #175b4d; }
    #resumeListening[hidden] { display: none; }
    @media (prefers-reduced-motion: reduce) { button { transition: none; } }
    @media (max-width: 699px) {
      body { padding: max(8px, env(safe-area-inset-top)) max(8px, env(safe-area-inset-right))
        max(8px, env(safe-area-inset-bottom)) max(8px, env(safe-area-inset-left)); }
      main { width: min(560px, 100%); padding: 18px; border-radius: 22px;
        grid-template-columns: minmax(0, 1fr); grid-template-rows: auto auto auto minmax(72px, 1fr) auto; gap: 14px; }
      .brand { grid-column: 1; grid-row: 1; padding-bottom: 0; gap: 9px; }
      .brand-mark { width: 36px; height: 36px; border-radius: 11px; }
      .brand-copy strong { font-size: 21px; }
      .brand-copy span { font-size: 10px; }
      .live-tag { font-size: 9px; padding: 6px 8px; }
      .hero { grid-column: 1; grid-row: 2; padding: 20px; border-radius: 14px; }
      .eyebrow { font-size: 9px; margin-bottom: 10px; }
      h1 { font-size: 30px; letter-spacing: -1px; max-width: 15em; }
      .intro { margin: 10px 0 0; font-size: 12px; line-height: 1.5; }
      .language-panel { padding-top: 12px; }
      .language-summary { margin-bottom: 0; font-size: 10px; }
      .language-list { display: none; }
      .channel-note { margin-top: 4px; font-size: 10px; }
      .status-grid { grid-column: 1; grid-row: 3; gap: 6px; }
      .status-card { min-height: 52px; padding: 8px; }
      .status-card span { font-size: 8px; }
      .status-card strong { font-size: 11px; }
      .now-playing { grid-column: 1; grid-row: 4; padding: 18px; }
      .now-playing strong { font-size: 23px; line-height: 1.3; }
      .controls { grid-column: 1; grid-row: 5; gap: 10px; }
    }
    @media (max-width: 699px) and (max-height: 680px) {
      main { padding: 12px; gap: 10px; }
      .hero { padding: 14px; }
      h1 { font-size: 26px; }
      .intro, .channel-note, .eyebrow, .language-panel { display: none; }
      .language-panel { padding-top: 7px; }
      .eyebrow { margin-bottom: 7px; }
      .status-card { min-height: 44px; gap: 3px; }
      .now-playing { padding: 12px; }
      .now-playing-copy { gap: 6px; }
      .controls { gap: 6px; }
      button { min-height: 44px; padding: 9px; font-size: 12px; }
    }
    @media (min-width: 600px) and (max-height: 500px) {
      body { padding: 8px; }
      main { padding: 16px; gap: 12px 18px;
        grid-template-columns: minmax(0, .8fr) minmax(0, 1.2fr);
        grid-template-rows: auto minmax(58px, 1fr) auto; }
      .brand { grid-column: 1; grid-row: 1; padding: 0; }
      .brand-copy strong { font-size: 20px; }
      .brand-copy span { font-size: 10px; }
      .brand-mark { width: 34px; height: 34px; }
      .live-tag { display: none; }
      .hero { grid-column: 1; grid-row: 2 / 4; padding: 20px; }
      .eyebrow { margin-bottom: 10px; }
      h1 { font-size: 32px; letter-spacing: -1px; }
      .intro { display: none; }
      .language-panel { padding-top: 12px; }
      .language-list { grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 5px; }
      .language-list li { font-size: 9px; padding: 5px 3px; text-align: center; }
      .language-summary, .channel-note { font-size: 10px; margin: 5px 0; }
      .status-grid { grid-row: 1; }
      .status-card { min-height: 44px; padding: 6px 8px; gap: 3px; }
      .status-card span { font-size: 8px; }
      .status-card strong { font-size: 11px; }
      .now-playing { grid-row: 2; padding: 12px; }
      .now-playing-copy { gap: 6px; }
      .now-playing strong { font-size: 23px; line-height: 1.25; }
      .controls { grid-row: 3; gap: 6px; }
      button { min-height: 44px; padding: 9px; font-size: 12px; }
    }
  </style>
</head>
<body>
  <main>
    <header class="brand">
      <div class="brand-mark" aria-hidden="true">
        <svg viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round">
          <path d="M5 11v6m6-12v18m6-15v12m6-9v6" />
        </svg>
      </div>
      <div class="brand-copy">
        <strong>VoxHalo</strong>
        <span data-i18n="listener.brand">Live interpretation</span>
      </div>
      <div class="live-tag" data-i18n="listener.tag">LISTENER</div>
    </header>

    <section class="hero">
      <p class="eyebrow" data-i18n="listener.eyebrow">LIVE INTERPRETATION</p>
      <h1 data-i18n="listener.heading">Stay in the conversation.</h1>
      <p class="intro" data-i18n="listener.intro">Listen to the live translation. Follow each sentence with captions that move with the audio.</p>
      <div class="language-panel">
        <p class="language-summary" data-i18n="listener.languages">8 languages · 56 translation directions</p>
        <ul class="language-list" aria-label="Supported languages" data-i18n-aria="listener.supported">
          <li lang="zh-CN">中文</li><li lang="en">English</li>
          <li lang="ja">日本語</li><li lang="fr">Français</li>
          <li lang="es">Español</li><li lang="it">Italiano</li>
          <li lang="pt-BR">Português</li><li lang="hi">हिन्दी</li>
        </ul>
        <p class="channel-note" data-i18n="listener.hostLanguage">The host selects the language for this live stream.</p>
      </div>
    </section>

    <section class="status-grid" aria-live="polite">
      <div id="connectionCard" class="status-card" data-state="warn">
        <span data-i18n="listener.connection">Connection</span><strong id="connectionStatus" data-i18n="listener.notStarted">Not started</strong>
      </div>
      <div id="producerCard" class="status-card" data-state="warn">
        <span data-i18n="listener.service">Service</span><strong id="producerStatus" data-i18n="listener.waiting">Waiting</strong>
      </div>
      <div id="queueCard" class="status-card">
        <span data-i18n="listener.listeners">Listeners</span><strong id="queueStatus" data-i18n="listener.notJoined">Not joined</strong>
      </div>
    </section>

    <section id="nowPlaying" class="now-playing" data-playing="false" data-speaking="false">
      <div class="now-playing-copy">
        <small data-i18n="listener.captions">TRANSLATED CAPTIONS</small>
        <strong id="liveCaption" data-i18n="listener.waitStart" aria-live="polite" aria-atomic="true">Waiting to start</strong>
        <span id="playbackStatus" class="playback-state" data-i18n="listener.joinHint">Start listening to join the shared stream</span>
      </div>
      <div class="pulse" aria-hidden="true"></div>
    </section>

    <audio id="ttsPlayback" preload="none" playsinline hidden></audio>

    <section class="controls">
      <label class="interface-picker"><span data-i18n="common.interface">Interface language</span><select id="interfaceLanguage" aria-label="Interface language" data-i18n-aria="common.interface"></select></label>
      <div class="playback-settings" aria-live="polite">
        <span data-i18n="listener.speed">Playback speed</span>
        <strong id="globalSpeedStatus">Auto - 1.0x</strong>
      </div>
      <div class="actions">
        <button id="startListening" type="button" data-i18n="listener.start">Start Listening</button>
        <button id="stopListening" type="button" data-i18n="listener.stop" disabled>Stop Listening</button>
        <button id="resumeListening" type="button" data-i18n="listener.resume" hidden>Resume Audio</button>
      </div>
    </section>
  </main>

  __LOCALIZATION__
  <script src="/listen/assets/hls.min.js"></script>
  <script>
  (() => {
    const ui = window.VoxUI;
    ui.mount();
    const startButton = document.getElementById("startListening");
    const stopButton = document.getElementById("stopListening");
    const resumeButton = document.getElementById("resumeListening");
    const connectionCard = document.getElementById("connectionCard");
    const producerCard = document.getElementById("producerCard");
    const connectionStatus = document.getElementById("connectionStatus");
    const producerStatus = document.getElementById("producerStatus");
    const queueStatus = document.getElementById("queueStatus");
    const liveCaption = document.getElementById("liveCaption");
    const playbackStatus = document.getElementById("playbackStatus");
    const nowPlaying = document.getElementById("nowPlaying");
    const globalSpeedStatus = document.getElementById("globalSpeedStatus");
    const playbackElement = document.getElementById("ttsPlayback");
    const CAPTION_POLL_INTERVAL_MS = 500;
    const PLAYBACK_INTERRUPTION_STATUS_HOLD_MS = 1500;
    const MIN_CAPTION_FONT_PX = 8;
    const MIN_DISCARDABLE_GAP_MS = 500;
    const NEXT_SPEECH_BUFFER_GUARD_MS = 1000;
    const NEXT_SPEECH_SEEKABLE_GUARD_MS = 100;
    const NATIVE_HLS_SPEECH_PREROLL_MS = 250;

    let listenerId = "";
    let running = false;
    let statusTimer = null;
    let captionTimer = null;
    let captionAbortController = null;
    let playbackStarted = false;
    let waitingForMedia = false;
    let playbackStatusHoldUntilMs = 0;
    let captionSnapshot = null;
    let captionCueId = "";
    let captionResizeFrame = null;
    const attemptedGapCueKeys = new Set();
    let hlsController = null;
    let serverTranslatedAudioBacklogSec = 0;
    let globalSpeedMode = "Auto";
    let globalSpeedMultiplier = 1;

    function setCard(card, value) {
      card.dataset.state = value || "";
    }

    function liveLagSec() {
      const ranges = playbackElement.seekable;
      if (!ranges || ranges.length < 1 || !Number.isFinite(playbackElement.currentTime)) {
        return null;
      }
      const liveEdge = Number(ranges.end(ranges.length - 1));
      if (!Number.isFinite(liveEdge)) return null;
      return Math.max(0, liveEdge - playbackElement.currentTime);
    }

    function forwardBufferedSec() {
      const currentTime = Number(playbackElement.currentTime);
      const ranges = playbackElement.buffered;
      if (!ranges || !Number.isFinite(currentTime)) return null;
      try {
        for (let index = 0; index < ranges.length; index += 1) {
          const start = Number(ranges.start(index));
          const end = Number(ranges.end(index));
          if (
            Number.isFinite(start)
            && Number.isFinite(end)
            && currentTime >= start
            && currentTime <= end
          ) {
            return Math.max(0, end - currentTime);
          }
        }
      } catch (error) {}
      return null;
    }

    function expectedMediaWaitStatus() {
      return serverTranslatedAudioBacklogSec > 0
        ? "listener.preparingSentence"
        : "listener.waitSpeech";
    }

    function showPlaybackInterruptionStatus(labelKey) {
      const bufferedAhead = forwardBufferedSec();
      playbackStatusHoldUntilMs = (
        performance.now() + PLAYBACK_INTERRUPTION_STATUS_HOLD_MS
      );
      ui.bind(playbackStatus, bufferedAhead === null
        ? "listener.bufferUnknown" : "listener.bufferAhead",
        () => ({label: ui.t(labelKey), seconds: bufferedAhead === null ? "" : bufferedAhead.toFixed(1)}));
    }

    function formatDurationSec(value) {
      const totalSec = Math.max(0, Math.ceil(Number(value) || 0));
      if (totalSec < 60) return ui.t("listener.seconds", {seconds: totalSec});
      const minutes = Math.floor(totalSec / 60);
      const seconds = totalSec % 60;
      return ui.t(seconds > 0 ? "listener.minutesSeconds" : "listener.minutes", {minutes, seconds});
    }

    function speedParameters() {
      return {mode: ui.t(globalSpeedMode === "Fixed" ? "listener.fixed" : "common.auto"),
        speed: globalSpeedMultiplier.toFixed(1)};
    }

    function sharedAudioParameters() {
      return {...speedParameters(), duration: formatDurationSec(serverTranslatedAudioBacklogSec)};
    }

    function estimatedPlaybackAtMs(snapshot) {
      if (hlsController !== null) {
        try {
          const playingDate = hlsController.playingDate;
          const playingAtMs = playingDate instanceof Date ? playingDate.getTime() : NaN;
          if (Number.isFinite(playingAtMs)) return playingAtMs;
        } catch (error) {}
        // HLS.js and the server refresh their playlist edges independently.
        // Keep the current caption until HLS.js exposes the exact playing date.
        return null;
      }
      const currentTime = Number(playbackElement.currentTime);
      if (
        Number.isFinite(currentTime)
        && typeof playbackElement.getStartDate === "function"
      ) {
        try {
          const startDate = playbackElement.getStartDate();
          const startAtMs = startDate instanceof Date ? startDate.getTime() : NaN;
          if (Number.isFinite(startAtMs)) {
            return startAtMs + currentTime * 1000;
          }
        } catch (error) {}
      }
      const liveEdgeAtMs = Number(snapshot && snapshot.live_edge_at_ms);
      const lag = liveLagSec();
      if (!Number.isFinite(liveEdgeAtMs) || lag === null) return null;
      return liveEdgeAtMs - lag * 1000;
    }

    function revealCaption() {
      liveCaption.classList.remove("caption-reveal");
      void liveCaption.offsetWidth;
      liveCaption.classList.add("caption-reveal");
    }

    function captionFitsCard() {
      return nowPlaying.scrollHeight <= nowPlaying.clientHeight + 1
        && nowPlaying.scrollWidth <= nowPlaying.clientWidth + 1;
    }

    function fitLiveCaption() {
      nowPlaying.dataset.captionFitting = "";
      liveCaption.style.fontSize = "";
      const maximumFontPx = Number.parseFloat(
        window.getComputedStyle(liveCaption).fontSize
      );
      if (!Number.isFinite(maximumFontPx) || captionFitsCard()) return;

      const fitAtSmallestSize = () => {
        liveCaption.style.fontSize = `${MIN_CAPTION_FONT_PX}px`;
        return captionFitsCard();
      };
      if (!fitAtSmallestSize()) {
        nowPlaying.dataset.captionFitting = "compact";
        liveCaption.style.fontSize = "";
        if (captionFitsCard()) return;
        if (!fitAtSmallestSize()) return;
      }

      let smallestFitPx = MIN_CAPTION_FONT_PX;
      let largestOverflowPx = maximumFontPx;
      for (let index = 0; index < 8; index += 1) {
        const candidatePx = (smallestFitPx + largestOverflowPx) / 2;
        liveCaption.style.fontSize = `${candidatePx}px`;
        if (captionFitsCard()) smallestFitPx = candidatePx;
        else largestOverflowPx = candidatePx;
      }
      const verifiedFitPx = Math.floor(smallestFitPx * 100) / 100;
      liveCaption.style.fontSize = `${verifiedFitPx.toFixed(2)}px`;
    }

    function scheduleCaptionFit() {
      if (captionResizeFrame !== null) {
        window.cancelAnimationFrame(captionResizeFrame);
      }
      captionResizeFrame = window.requestAnimationFrame(() => {
        captionResizeFrame = null;
        fitLiveCaption();
      });
    }

    function setLiveCaptionMessage(key) {
      setLiveCaption(ui.t(key));
      ui.bind(liveCaption, key);
    }

    function setLiveCaption(text, cueId = "") {
      ui.unbind(liveCaption);
      const nextText = String(text || "").trim();
      if (!nextText) return;
      const nextCueId = String(cueId || "");
      if (liveCaption.textContent === nextText && captionCueId === nextCueId) return;
      liveCaption.textContent = nextText;
      captionCueId = nextCueId;
      fitLiveCaption();
      revealCaption();
    }

    function bufferedRangeContainsBoth(targetMediaTime, guardedMediaTime) {
      const ranges = playbackElement.buffered;
      if (!ranges) return false;
      try {
        for (let index = 0; index < ranges.length; index += 1) {
          const start = Number(ranges.start(index));
          const end = Number(ranges.end(index));
          if (
            Number.isFinite(start)
            && Number.isFinite(end)
            && targetMediaTime >= start
            && targetMediaTime <= end
            && guardedMediaTime >= start
            && guardedMediaTime <= end
          ) {
            return true;
          }
        }
      } catch (error) {}
      return false;
    }

    function seekableRangeContainsBoth(targetMediaTime, guardedMediaTime) {
      const ranges = playbackElement.seekable;
      if (!ranges) return false;
      try {
        for (let index = 0; index < ranges.length; index += 1) {
          const start = Number(ranges.start(index));
          const end = Number(ranges.end(index));
          if (
            Number.isFinite(start)
            && Number.isFinite(end)
            && targetMediaTime >= start
            && targetMediaTime <= end
            && guardedMediaTime >= start
            && guardedMediaTime <= end
          ) {
            return true;
          }
        }
      } catch (error) {}
      return false;
    }

    function compactBufferedWaitingGap(playheadAtMs, previousCue, nextCue) {
      if (!running || !playbackStarted || !previousCue || !nextCue) return false;
      const previousEndAtMs = Number(previousCue.end_at_ms);
      const nextStartAtMs = Number(nextCue.start_at_ms);
      const resumeAtMs = Number(nextCue.resume_at_ms);
      const discardableGapMs = Number(nextCue.discardable_gap_before_ms);
      if (
        !Number.isFinite(playheadAtMs)
        || !Number.isFinite(previousEndAtMs)
        || !Number.isFinite(nextStartAtMs)
        || !Number.isFinite(resumeAtMs)
        || !Number.isFinite(discardableGapMs)
        || discardableGapMs < MIN_DISCARDABLE_GAP_MS
        || resumeAtMs < previousEndAtMs
        || resumeAtMs > nextStartAtMs
        || playheadAtMs < previousEndAtMs
        || playheadAtMs >= nextStartAtMs
      ) {
        return false;
      }
      const nextCueKey = String(
        nextCue.cue_id || `${nextStartAtMs}:${resumeAtMs}`
      );
      if (attemptedGapCueKeys.has(nextCueKey)) return false;

      const naturalGapMs = Math.max(0, nextStartAtMs - resumeAtMs);
      const heardGapMs = Math.max(0, playheadAtMs - previousEndAtMs);
      const remainingNaturalMs = Math.max(0, naturalGapMs - heardGapMs);
      // Native HLS needs a short decoded lead-in around an exact AAC seek.
      const speechPrerollMs = hlsController === null
        ? NATIVE_HLS_SPEECH_PREROLL_MS
        : 0;
      const targetProgramAtMs = Math.max(
        previousEndAtMs,
        Math.min(
          nextStartAtMs - remainingNaturalMs,
          nextStartAtMs - speechPrerollMs
        )
      );
      const currentTime = Number(playbackElement.currentTime);
      if (!Number.isFinite(currentTime) || targetProgramAtMs <= playheadAtMs) {
        return false;
      }
      const targetMediaTime = currentTime
        + (targetProgramAtMs - playheadAtMs) / 1000;
      const guardedMediaTime = currentTime
        + (nextStartAtMs + NEXT_SPEECH_BUFFER_GUARD_MS - playheadAtMs) / 1000;
      const seekableGuardedMediaTime = currentTime
        + (nextStartAtMs + NEXT_SPEECH_SEEKABLE_GUARD_MS - playheadAtMs) / 1000;
      const bufferedReady = bufferedRangeContainsBoth(
        targetMediaTime,
        guardedMediaTime
      );
      const seekableReady = seekableRangeContainsBoth(
        targetMediaTime,
        seekableGuardedMediaTime
      );
      const targetReady = hlsController === null
        ? seekableReady
        : bufferedReady || seekableReady;
      if (
        !Number.isFinite(targetMediaTime)
        || !Number.isFinite(guardedMediaTime)
        || !Number.isFinite(seekableGuardedMediaTime)
        || targetMediaTime <= currentTime
        || !targetReady
      ) {
        return false;
      }

      attemptedGapCueKeys.add(nextCueKey);
      try {
        playbackElement.currentTime = targetMediaTime;
        return true;
      } catch (error) {}
      return false;
    }

    function applyCaptionSnapshot(snapshot, requestListenerId) {
      if (!running || !requestListenerId || requestListenerId !== listenerId) return;
      const playheadAtMs = estimatedPlaybackAtMs(snapshot);
      if (playheadAtMs === null) return;
      const cues = Array.isArray(snapshot && snapshot.cues) ? snapshot.cues : [];
      let selected = null;
      let next = null;
      for (const cue of cues) {
        const startAtMs = Number(cue && cue.start_at_ms);
        if (!Number.isFinite(startAtMs)) continue;
        if (
          startAtMs <= playheadAtMs
          && (selected === null || startAtMs >= Number(selected.start_at_ms))
        ) {
          selected = cue;
        } else if (
          startAtMs > playheadAtMs
          && (next === null || startAtMs < Number(next.start_at_ms))
        ) {
          next = cue;
        }
      }
      if (selected === null) {
        if (!captionCueId) setLiveCaptionMessage("listener.waitSpeech");
        nowPlaying.dataset.speaking = "false";
        return;
      }
      setLiveCaption(selected.text, selected.cue_id);
      const endAtMs = Number(selected.end_at_ms);
      nowPlaying.dataset.speaking = String(
        nowPlaying.dataset.playing === "true"
          && Number.isFinite(endAtMs)
          && playheadAtMs < endAtMs
      );
      compactBufferedWaitingGap(playheadAtMs, selected, next);
    }

    function refreshCaptionForPlayhead() {
      if (captionSnapshot !== null) {
        applyCaptionSnapshot(captionSnapshot, listenerId);
      }
    }

    async function pollCaptions() {
      if (!running || document.hidden || !listenerId || captionAbortController) return;
      const requestListenerId = listenerId;
      const controller = new AbortController();
      captionAbortController = controller;
      try {
        const response = await fetch(
          `/api/tts/live/${encodeURIComponent(requestListenerId)}/captions`,
          {
            credentials: "same-origin",
            cache: "no-store",
            signal: controller.signal,
          }
        );
        if (!response.ok) throw new Error(`caption request failed: ${response.status}`);
        const snapshot = await response.json();
        if (!running || requestListenerId !== listenerId) return;
        captionSnapshot = snapshot;
        applyCaptionSnapshot(snapshot, requestListenerId);
      } catch (error) {
        // Caption metadata is advisory; native HLS playback remains independent.
      } finally {
        if (captionAbortController === controller) {
          captionAbortController = null;
        }
      }
    }

    function forceNormalPlaybackRate() {
      playbackElement.defaultPlaybackRate = 1;
      playbackElement.playbackRate = 1;
    }

    function updateLiveAudioStatus() {
      forceNormalPlaybackRate();
      if (!running) return;
      if (waitingForMedia) {
        playbackStatusHoldUntilMs = 0;
        ui.bind(playbackStatus, expectedMediaWaitStatus());
        return;
      }
      if (performance.now() < playbackStatusHoldUntilMs) return;
      playbackStatusHoldUntilMs = 0;
      if (!playbackStarted) {
        ui.bind(playbackStatus, "listener.buffering");
      } else if (serverTranslatedAudioBacklogSec > 0) {
        ui.bind(playbackStatus, "listener.backlog", sharedAudioParameters);
      } else {
        ui.bind(playbackStatus, "listener.liveSpeed", speedParameters);
      }
    }

    function createListenerId() {
      if (window.crypto && typeof window.crypto.randomUUID === "function") {
        return `iphone-${window.crypto.randomUUID()}`;
      }
      const bytes = new Uint8Array(16);
      window.crypto.getRandomValues(bytes);
      return `iphone-${Array.from(bytes, (value) =>
        value.toString(16).padStart(2, "0")
      ).join("")}`;
    }

    function destroyHlsController() {
      if (hlsController === null) return;
      hlsController.destroy();
      hlsController = null;
    }

    function configurePlaybackSource(streamUrl) {
      destroyHlsController();
      const nativeHlsSupported = Boolean(
        playbackElement.canPlayType("application/vnd.apple.mpegurl")
      );
      const mseAacSupported = Boolean(
        window.MediaSource
        && typeof window.MediaSource.isTypeSupported === "function"
        && window.MediaSource.isTypeSupported('audio/mp4; codecs="mp4a.40.2"')
      );
      const hlsJsSupported = Boolean(
        window.Hls
        && typeof window.Hls.isSupported === "function"
        && Hls.isSupported()
        && mseAacSupported
      );
      if (nativeHlsSupported && ("ManagedMediaSource" in window || !hlsJsSupported)) {
        playbackElement.src = streamUrl;
        return true;
      }
      if (hlsJsSupported) {
        hlsController = new Hls({ maxLiveSyncPlaybackRate: 1 });
        hlsController.loadSource(streamUrl);
        hlsController.attachMedia(playbackElement);
        return true;
      }
      if (nativeHlsSupported) {
        playbackElement.src = streamUrl;
        return true;
      }
      return false;
    }

    function setMediaPlaybackState(state) {
      if ("mediaSession" in navigator) {
        navigator.mediaSession.playbackState = state;
      }
    }

    function markPlaying() {
      if (!running) return;
      waitingForMedia = false;
      playbackStarted = true;
      resumeButton.hidden = true;
      ui.bind(connectionStatus, "listener.connected");
      setCard(connectionCard, "ok");
      nowPlaying.dataset.playing = "true";
      beginCaptionPolling();
      refreshCaptionForPlayhead();
      setMediaPlaybackState("playing");
      updateLiveAudioStatus();
    }

    function markPlaybackBlocked(error) {
      if (!running) return;
      waitingForMedia = false;
      playbackStarted = false;
      playbackStatusHoldUntilMs = 0;
      forceNormalPlaybackRate();
      const blocked = error && error.name === "NotAllowedError";
      ui.bind(connectionStatus, blocked ? "listener.tapContinue" : "listener.unavailable");
      setCard(connectionCard, blocked ? "warn" : "error");
      ui.bind(playbackStatus, blocked ? "listener.tapResume" : "listener.streamUnavailable");
      nowPlaying.dataset.playing = "false";
      nowPlaying.dataset.speaking = "false";
      resumeButton.hidden = false;
      setMediaPlaybackState("paused");
    }

    async function pollStatus() {
      if (!running) return;
      try {
        const response = await fetch("/api/tts/live/status", {
          credentials: "same-origin",
          cache: "no-store",
        });
        if (!response.ok) throw new Error(`status request failed: ${response.status}`);
        const status = await response.json();
        if (!running) return;
        const reportedBacklogMs = Number(status.translated_audio_backlog_ms);
        const fallbackPendingAudioMs = Number(status.pending_audio_ms);
        const serverBacklogMs = Number.isFinite(reportedBacklogMs)
          ? reportedBacklogMs
          : fallbackPendingAudioMs;
        serverTranslatedAudioBacklogSec = Number.isFinite(serverBacklogMs)
          ? Math.max(0, serverBacklogMs) / 1000
          : 0;
        globalSpeedMode = status.global_speed_mode === "fixed" ? "Fixed" : "Auto";
        const reportedSpeedMultiplier = Number(status.global_speed_multiplier);
        globalSpeedMultiplier = Number.isFinite(reportedSpeedMultiplier)
          ? Math.max(0.5, reportedSpeedMultiplier)
          : 1;
        ui.bind(globalSpeedStatus, "listener.speedValue", speedParameters);
        ui.bind(producerStatus, status.producer_active ? "listener.serviceLive" : "listener.waitService");
        setCard(producerCard, status.producer_active ? "ok" : "warn");
        const listeners = Number(status.listener_count || 0);
        ui.bind(queueStatus, status.encoder_active ? "listener.liveListeners" : "listener.preparingStream", {count: listeners});
        updateLiveAudioStatus();
      } catch (error) {
        if (!running) return;
        ui.bind(producerStatus, "listener.statusUnavailable");
        setCard(producerCard, "warn");
      }
    }

    function beginStatusPolling() {
      if (statusTimer !== null) window.clearInterval(statusTimer);
      void pollStatus();
      statusTimer = window.setInterval(() => void pollStatus(), 5000);
    }

    function stopStatusPolling() {
      if (statusTimer === null) return;
      window.clearInterval(statusTimer);
      statusTimer = null;
    }

    function beginCaptionPolling() {
      if (captionTimer !== null) return;
      void pollCaptions();
      captionTimer = window.setInterval(
        () => void pollCaptions(),
        CAPTION_POLL_INTERVAL_MS
      );
    }

    function stopCaptionPolling() {
      if (captionTimer !== null) {
        window.clearInterval(captionTimer);
        captionTimer = null;
      }
      if (captionAbortController !== null) {
        captionAbortController.abort();
        captionAbortController = null;
      }
    }

    function startListeningFromGesture() {
      if (running) return;
      running = true;
      playbackStarted = false;
      waitingForMedia = false;
      playbackStatusHoldUntilMs = 0;
      serverTranslatedAudioBacklogSec = 0;
      globalSpeedMode = "Auto";
      globalSpeedMultiplier = 1;
      attemptedGapCueKeys.clear();
      ui.bind(globalSpeedStatus, "listener.speedValue", speedParameters);
      listenerId = createListenerId();
      startButton.disabled = true;
      stopButton.disabled = false;
      resumeButton.hidden = true;
      ui.bind(connectionStatus, "listener.connecting");
      ui.bind(producerStatus, "listener.checkService");
      ui.bind(queueStatus, "listener.joining");
      ui.bind(playbackStatus, "listener.startingAudio");
      setLiveCaptionMessage("listener.waitSpeech");
      nowPlaying.dataset.speaking = "false";
      setCard(connectionCard, "warn");
      setCard(producerCard, "warn");

      playbackElement.muted = false;
      playbackElement.playsInline = true;
      const streamUrl =
        `/api/tts/live/${encodeURIComponent(listenerId)}/index.m3u8`;
      forceNormalPlaybackRate();
      const sourceConfigured = configurePlaybackSource(streamUrl);

      if (!sourceConfigured) {
        beginStatusPolling();
        markPlaybackBlocked(new Error("HLS playback is unsupported"));
        return;
      }

      // iOS requires the native stream to start directly inside the user's gesture.
      const playPromise = playbackElement.play();
      beginStatusPolling();
      if (playPromise) {
        playPromise.then(markPlaying).catch(markPlaybackBlocked);
      } else {
        markPlaying();
      }
    }

    function resumeListeningFromGesture() {
      if (!running || !playbackElement.src) return;
      playbackStarted = false;
      waitingForMedia = false;
      playbackStatusHoldUntilMs = 0;
      forceNormalPlaybackRate();
      resumeButton.hidden = true;
      ui.bind(connectionStatus, "listener.restoring");
      setCard(connectionCard, "warn");
      const playPromise = playbackElement.play();
      if (playPromise) {
        playPromise.then(markPlaying).catch(markPlaybackBlocked);
      } else {
        markPlaying();
      }
    }

    function releaseListenerLease(id) {
      if (!id) return;
      fetch(`/api/tts/live/${encodeURIComponent(id)}`, {
        method: "DELETE",
        credentials: "same-origin",
        keepalive: true,
      }).catch(() => {});
    }

    function stopListening() {
      const closingListenerId = listenerId;
      listenerId = "";
      playbackStarted = false;
      waitingForMedia = false;
      playbackStatusHoldUntilMs = 0;
      forceNormalPlaybackRate();
      running = false;
      stopStatusPolling();
      stopCaptionPolling();
      captionSnapshot = null;
      captionCueId = "";
      attemptedGapCueKeys.clear();
      playbackElement.pause();
      destroyHlsController();
      playbackElement.removeAttribute("src");
      playbackElement.load();
      releaseListenerLease(closingListenerId);
      resumeButton.hidden = true;
      nowPlaying.dataset.playing = "false";
      nowPlaying.dataset.speaking = "false";
      ui.bind(connectionStatus, "listener.stopped");
      ui.bind(producerStatus, "listener.waiting");
      ui.bind(queueStatus, "listener.notJoined");
      globalSpeedMode = "Auto";
      globalSpeedMultiplier = 1;
      ui.bind(globalSpeedStatus, "listener.speedValue", speedParameters);
      ui.bind(liveCaption, "listener.waitStart");
      fitLiveCaption();
      ui.bind(playbackStatus, "listener.joinHint");
      setCard(connectionCard, "warn");
      setCard(producerCard, "warn");
      startButton.disabled = false;
      stopButton.disabled = true;
      setMediaPlaybackState("none");
    }

    function updateMediaMetadata() {
      if (!("mediaSession" in navigator)) return;
      try {
        navigator.mediaSession.metadata = new MediaMetadata({
          title: ui.t("listener.title"),
          artist: "VoxHalo",
          album: ui.t("listener.album"),
        });
      } catch (error) {}
    }

    function configureMediaSession() {
      if (!("mediaSession" in navigator)) return;
      updateMediaMetadata();
      try {
        navigator.mediaSession.setActionHandler("play", () => {
          if (!running) startListeningFromGesture();
          else resumeListeningFromGesture();
        });
      } catch (error) {}
      try {
        navigator.mediaSession.setActionHandler("pause", () => {
          playbackElement.pause();
          waitingForMedia = false;
          nowPlaying.dataset.playing = "false";
          nowPlaying.dataset.speaking = "false";
          ui.bind(playbackStatus, "listener.paused");
          setMediaPlaybackState("paused");
        });
      } catch (error) {}
    }

    forceNormalPlaybackRate();
    configureMediaSession();
    ui.bind(globalSpeedStatus, "listener.speedValue", speedParameters);
    ui.onChange(() => {
      // Relabeling must not seek, restart, pause, or select another caption.
      updateMediaMetadata();
      fitLiveCaption();
    });

    startButton.addEventListener("click", startListeningFromGesture);
    resumeButton.addEventListener("click", resumeListeningFromGesture);
    stopButton.addEventListener("click", stopListening);
    playbackElement.addEventListener("playing", markPlaying);
    playbackElement.addEventListener("waiting", () => {
      if (!running) return;
      waitingForMedia = true;
      forceNormalPlaybackRate();
      playbackStatusHoldUntilMs = 0;
      ui.bind(playbackStatus, expectedMediaWaitStatus());
      nowPlaying.dataset.playing = "false";
      nowPlaying.dataset.speaking = "false";
    });
    playbackElement.addEventListener("stalled", () => {
      if (!running) return;
      waitingForMedia = false;
      playbackStarted = false;
      forceNormalPlaybackRate();
      showPlaybackInterruptionStatus("listener.reconnecting");
      nowPlaying.dataset.playing = "false";
      nowPlaying.dataset.speaking = "false";
    });
    playbackElement.addEventListener("error", () => {
      if (!running) return;
      markPlaybackBlocked(playbackElement.error || new Error("media error"));
    });
    playbackElement.addEventListener("timeupdate", updateLiveAudioStatus);
    playbackElement.addEventListener("timeupdate", refreshCaptionForPlayhead);
    playbackElement.addEventListener("progress", updateLiveAudioStatus);
    playbackElement.addEventListener("progress", refreshCaptionForPlayhead);
    document.addEventListener("visibilitychange", () => {
      updateLiveAudioStatus();
      if (!document.hidden) void pollCaptions();
    });
    window.addEventListener("resize", scheduleCaptionFit);
    window.addEventListener("beforeunload", () => {
      if (captionResizeFrame !== null) {
        window.cancelAnimationFrame(captionResizeFrame);
      }
      stopStatusPolling();
      stopCaptionPolling();
      releaseListenerLease(listenerId);
      playbackElement.pause();
      destroyHlsController();
    });
  })();
  </script>
</body>
</html>
"""


TTS_LISTENER_HTML = TTS_LISTENER_HTML.replace("__LOCALIZATION__", embedded_localization())

__all__ = ["HLS_JS_PATH", "TTS_LISTENER_HTML"]
