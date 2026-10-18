"""Explicit board replay with provenance and bounded subprocess execution.

Does not program a board. Operator must first load the intended bitstream.
Offline tests can call run_session with an injected command runner; CLI cannot.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

from kem_trace import validate_trace, write_json

HERE=Path(__file__).resolve().parent
ROOT=HERE.parent


def run_session(trace, output, port, build, bitstream, frequency_mhz,
                baud=115200, timeout=180, runner=subprocess.run):
    trace,output,bitstream=map(lambda p:Path(p).resolve(),(trace,output,bitstream))
    if output.exists():raise FileExistsError('output must be a new directory')
    if not isinstance(port,str) or not port.strip():raise ValueError('explicit port required')
    if build not in (1,4,16):raise ValueError('explicit build 1/4/16 required')
    if baud not in (115200,921600):raise ValueError('use the project-supported baud 115200/921600')
    if not 0<float(frequency_mhz)<1000:raise ValueError('invalid declared frequency')
    if not 1<=timeout<=600:raise ValueError('timeout must be 1..600 seconds')
    payload=json.loads(trace.read_text(encoding='utf-8'))
    if payload.get('algorithm')!='ML-KEM-768' or payload.get('schema_version')!=1:
        raise ValueError('unsupported transcript')
    validate_trace(payload['records'])
    if not bitstream.is_file() or bitstream.suffix.lower()!='.bit':raise ValueError('existing .bit file required')
    output.mkdir(parents=True)
    cmd=[sys.executable,str(HERE/'kem_trace_replay.py'),str(trace),'--output',str(output/'serial'),
         '--port',port,'--build',str(build),'--baud',str(baud)]
    result=dict(status='running',source='serial_session',started_utc=datetime.now(timezone.utc).isoformat(),
                port=port,build=build,baud=baud,timeout_seconds=timeout,
                bitstream_file=str(bitstream),bitstream_sha256=hashlib.sha256(bitstream.read_bytes()).hexdigest(),
                declared_frequency_mhz=frequency_mhz,frequency_measured=False,
                programmed_bitstream_verified=False,
                trace_sha256=hashlib.sha256(trace.read_bytes()).hexdigest(),
                command=cmd,git_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip())
    write_json(output/'session.json',result)
    try:
        p=runner(cmd,cwd=ROOT,capture_output=True,timeout=timeout)
        for name,data in [('stdout',p.stdout),('stderr',p.stderr)]:
            (output/(name+'.txt')).write_bytes(data if isinstance(data,bytes) else (data or '').encode('utf-8'))
        result['returncode']=p.returncode
        if p.returncode:raise RuntimeError(f'board replay exited {p.returncode}; inspect stdout/stderr and serial/replay.json')
        replay=json.loads((output/'serial/replay.json').read_text(encoding='utf-8'))
        if (replay.get('status')!='pass' or replay.get('source')!='serial'
            or replay.get('transactions')!=15 or replay.get('passed_transactions')!=15
            or replay.get('coefficients')!=3840 or replay.get('trace_sha256')!=result['trace_sha256']
            or replay.get('port')!=port or replay.get('baud')!=baud
            or len(replay.get('results',[]))!=15):
            raise ValueError('incomplete or inconsistent serial replay evidence')
        for i,row in enumerate(replay['results']):
            if (row.get('id')!=i or row.get('phase')!=payload['records'][i]['phase']
                or row.get('build')!=build or row.get('status')!='pass' or row.get('mismatched')!=0
                or row.get('unpacked_values')!=[v%3329 for v in payload['records'][i]['output_signed']]):
                raise ValueError(f'invalid per-call evidence {i}')
        result.update(status='pass',transactions=15,coefficients=3840)
    except subprocess.TimeoutExpired as exc:
        for name,data in [('stdout',exc.stdout),('stderr',exc.stderr)]:
            (output/(name+'.txt')).write_bytes(data if isinstance(data,bytes) else (data or '').encode('utf-8'))
        result.update(status='timeout',error='child process timed out; partial evidence retained')
    except BaseException as exc:
        result.update(status='fail',error_type=type(exc).__name__,error=str(exc))
    finally:
        result['finished_utc']=datetime.now(timezone.utc).isoformat()
        write_json(output/'session.json',result)
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--trace',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--port',required=True)
    ap.add_argument('--build',type=int,choices=(1,4,16),required=True)
    ap.add_argument('--bitstream',type=Path,required=True)
    ap.add_argument('--frequency-mhz',type=float,required=True)
    ap.add_argument('--baud',type=int,choices=(115200,921600),default=115200)
    ap.add_argument('--timeout',type=int,default=180)
    args=ap.parse_args()
    result=run_session(args.trace,args.output,args.port,args.build,args.bitstream,args.frequency_mhz,args.baud,args.timeout)
    print(f"{result['status'].upper()}: session saved to {args.output}; frequency/loaded bitstream remain operator-declared")
    if result['status']!='pass':raise SystemExit(2)

if __name__=='__main__':main()
