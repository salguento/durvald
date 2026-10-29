#!/usr/bin/env python3
"""Measure visible official WKWebView players using an isolated temporary app."""
import argparse
import csv
import ctypes
import datetime as dt
import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import plistlib
import queue
import re
import signal
import subprocess
import tempfile
import threading
import time
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parent
REQUIRED = ('ready','play','progress','pause','resume','seek')


def responsibility_lookup():
    # Read-only OS introspection; not part of the distributed application.
    function = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
    function.argtypes = [ctypes.c_int]; function.restype = ctypes.c_int
    return function


def processes():
    output = subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,time=,rss=,comm='],text=True)
    result = {}
    for line in output.splitlines():
        parts = line.split(None,4)
        if len(parts) != 5: continue
        pid, parent, cpu, rss, name = parts
        seconds = sum(float(part)*60**i for i,part in enumerate(reversed(cpu.split(':'))))
        result[int(pid)] = dict(parent=int(parent),cpu_seconds=seconds,rss_kib=int(rss),kind='webkit' if '/WebKit.framework/' in name else 'other')
    return result


def parse_network_row(line):
    row = next(csv.reader([line]))
    if len(row)<3: return None
    match = re.search(r'\.(\d+)$',row[0])
    if not match: return None
    try: values = int(row[1]),int(row[2])
    except ValueError: return None
    return int(match[1]),values


def timing(events):
    first = {}
    for event in events:
        if 'time' in event: first.setdefault(event['event'],event['time'])
    def delta(end,start):
        if end not in first or start not in first: return None
        return max(0,first[end]-first[start])
    return dict(page_to_ready_ms=first.get('ready'), play_to_progress_ms=delta('first_progress','play_requested'),
                ready_to_play_ms=delta('playing','ready'), resume_to_progress_ms=delta('resumed_progress','resume_requested'),
                seek_to_observed_ms=delta('seek_observed','seek_requested'))


def phase_summary(samples):
    result = {}
    for phase in ('unloaded_idle','loading','playback','pausing','paused','resuming','seeking'):
        rows = [r for r in samples if r['phase']==phase]
        if not rows: continue
        duration = sum(r['interval_seconds'] for r in rows)
        result[phase] = dict(samples=len(rows),sampled_seconds=duration,
                             cpu_mean_percent=sum(r['cpu_delta_seconds'] for r in rows)/duration*100,
                             rss_max_mib=max(r['rss_kib'] for r in rows)/1024)
    return result


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = urllib.parse.urlsplit(self.path).path
        if name not in ('/metrics-player.html','/metrics-player.js'): self.send_error(404); return
        data = (ROOT/name[1:]).read_bytes();self.send_response(200)
        self.send_header('Content-Type','text/html; charset=utf-8' if name.endswith('html') else 'text/javascript')
        self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def log_message(self,*args): pass


def build_app(directory):
    app = directory/'DurvaldPlayerProbe.app';macos = app/'Contents'/'MacOS';macos.mkdir(parents=True)
    identifier = 'org.durvald.externalprobe.'+uuid.uuid4().hex
    (app/'Contents'/'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=identifier,CFBundleExecutable='DurvaldPlayerProbe',CFBundleName='DurvaldPlayerProbe',CFBundlePackageType='APPL',NSHighResolutionCapable=True,NSAppTransportSecurity={'NSAllowsLocalNetworking':True})))
    result = subprocess.run(['/usr/bin/swiftc','-O','-module-cache-path',str(directory/'modules'),str(ROOT/'MetricsWebKitProbe.swift'),'-o',str(macos/'DurvaldPlayerProbe')],capture_output=True,text=True,timeout=120)
    if result.returncode: raise RuntimeError('swift_compilation_failed')
    return app


def measure(app,provider,item,server_port,directory,number,responsible):
    prefix = directory/f'{provider}-{number}'
    output,pidfile,eventfile = (prefix.with_suffix(suffix) for suffix in ('.json','.pid','.events'))
    query = urllib.parse.urlencode(dict(provider=provider,item=item))
    url = f'http://127.0.0.1:{server_port}/metrics-player.html?{query}'
    messages = queue.Queue()
    net = subprocess.Popen(['/usr/bin/nettop','-P','-L','0','-J','bytes_in,bytes_out','-n','-x','-t','external','-s','1'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    def read_net():
        for line in net.stdout:
            value = parse_network_row(line)
            if value: messages.put(value)
    reader = threading.Thread(target=read_net,daemon=True);reader.start()
    before = processes(); initial_pids = set(before)
    launcher = None;pid = None;owned = {};network = {};samples=[];events=[];phase='unloaded_idle'
    previous_cpu = {};start=time.monotonic();previous=start;exit_seen=None
    attribution_verified = False
    try:
        launcher = subprocess.Popen(['/usr/bin/open','-n','-W','-a',str(app),'--stdout',str(prefix.with_suffix('.stdout')),'--stderr',str(prefix.with_suffix('.stderr')),'--args','--url',url,'--report',str(output),'--pidfile',str(pidfile),'--events',str(eventfile)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        while time.monotonic()-start<100:
            now=time.monotonic()
            if pid is None and pidfile.exists():
                pid=int(pidfile.read_text());attribution_verified=responsible(pid)==pid
                if not attribution_verified: raise RuntimeError('app_responsibility_not_isolated')
            rows = processes()
            if eventfile.exists():
                try: events=[json.loads(line) for line in eventfile.read_text().splitlines() if line.strip()]
                except ValueError: pass
                if events: phase=events[-1].get('phase',phase)
            if pid:
                for candidate,row in rows.items():
                    if candidate==pid or (candidate not in initial_pids and row['kind']=='webkit' and responsible(candidate)==pid):
                        owned.setdefault(candidate,row['kind'] if candidate!=pid else 'host')
                current = {p:rows[p] for p in owned if p in rows}
                delta=sum(max(0,row['cpu_seconds']-previous_cpu.get(p,0)) for p,row in current.items())
                previous_cpu.update({p:r['cpu_seconds'] for p,r in current.items()})
                if exit_seen is None and pid in rows:
                    samples.append(dict(elapsed_seconds=now-start,phase=phase,interval_seconds=now-previous,
                                        cpu_delta_seconds=delta,rss_kib=sum(r['rss_kib'] for r in current.values()),
                                        host_count=sum(owned[p]=='host' for p in current),webkit_count=sum(owned[p]=='webkit' for p in current)))
                if pid not in rows and exit_seen is None: exit_seen=now
            while not messages.empty():
                candidate,counts=messages.get_nowait()
                if pid and (candidate in owned or (candidate not in initial_pids and responsible(candidate)==pid)):
                    previous_counts=network.setdefault(candidate,[0,0])
                    network[candidate]=[max(previous_counts[i],counts[i]) for i in range(2)]
            previous=now
            if exit_seen is not None and now-exit_seen>=5: break
            if pid is None and launcher.poll() is not None: raise RuntimeError('app_launch_failed')
            time.sleep(.5)
        else: raise TimeoutError('player_process_deadline')
        if not output.exists(): raise RuntimeError('player_report_missing')
        observation=json.loads(output.read_text())
        phases=phase_summary(samples)
        alive=processes();survivors=[p for p in owned if p in alive and responsible(p)==pid]
        checks=observation.get('checks',{})
        playback_valid=all(checks.get(k) is True for k in REQUIRED)
        net_available=net.poll() is None and any(v[0]>0 for v in network.values())
        measurement_valid=attribution_verified and net_available and phases.get('playback',{}).get('sampled_seconds',0)>=15 and phases.get('paused',{}).get('sampled_seconds',0)>=8
        return dict(provider=provider,public_item_id=item,run=number,status='measured' if playback_valid and measurement_valid else 'limited',
                    observation=observation,timing=timing(observation.get('events',[])),phases=phases,samples=samples,
                    network=dict(status='measured' if net_available else 'unavailable',received_bytes=sum(v[0] for v in network.values()) if net_available else None,
                                 sent_bytes=sum(v[1] for v in network.values()) if net_available else None,
                                 processes_with_counters=len(network),process_roles=sorted({owned.get(p,'attributed_process') for p in network}),scope='nettop external TCP+UDP process counters; includes SDK, video/audio, metadata, advertising and control overhead; not media payload size',
                                 interval='whole process lifetime including load, 20s advancing playback, 10s pause, resume and seek; prefetched bytes are not 20s bitrate'),
                    process_attribution=dict(verified=attribution_verified,method='LaunchServices app responsibility_get_pid_responsible_for_pid; new WebKit processes only',
                                             host_processes=sum(v=='host' for v in owned.values()),webkit_processes=sum(v=='webkit' for v in owned.values()),
                                             alive_five_seconds_after_exit=len(survivors)),
                    stall_windows_observed=sum(e.get('event')=='stall_observed' for e in observation.get('events',[])))
    finally:
        if pid and responsible(pid)==pid:
            try: os.kill(pid,signal.SIGTERM)
            except ProcessLookupError: pass
        if launcher and launcher.poll() is None:
            try: launcher.wait(timeout=5)
            except subprocess.TimeoutExpired: launcher.terminate();launcher.wait(timeout=5)
        if net.poll() is None: net.terminate()
        net.wait(timeout=5);reader.join(timeout=2);net.stdout.close()


def aggregate(results):
    summary={}
    for provider in ('soundcloud','youtube'):
        rows=[r for r in results if r['provider']==provider]
        measured=[r for r in rows if r['status']=='measured']
        timings={}
        for key in ('page_to_ready_ms','play_to_progress_ms','resume_to_progress_ms','seek_to_observed_ms'):
            values=[r['timing'][key] for r in measured if r['timing'].get(key) is not None]
            timings[key]=dict(samples=len(values),min=min(values) if values else None,max=max(values) if values else None)
        summary[provider]=dict(runs=len(rows),measured_runs=len(measured),timing_ranges=timings,
                               received_bytes=[r['network']['received_bytes'] for r in rows],
                               sent_bytes=[r['network']['sent_bytes'] for r in rows],
                               status='measured' if rows and len(measured)==len(rows) else 'limited')
    return summary


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report',type=Path,required=True);parser.add_argument('--runs',type=int,default=3)
    parser.add_argument('--network-label',default='current network; SSID, addresses and credentials not collected')
    parser.add_argument('--provider',choices=['soundcloud','youtube','both'],default='both')
    args=parser.parse_args()
    if args.report.exists():parser.error('Report already exists')
    if not 1<=args.runs<=5:parser.error('Runs must be 1...5')
    results=[];report={}
    try:
        if platform.system()!='Darwin':raise RuntimeError('macOS_required')
        responsible=responsibility_lookup()
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='durvald-external-metrics-') as temporary:
                directory=Path(temporary);app=build_app(directory)
                for provider,item in [('soundcloud','293'),('youtube','M7lc1UVf-VE')]:
                    if args.provider not in ('both',provider):continue
                    for number in range(1,args.runs+1):
                        result=measure(app,provider,item,server.server_port,directory,number,responsible)
                        results.append(result);print(f'{provider} run {number}: {result["status"]}',flush=True)
        finally:server.shutdown();server.server_close();thread.join(timeout=2)
        report.update(status='measured' if results and all(r['status']=='measured' for r in results) else 'limited',summary=aggregate(results))
    except (OSError,ValueError,RuntimeError,TimeoutError,AttributeError,subprocess.SubprocessError) as error:
        report.update(status='blocked',reason=type(error).__name__,failure_stage=str(error) if isinstance(error,(RuntimeError,TimeoutError)) else 'environment_unavailable')
    report.update(schema=1,captured_at=dt.datetime.now(dt.timezone.utc).isoformat(),runs=results,network_label=args.network_label,
                  hardware=dict(os=platform.platform(),architecture=platform.machine(),model=subprocess.run(['sysctl','-n','hw.model'],capture_output=True,text=True).stdout.strip()),
                  source_sha256={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ('measure_external_players.py','MetricsWebKitProbe.swift','metrics-player.js','metrics-player.html')},
                  limitations=['Standalone optimized WKWebView app; excludes Durvald UI/core and code-signing/notarization',
                               'Nonpersistent WebKit storage per run; OS/DNS/CDN caches not flushed',
                               'Only the two public sample items and measured intervals; no provider-wide SLO or p95 from three runs',
                               'Position polling 250ms; stalls mean no observed clock advance >1s, not decoded acoustic silence',
                               'Resource phases use 500ms snapshots; phase boundaries have sampling error and include diagnostic polling overhead',
                               'Process RSS sums may double-count shared pages; CPU percent is relative to one core',
                               'nettop counters observed every second; short-lived/unattributed processes may be missed; byte counts are observational, not packet capture'])
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2)+'\n')
    print('External measurement: '+report['status'])
    return 0 if report['status']=='measured' else 1

if __name__=='__main__':raise SystemExit(main())
