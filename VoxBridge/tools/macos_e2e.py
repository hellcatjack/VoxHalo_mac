"""Real-paced local ASR → HY-MT → Kokoro → shared AAC/HLS, without playback."""
import argparse
import asyncio
import json
from pathlib import Path
import subprocess
import time
import uuid

import httpx
import imageio_ffmpeg
import numpy as np
import soundfile as sf
import websockets


async def run(args):
    output=Path(args.output);output.mkdir(parents=True,exist_ok=True)
    pcm,sr=sf.read(args.audio,dtype='float32')
    assert sr==16000 and pcm.ndim==1
    pcm=pcm[:int(args.seconds*16000)] if args.seconds else pcm
    pcm=np.concatenate((pcm,np.zeros(16000,np.float32)))
    raw=np.clip(pcm*32768,-32768,32767).astype('<i2').tobytes()
    listeners=['mac-e2e-'+uuid.uuid4().hex for _ in range(2)]
    events=[]; captions={}; segments={}; snapshots=[]
    begin=time.monotonic()
    async with httpx.AsyncClient(base_url='http://127.0.0.1:8024',timeout=15) as http:
        headers={}
        monitor=await http.get('/api/monitor/state')
        if monitor.status_code==200 and monitor.json().get('native_console'):
            token_file=Path(__file__).resolve().parents[1]/'artifacts/macos-service/native-control-token'
            headers['X-VoxBridge-Control-Token']=token_file.read_text().strip()
        async def poll_media():
            playlist=await http.get(f'/api/tts/live/{listeners[0]}/index.m3u8')
            playlist.raise_for_status()
            for line in playlist.text.splitlines():
                if line.startswith('/') and line.endswith('.ts'):
                    name=line.rsplit('/',1)[1]
                    if name not in segments:
                        response=await http.get(line);response.raise_for_status();segments[name]=response.content
            cue_response=await http.get(f'/api/tts/live/{listeners[0]}/captions')
            cue_response.raise_for_status()
            for cue in cue_response.json()['cues']: captions[cue['cue_id']]=cue
            status=(await http.get('/api/tts/live/status')).json()
            snapshots.append({'at_s':time.monotonic()-begin,**status})
            assert not status['last_error'],status
            return status
        try:
            for listener in listeners:
                response=await http.get(f'/api/tts/live/{listener}/index.m3u8');response.raise_for_status()
            status=await poll_media()
            assert status['listener_count']==2 and status['encoder_active']
            epoch=status['speech_epoch_id']
            final=asyncio.Event()
            async with websockets.connect('ws://127.0.0.1:8024/ws',max_size=16*1024*1024,extra_headers=headers) as ws:
                first=json.loads(await ws.recv());assert first['type']=='ready',first
                await ws.send(json.dumps({'type':'start','asr_engine':'qwen3-asr',
                    'translation_direction':args.direction,'asr_context_terms':[],
                    'tts_enabled':True,'tts_client_id':'mac-producer-'+uuid.uuid4().hex}))
                while True:
                    data=json.loads(await ws.recv());events.append({'at_s':time.monotonic()-begin,**data})
                    assert data['type']!='error',data
                    if data['type']=='started': break
                async def receive():
                    async for message in ws:
                        data=json.loads(message);events.append({'at_s':time.monotonic()-begin,**data})
                        if data['type'] in ('final','error'):
                            final.set();return
                receiver=asyncio.create_task(receive())
                audio_begin=time.monotonic()
                last_poll=audio_begin
                for offset in range(0,len(raw),3200):
                    deadline=audio_begin+min(offset+3200,len(raw))/32000
                    await asyncio.sleep(max(0,deadline-time.monotonic()))
                    await ws.send(raw[offset:offset+3200])
                    if time.monotonic()-last_poll>2:
                        await poll_media();last_poll=time.monotonic()
                await ws.send(json.dumps({'type':'finish'}))
                await asyncio.wait_for(final.wait(),60)
                await receiver
                assert events[-1]['type']=='final',events[-1]
            deadline=time.monotonic()+60
            while True:
                status=await poll_media()
                if (captions and not status['queue_depth'] and not status['pending_audio_ms']
                    and not status['preparation_queue_depth'] and not status['synthesis_active']):break
                assert time.monotonic()<deadline,('TTS drain timed out',status)
                await asyncio.sleep(.5)
            # Removing the first listener must retain the same shared epoch.
            await http.delete(f'/api/tts/live/{listeners[0]}')
            status=(await http.get('/api/tts/live/status')).json()
            assert status['listener_count']==1 and status['speech_epoch_id']==epoch and status['encoder_active']
            assert captions and segments
            media=output/'shared-audio.ts'
            media.write_bytes(b''.join(value for _,value in sorted(segments.items())))
            wav=output/'shared-audio.wav'
            subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(),'-v','error','-y','-i',str(media),
                            '-ac','1','-ar','24000',str(wav)],check=True,capture_output=True)
            audio,rate=sf.read(wav,dtype='float32')
            assert len(audio)>rate and np.max(np.abs(audio))>.01,'HLS must contain real speech, not only carrier'
            report={'input':str(args.audio),'audio_seconds':len(pcm)/16000,'direction':args.direction,
                'events':events,'captions':list(captions.values()),'status_samples':snapshots,
                'decoded_audio_seconds':len(audio)/rate,'decoded_audio_peak':float(np.max(np.abs(audio))),
                'shared_epoch_survives_first_listener_exit':True}
            (output/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
            print(json.dumps({key:val for key,val in report.items() if key not in ('events','captions','status_samples')},ensure_ascii=False),flush=True)
            print('FINAL:',events[-1],flush=True)
        finally:
            (output/'events.json').write_text(json.dumps(events,ensure_ascii=False,indent=2))
            for listener in listeners:
                await http.delete(f'/api/tts/live/{listener}')
            after=(await http.get('/api/tts/live/status')).json()
            (output/'after.json').write_text(json.dumps(after,indent=2))
            assert after['listener_count']==0 and not after['encoder_active'],after


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--audio',required=True)
    parser.add_argument('--seconds',type=float,default=0)
    parser.add_argument('--direction',choices=['zh2en','en2zh'],default='zh2en')
    parser.add_argument('--output',default='artifacts/macos/e2e')
    asyncio.run(run(parser.parse_args()))


if __name__=='__main__': main()
