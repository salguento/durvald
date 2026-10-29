#!/usr/bin/env python3
"""Opt-in real slskd -> production core -> isolated reviewed import proof."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid
from slskd_backend import STATE, private_json, status, verified_installation

ROOT=Path(__file__).resolve().parents[2]
PHASES=('transfer','import','verify')


def selection(value):
    if not isinstance(value,dict) or set(value)!={'query','peer','filename','size_bytes'}:
        raise ValueError('Supply one explicit query, peer, filename and byte size')
    for key in ('query','peer','filename'):
        text=value[key]
        if not isinstance(text,str) or not text.strip() or len(text)>2048 or any(ord(c)<32 for c in text):
            raise ValueError('Invalid selection')
    if len(value['query'])>200 or '..' in value['filename'].replace('\\','/').split('/'):
        raise ValueError('Invalid selection')
    if Path(value['filename'].replace('\\','/')).suffix.lower() not in ('.mp3','.wav','.flac','.ogg','.oga'):
        raise ValueError('Selected file must use a supported audio format')
    if type(value['size_bytes']) is not int or not 0<value['size_bytes']<=256*1024*1024:
        raise ValueError('Select one file no larger than 256 MiB')
    return dict(value)


def collect(binary,config,environment,workspace,timeout):
    phases={}
    for phase in PHASES:
        try:
            result=subprocess.run([str(binary),str(config),phase],env=environment,capture_output=True,timeout=timeout if phase=='transfer' else 180)
        except subprocess.TimeoutExpired as error:
            result=subprocess.CompletedProcess([],1,error.stdout or b'',error.stderr or b'')
        # Logs can contain selected paths from dependencies; retain privately only.
        log=workspace/f'{phase}.log'
        descriptor=os.open(log,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(descriptor,'wb') as stream:stream.write(result.stdout+result.stderr)
        output=workspace/f'{phase}-result.json'
        observation=json.loads(output.read_text()) if output.exists() else {'status':'missing_report'}
        phases[phase]=observation
        if result.returncode or observation.get('status')!='passed' or observation.get('credential_cleanup_confirmed') is not True:
            try:
                cleanup=subprocess.run([str(binary),str(config),'cleanup'],env=environment,capture_output=True,timeout=120)
                receipt=workspace/'cleanup-result.json'
                phases['cleanup']=json.loads(receipt.read_text()) if receipt.exists() else {'status':'missing_report'}
                if cleanup.returncode: phases['cleanup']['status']='failed'
            except (OSError,ValueError,subprocess.SubprocessError):
                phases['cleanup']={'status':'unconfirmed'}
            break
    return phases


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--selection',type=Path,required=True,help='Private JSON with the exact reviewed file; never chooses a result automatically')
    parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--timeout',type=int,default=120)
    args=parser.parse_args()
    if args.report.exists():parser.error('Report already exists')
    if not 10<=args.timeout<=600:parser.error('Timeout must be 10...600 seconds')
    report={'schema':1,'status':'blocked','real_soulseek_network_tested':False,'phases':{}}
    workspace=None
    try:
        chosen=selection(json.loads(args.selection.read_text()))
        verified_installation()
        connection=status()
        if not connection.get('api_authenticated') or not connection.get('soulseek_logged_in'):
            raise RuntimeError('Existing validation backend must be running and logged in')
        backend=json.loads((STATE/'slskd.yml').read_text())
        credentials=json.loads((STATE/'credentials.json').read_text())
        if backend.get('shares',{}).get('directories'):
            raise RuntimeError('Validation backend must keep library sharing disabled')
        binary=ROOT/'durvald-core/target/debug/examples/soulseek_acquisition_probe'
        if not binary.is_file():raise RuntimeError('Build soulseek_acquisition_probe before executing')
        workspace=STATE.parent/'acquisition'/str(uuid.uuid4())
        workspace.mkdir(parents=True,mode=0o700)
        mapped=Path(backend['directories']['downloads']).resolve(strict=True)
        config=workspace/'input.json'
        private_json(config,dict(root=str(workspace.resolve()),endpoint=f"http://127.0.0.1:{credentials['port']}",
                                 selection={**chosen,'remote_download_root':str(mapped),'mapped_download_root':str(mapped)},
                                 transfer_timeout_seconds=args.timeout))
        environment=dict(os.environ,SLSKD_API_KEY=credentials['api_key'])
        phases=collect(binary,config,environment,workspace,args.timeout+120)
        passed=len(phases)==3 and all(p.get('status')=='passed' and p.get('credential_cleanup_confirmed') is True for p in phases.values())
        report.update(status='passed' if passed else 'limited',real_soulseek_network_tested=phases.get('transfer',{}).get('checks',{}).get('backend_completion_confirmed') is True,real_backend_contacted=True,phases=phases,
                      backend_version=connection.get('version'),production_path='DurvaldCore public facade; native initialization; no playback started',
                      process_restarts=2 if passed else max(0,len(phases)-1),library_shared=False,
                      identities_redacted=True,private_recovery_run=workspace.name,
                      limitations=['Single explicitly selected file, native local slskd mapping; no claim about album completeness or remote mounts',
                                   'Successful reimport validates favorite and source identity; other personal-value cases remain covered by offline tests',
                                   'Cancellation and partial-batch recovery need their own explicitly selected real cases; not inferred from single-file success'])
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as error:
        # Do not export exception text, selections, keys, peers or mapped paths.
        report.update(reason=type(error).__name__,private_recovery_run=workspace.name if workspace else None)
    report.update(captured_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                  source_sha256={name:hashlib.sha256(path.read_bytes()).hexdigest() for name,path in {
                      'live_acquisition.py':Path(__file__),
                      'soulseek_acquisition_probe.rs':ROOT/'durvald-core/examples/soulseek_acquisition_probe.rs'}.items()})
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2)+'\n')
    print('Live acquisition: '+report['status'])
    return 0 if report['status']=='passed' else 1

if __name__=='__main__':raise SystemExit(main())
