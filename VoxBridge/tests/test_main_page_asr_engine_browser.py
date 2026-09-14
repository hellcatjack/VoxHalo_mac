import pytest

from test_main_page_audio_gate_browser import main_page


def install_transport(page, *, hold=False, fail=False, hold_final=False):
    page.evaluate("""({hold, fail, hold_final}) => {
      window.__starts = [];
      const ctx = new (window.AudioContext || window.webkitAudioContext)();
      const stream = ctx.createMediaStreamDestination().stream;
      navigator.mediaDevices.getUserMedia = async () => stream;
      navigator.mediaDevices.getDisplayMedia = async () => stream;
      window.WebSocket = class {
        static OPEN = 1; static CONNECTING = 0;
        constructor() {
          this.readyState = 1; this.bufferedAmount = 0;
          setTimeout(() => this.emit({type:'ready', translation_direction:'zh2en',
            asr_engines:[{id:'qwen3-asr', available:true, load_state:'ready'},
                         {id:'zipformer-xl', available:true, load_state:'unloaded'}]}), 0);
        }
        emit(msg) { this.onmessage?.({data:JSON.stringify(msg)}); }
        send(raw) {
          if (typeof raw !== 'string') return;
          const msg = JSON.parse(raw);
          if (msg.type === 'start') {
            window.__starts.push(msg);
            const complete = () => this.emit(fail ? {type:'error',message:'XL load failed'} :
              {type:'started', asr_engine:msg.asr_engine, language:'Chinese',
               translation_direction:msg.translation_direction, asr_context_active:false});
            if (hold) {
              this.emit({type:'asr_loading',asr_engine:'zipformer-xl'});
              window.__releaseStart = complete;
            } else setTimeout(complete, 0);
          } else if (msg.type === 'finish') {
            const complete = () => this.emit({type:'final',text:'',translation:''});
            if (hold_final) window.__releaseFinal = complete;
            else setTimeout(complete, 0);
          }
        }
        close() { this.readyState=3; this.onclose?.({code:1000}); }
      };
    }""", {"hold": hold, "fail": fail, "hold_final": hold_final})


def test_old_xl_preference_migrates_without_losing_context(main_page):
    page = main_page
    page.locator("#asrContextInput").fill("尼希米记")
    page.evaluate("localStorage.setItem('voxbridge_asr_engine','zipformer-xl')")
    page.reload()
    assert page.locator("select#asrEngine").count() == 0
    assert page.evaluate("localStorage.getItem('voxbridge_asr_engine')") == "qwen3-asr"
    assert page.locator("#asrContextInput").is_enabled()
    assert page.locator("#asrContextInput").input_value() == "尼希米记"


def test_english_direction_and_unknown_saved_engine_keep_qwen(main_page):
    page = main_page
    page.locator("#translationDirectionSelect").select_option("en2zh")
    page.evaluate("localStorage.setItem('voxbridge_asr_engine','unknown')")
    page.reload()
    assert page.locator("select#asrEngine").count() == 0
    assert page.locator("#translationDirectionSelect").input_value() == "en2zh"
    assert page.evaluate("localStorage.getItem('voxbridge_asr_engine')") == "qwen3-asr"


@pytest.mark.parametrize("source", ["mic", "system"])
def test_capture_always_sends_qwen_and_locks_until_stop(main_page, source):
    page = main_page
    install_transport(page)
    page.evaluate("localStorage.setItem('voxbridge_asr_engine','zipformer-xl')")
    page.locator("#inputSourceSelect").select_option(source)
    page.locator("#btnStart").click()
    page.wait_for_function("window.__starts.length === 1 && window.__subtitleDebug.getState().running")
    assert page.evaluate("window.__starts[0].asr_engine") == "qwen3-asr"
    assert page.evaluate("window.__starts[0].asr_context_terms") == []
    assert page.locator("select#asrEngine").count() == 0
    assert page.locator("#asrContextInput").is_disabled()
    assert page.locator("#translationDirectionSelect").is_disabled()
    page.locator("#controlReveal").click()
    page.locator("#btnStop").click()
    page.wait_for_function("!document.querySelector('#asrContextInput').disabled")
    assert page.locator("#asrContextInput").is_enabled()


def test_failed_start_unlocks_context(main_page):
    page = main_page
    install_transport(page, hold=True, fail=True)
    page.locator("#btnStart").click()
    page.wait_for_function("typeof window.__releaseStart === 'function'")
    assert page.locator("#asrContextInput").is_disabled()
    page.evaluate("window.__releaseStart()")
    page.wait_for_function("!document.querySelector('#asrContextInput').disabled")
    assert "XL load failed" in page.locator("#status").inner_text()


def test_debug_pcm_path_also_sends_qwen(main_page):
    page = main_page
    install_transport(page)
    page.evaluate("localStorage.setItem('voxbridge_asr_engine','zipformer-xl')")
    page.evaluate("window.__subtitleDebug.streamPcm16Base64({base64:'AAAAAA==',timeoutMs:5000})")
    assert page.evaluate("window.__starts[0].asr_engine") == "qwen3-asr"


def test_qwen_controls_lock_during_start_active_and_finish_wait(main_page):
    page = main_page
    install_transport(page, hold=True, hold_final=True)
    page.locator("#btnStart").click()
    page.wait_for_function("typeof window.__releaseStart === 'function'")
    assert not page.evaluate("window.__subtitleDebug.getState().running")
    assert page.locator("#asrContextInput").is_disabled()
    page.evaluate("window.__releaseStart()")
    page.wait_for_function("window.__subtitleDebug.getState().running")
    page.locator("#controlReveal").click()
    page.locator("#btnStop").click()
    page.wait_for_function("typeof window.__releaseFinal === 'function'")
    assert page.locator("select#asrEngine").count() == 0
    assert page.locator("#asrContextInput").is_disabled()
    assert page.locator("#btnStart").is_disabled()
    page.evaluate("window.__releaseFinal()")
    page.wait_for_function("!document.querySelector('#asrContextInput').disabled")
    assert page.locator("#asrContextInput").is_enabled()
