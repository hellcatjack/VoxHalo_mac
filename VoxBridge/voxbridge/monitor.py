"""Bounded, passive views of the authoritative interpretation session."""
from __future__ import annotations

import time
from collections import OrderedDict
from copy import deepcopy
from voxbridge.languages import pair_for_direction
from voxbridge.web.localization import embedded_localization


class MonitorState:
    def __init__(self, max_rows: int = 300):
        self.max_rows = max(1, int(max_rows))
        self.version = 0
        self.reset()

    def reset(self) -> None:
        self.rows: OrderedDict[str, dict] = OrderedDict()
        self.session = {'status': 'idle', 'direction': 'zh2en', 'last_error': ''}
        self._set_direction('zh2en')
        self.tentative = ''
        self.version += 1
        self.updated_at_ms = int(time.time() * 1000)

    def _set_direction(self, direction: str) -> None:
        pair = pair_for_direction(direction)
        self.session.update(direction=pair.direction, source_name=pair.source.name,
                            target_name=pair.target.name, source_language=pair.source.code,
                            target_language=pair.target.code)

    def observe(self, event: dict) -> None:
        kind = event.get('type')
        if kind == 'started':
            self.reset()
            self.session.update(status='running')
            self._set_direction(event.get('translation_direction', 'zh2en'))
        elif kind == 'ready':
            self.session['status'] = 'ready'
        elif kind == 'sentence_reset':
            self.rows.clear()
            self.tentative = ''
        elif kind in ('sentence_committed', 'sentence_updated'):
            sid = str(event.get('sentence_id', ''))
            if not sid:
                return
            revision = int(event.get('revision', 0))
            old = self.rows.get(sid)
            if old and revision < old['revision']:
                return
            source = str(event.get('text', ''))[:4000]
            translation = old['translation'] if old and old['revision'] == revision and old['source'] == source else ''
            self.rows[sid] = {'id': sid, 'revision': revision, 'source': source, 'translation': translation}
            if old and 'spoken' in old:
                self.rows[sid]['spoken'] = old['spoken']
            while len(self.rows) > self.max_rows:
                self.rows.popitem(last=False)
            self.tentative = ''
        elif kind == 'sentence_translation':
            row = self.rows.get(str(event.get('sentence_id', '')))
            if row is not None and int(event.get('revision', 0)) == row['revision']:
                row['translation'] = str(event.get('translation', ''))[:8000]
        elif kind == 'speech_committed':
            sid = str(event.get('sentence_id', ''))
            row = self.rows.get(sid.split(':addition:', 1)[0])
            if row is None:
                return
            spoken = row.setdefault('spoken', [])
            if not any(part['sentence_id'] == sid for part in spoken):
                spoken.append(dict(sentence_id=sid, revision=int(event.get('revision', 0)),
                    source=str(event.get('source', ''))[:4000], text=str(event.get('translation', ''))[:8000]))
        elif kind == 'partial':
            # tentative_text is computed by the backend's revision/segmentation policy.
            self.tentative = str(event.get('tentative_text', ''))[-4000:]
        elif kind == 'final':
            self.session['status'] = 'stopped'
            self.tentative = str(event.get('tentative_text', ''))[-4000:]
        elif kind == 'closed':
            if self.session['status'] not in ('stopped', 'error'):
                self.session['status'] = 'disconnected'
        elif kind == 'error':
            self.session.update(status='error', last_error=str(event.get('message', ''))[:1000])
        elif kind == 'translation_direction':
            self._set_direction(event.get('translation_direction', 'zh2en'))
        else:
            return
        self.version += 1
        self.updated_at_ms = int(time.time() * 1000)

    def snapshot(self) -> dict:
        return {'session': dict(self.session), 'rows': deepcopy(list(self.rows.values())),
                'tentative': self.tentative, 'updated_at_ms': self.updated_at_ms,
                'version': self.version}


MONITOR_HTML = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title data-i18n="monitor.title">Interpretation monitor</title><style>
:root{color-scheme:light;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#263632;background:#f3f5f1}*{box-sizing:border-box}body{margin:0}header{padding:24px 4vw 18px;background:#fff;border-bottom:1px solid #dde5dc;position:sticky;top:0;z-index:1}h1{font-size:23px;margin:0 0 8px}p{line-height:1.6;margin:6px 0}.muted{color:#63746a;font-size:13px}.status{display:flex;gap:14px;flex-wrap:wrap;margin-top:13px;font-size:14px}.pill{background:#e9f0e5;padding:6px 12px;border-radius:16px}main{max-width:1500px;margin:auto;padding:24px 4vw}.labels,.row{display:grid;grid-template-columns:1fr 1fr;gap:34px}.labels{font-size:13px;color:#69796f;padding-bottom:12px}.row{padding:14px 0;border-bottom:1px solid #dfe6dc;font-size:22px;line-height:1.6;white-space:pre-wrap;overflow-wrap:anywhere}.tail{color:#79887c}.error{color:#a33}.tools{display:flex;align-items:center;gap:15px;flex-wrap:wrap}a{color:#38664d}img{width:76px;height:76px;float:right}input{accent-color:#486b50}.interface-picker{display:flex;align-items:center;gap:8px;flex-wrap:wrap}select{font:inherit;max-width:100%;padding:6px;border:1px solid #bdcbbd;border-radius:6px;background:#fff;color:inherit}@media(max-width:680px){.row{grid-template-columns:1fr;gap:6px;font-size:19px}.labels{display:none}}
</style></head><body><header><img src="/listen/qr.svg" alt="Local network listener QR code" data-i18n-alt="monitor.qr"><h1 data-i18n="monitor.title">Interpretation monitor</h1><p class="muted" data-i18n="monitor.intro">View translations and published speech here. Open the listener page for synchronized captions. Closing this page does not interrupt interpretation.</p><div class="status"><span id="session" class="pill" data-i18n="monitor.connecting">Connecting…</span><span id="tts" class="pill" data-i18n="monitor.readingSpeech">Reading speech status…</span><span id="listeners" class="pill"></span></div><p id="error" class="error"></p><div class="tools"><label class="muted"><input id="follow" type="checkbox" checked> <span data-i18n="monitor.follow">Follow latest entries</span></label><a href="/listen" target="_blank" rel="noopener" data-i18n="monitor.listener">Listener page</a><label class="interface-picker muted"><span data-i18n="common.interface">Interface language</span><select id="interfaceLanguage" data-i18n-aria="common.interface" aria-label="Interface language"></select></label></div></header><main><div class="labels"><span id="sourceLabel"></span><span id="targetLabel"></span></div><div id="rows"></div></main>__LOCALIZATION__<script>
const ui=window.VoxUI;ui.mount();
const rows=document.getElementById('rows'), nodes=new Map();let version=-1, failed=false;
const statuses=new Set(['idle','ready','running','stopped','disconnected','error']);
function localizedLabel(tag,key){const node=document.createElement(tag);node.dataset.i18n=key;node.textContent=ui.t(key);return node}
function renderTranslation(node,r){
  const spoken=(r.spoken||[]).map(p=>p.text).join('\n');
  const signature=JSON.stringify([spoken,r.translation]);
  if(node.dataset.content===signature)return;
  node.dataset.content=signature;node.replaceChildren();
  const label=localizedLabel('div',spoken?'monitor.published':'monitor.pending');label.className='muted';node.append(label);
  const text=document.createElement('div');
  if(spoken||r.translation)text.textContent=spoken||r.translation;
  else {text.dataset.i18n='monitor.waitTranslation';text.textContent=ui.t('monitor.waitTranslation')}
  node.append(text);
  if(spoken&&r.translation&&spoken!==r.translation){
    const details=document.createElement('details'),summary=localizedLabel('summary','monitor.correction'),correction=document.createElement('div');
    details.className='muted';correction.textContent=r.translation;
    details.append(summary,correction);node.append(details);
  }
}
function clearError(){const node=document.getElementById('error');ui.unbind(node);node.textContent=''}
async function poll(){try{
  const res=await fetch('/api/monitor/state',{cache:'no-store'});if(!res.ok)throw Error('monitor request failed');
  const d=await res.json(),s=d.session,t=d.tts;
  ui.bind('session',statuses.has(s.status)?`monitor.${s.status}`:'monitor.unknownStatus',{status:s.status});
  ui.bind('tts','monitor.speech',()=>({count:t.queue_depth,seconds:(t.translated_audio_backlog_ms/1000).toFixed(1),estimated:t.translated_audio_backlog_estimated?ui.t('monitor.estimated'):'',speed:t.tts_effective_speed.toFixed(2)}));
  ui.bind('listeners','monitor.listeners',{count:t.listener_count});
  const diagnostic=s.last_error||t.last_error;
  if(diagnostic)ui.bind('error','monitor.diagnostic',{detail:diagnostic});else clearError();
  ui.bind('sourceLabel','monitor.source',()=>({language:ui.t(`language.${s.source_language}`)}));
  ui.bind('targetLabel','monitor.target',()=>({language:ui.t(`language.${s.target_language}`)}));
  if(d.version!==version||failed){version=d.version;const items=[...d.rows];if(d.tentative)items.push({id:'__tail',source:d.tentative,translation:''});const keep=new Set(items.map(x=>x.id));for(const[id,n]of nodes)if(!keep.has(id)){n.remove();nodes.delete(id)}for(const r of items){let n=nodes.get(r.id);if(!n){n=document.createElement('div');n.className='row';n.append(document.createElement('div'),document.createElement('div'));nodes.set(r.id,n);rows.append(n)}n.classList.toggle('tail',r.id==='__tail');if(n.children[0].textContent!==r.source)n.children[0].textContent=r.source;renderTranslation(n.children[1],r);rows.append(n)}if(document.getElementById('follow').checked)window.scrollTo({top:document.body.scrollHeight,behavior:'instant'})}
  failed=false;
}catch(e){failed=true;ui.bind('session','monitor.lost');ui.bind('error','monitor.reconnect')}
finally{setTimeout(poll,1000)}}poll();
</script></body></html>'''

MONITOR_HTML = MONITOR_HTML.replace('__LOCALIZATION__', embedded_localization())
