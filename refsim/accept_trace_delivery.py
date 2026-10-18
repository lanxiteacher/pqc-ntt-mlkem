"""Unified offline acceptance: fresh KAT trace, actual RTL, bulk Host, board kit tests.

No physical serial port is opened. Requires gcc, iverilog/vvp and Python.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from kem_trace import write_json
from accept_strengthening import checked

HERE=Path(__file__).resolve().parent
ROOT=HERE.parent


def accept(output):
    output=Path(output).resolve()
    if output.exists():raise FileExistsError('output must be new')
    output.mkdir(parents=True)
    tracked=subprocess.check_output(['git','ls-files','refsim','host/src','rtl/ntt_core','research/kyber_ref'],cwd=ROOT,text=True).splitlines()
    # Include new files before first commit as well.
    tracked+=['refsim/kem_trace_rtl.py','refsim/run_kem_board.py','refsim/test_kem_board_delivery.py',
              'refsim/accept_trace_delivery.py','host/src/test_bulk_pipeline.py']
    hashes={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sorted(set(tracked)) if (ROOT/name).is_file()}
    summary=dict(status='running',board_tested=False,source_sha256=hashes,
                 git_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),stages=[])
    write_json(output/'acceptance.json',summary)
    stages=[('fresh_kat_trace',[sys.executable,HERE/'accept_kem_trace.py','--output',output/'trace']),
            ('actual_rtl',[sys.executable,HERE/'kem_trace_rtl.py',output/'trace/trace.json','--output',output/'rtl']),
            ('bulk_host',[sys.executable,ROOT/'host/src/test_bulk_pipeline.py']),
            ('board_delivery_mocks',[sys.executable,HERE/'test_kem_board_delivery.py',output/'trace/trace.json','--output',output/'delivery_tests'])]
    try:
        for index,(name,cmd) in enumerate(stages,1):
            out=checked(cmd,output,name)
            summary['stages'].append(dict(name=name,status='pass'))
            write_json(output/'acceptance.json',summary)
            print(f'{index}/4 PASS: {name}\n'+out.strip().splitlines()[-1],flush=True)
        rtl=json.loads((output/'rtl/replay.json').read_text())
        if rtl['status']!='pass' or rtl['transactions']!=45 or rtl['coefficients']!=11520:
            raise ValueError('incomplete RTL verification')
        # Preserve the exact artifact to hand off to the board operator.
        kit=output/'board_kit';kit.mkdir()
        raw=(output/'trace/trace.json').read_bytes();(kit/'trace.json').write_bytes(raw)
        write_json(kit/'manifest.json',dict(trace_sha256=hashlib.sha256(raw).hexdigest(),
                   algorithm='ML-KEM-768',calls=15,builds=[1,4,16],board_tested=False,
                   instructions='Read refsim/trace_delivery_README.md; use run_kem_board.py with explicit port/build/bitstream/frequency.'))
        if any(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()!=h for p,h in hashes.items()):
            raise AssertionError('source changed during acceptance')
        summary.update(status='pass',rtl_transactions=45,rtl_coefficients=11520,
                       bulk_transactions=480,board_delivery_checks=9,trace_sha256=hashlib.sha256(raw).hexdigest())
    except BaseException as exc:
        summary.update(status='fail',error=str(exc));raise
    finally:write_json(output/'acceptance.json',summary)
    print('PASS: offline trace delivery complete; actual RTL 45/45; bulk and board-kit checks PASS; board NOT tested.')
    return summary


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output',type=Path,required=True)
    args=ap.parse_args();accept(args.output)
