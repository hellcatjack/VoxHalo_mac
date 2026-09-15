"""Bounded, passive views of the authoritative interpretation session."""
from __future__ import annotations

import time
from collections import OrderedDict
from copy import deepcopy
from voxbridge.languages import pair_for_direction


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
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>同声传译监控</title><style>
:root{color-scheme:light;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#263632;background:#f3f5f1}*{box-sizing:border-box}body{margin:0}header{padding:24px 4vw 18px;background:#fff;border-bottom:1px solid #dde5dc;position:sticky;top:0;z-index:1}h1{font-size:23px;margin:0 0 8px}p{line-height:1.6;margin:6px 0}.muted{color:#63746a;font-size:13px}.status{display:flex;gap:14px;flex-wrap:wrap;margin-top:13px;font-size:14px}.pill{background:#e9f0e5;padding:6px 12px;border-radius:16px}main{max-width:1500px;margin:auto;padding:24px 4vw}.labels,.row{display:grid;grid-template-columns:1fr 1fr;gap:34px}.labels{font-size:13px;color:#69796f;padding-bottom:12px}.row{padding:14px 0;border-bottom:1px solid #dfe6dc;font-size:22px;line-height:1.6;white-space:pre-wrap;overflow-wrap:anywhere}.tail{color:#79887c}.error{color:#a33}.tools{display:flex;align-items:center;gap:15px;flex-wrap:wrap}a{color:#38664d}img{width:76px;height:76px;float:right}input{accent-color:#486b50}@media(max-width:680px){.row{grid-template-columns:1fr;gap:6px;font-size:19px}.labels{display:none}}
</style></head><body><header><img src="/listen/qr.svg" alt="局域网朗读二维码"><h1>同声传译监控</h1><p class="muted">这里显示译文与朗读记录；同步跟读请打开听众朗读页。关闭此页不影响传译。</p><div class="status"><span id="session" class="pill">正在连接…</span><span id="tts" class="pill">读取朗读状态…</span><span id="listeners" class="pill"></span></div><p id="error" class="error"></p><div class="tools"><label class="muted"><input id="follow" type="checkbox" checked> 跟随最新记录</label><a href="/listen" target="_blank" rel="noopener">听众朗读页</a></div></header><main><div class="labels"><span id="sourceLabel">中文原文</span><span id="targetLabel">英文译文</span></div><div id="rows"></div></main><script>
const rows=document.getElementById('rows'), nodes=new Map();let version=-1, failed=false;
const names={idle:'等待 App 开始',ready:'已连接 · 等待采集',running:'正在识别和翻译',stopped:'已停止采集',disconnected:'App 已断开',error:'需要处理'};
function renderTranslation(node,r){
  const spoken=(r.spoken||[]).map(p=>p.text).join('\n');
  const signature=JSON.stringify([spoken,r.translation]);
  if(node.dataset.content===signature)return;
  node.dataset.content=signature;node.replaceChildren();
  const label=document.createElement('div');label.className='muted';
  label.textContent=spoken?'已发布朗读':'译文待确认';node.append(label);
  const text=document.createElement('div');text.textContent=spoken||r.translation||'等待翻译…';node.append(text);
  if(spoken&&r.translation&&spoken!==r.translation){
    const details=document.createElement('details'),summary=document.createElement('summary'),correction=document.createElement('div');
    details.className='muted';summary.textContent='查看最新校订译文';correction.textContent=r.translation;
    details.append(summary,correction);node.append(details);
  }
}
function set(id,text){const n=document.getElementById(id);if(n.textContent!==text)n.textContent=text}
async function poll(){try{const res=await fetch('/api/monitor/state',{cache:'no-store'});if(!res.ok)throw Error('服务暂不可用');const d=await res.json(),s=d.session,t=d.tts;set('session',names[s.status]||s.status);set('tts',`朗读队列 ${t.queue_depth} · 待输出 ${(t.translated_audio_backlog_ms/1000).toFixed(1)} 秒${t.translated_audio_backlog_estimated?'（估算）':''} · ${t.tts_effective_speed.toFixed(2)}×`);set('listeners',`音频连接 ${t.listener_count}`);set('error',s.last_error||t.last_error||'');set('sourceLabel',`${s.source_name}原文`);set('targetLabel',`${s.target_name}译文`);if(d.version!==version||failed){version=d.version;const items=[...d.rows];if(d.tentative)items.push({id:'__tail',source:d.tentative,translation:''});const keep=new Set(items.map(x=>x.id));for(const[id,n]of nodes)if(!keep.has(id)){n.remove();nodes.delete(id)}for(const r of items){let n=nodes.get(r.id);if(!n){n=document.createElement('div');n.className='row';n.append(document.createElement('div'),document.createElement('div'));nodes.set(r.id,n);rows.append(n)}n.classList.toggle('tail',r.id==='__tail');if(n.children[0].textContent!==r.source)n.children[0].textContent=r.source;renderTranslation(n.children[1],r);rows.append(n)}if(document.getElementById('follow').checked)window.scrollTo({top:document.body.scrollHeight,behavior:'instant'})}failed=false}catch(e){failed=true;set('session','监控连接已断开');set('error','无法连接本机服务；页面会自动重连。请在 App 中查看运行状态。')}finally{setTimeout(poll,1000)}}poll();
</script></body></html>'''
