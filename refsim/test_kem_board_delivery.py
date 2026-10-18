"""No-board tests for serial replay orchestration and evidence retention.

SerialLink is replaced by a byte-framed known-answer transport. Session tests
inject a child runner. These results never constitute hardware verification.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

import kem_trace_replay as replay_module
from kem_trace import hex_file,write_json
from run_kem_board import run_session


def test(trace, output):
    trace,output=Path(trace).resolve(),Path(output).resolve()
    if output.exists():raise FileExistsError('output must be new')
    output.mkdir(parents=True)
    payload=json.loads(trace.read_text(encoding='utf-8'))
    records=payload['records']
    results=[]
    with tempfile.TemporaryDirectory(prefix='kem_board_test_') as tmp:
        vectors=Path(tmp)
        hex_file(vectors/'ntt_batch_in.txt',[v for r in records for v in r['input_signed']])
        hex_file(vectors/'ntt_batch_exp.txt',[v for r in records for v in r['output_signed']])
        opened=[]
        class MockSerial(replay_module.link.LoopbackLink):
            BULK_WRITE=True
            def __init__(self,port,baud):
                self.closed=False
                self.writes=[]
                super().__init__(replay_module.fake_board.FakeBoard(batch_dir=vectors,build=4,physical_order=True))
                opened.append(self)
            def write(self,data):
                self.writes.append(bytes(data));return super().write(data)
            def close(self):self.closed=True
        def call(name,build=4):
            with patch.object(replay_module.link,'SerialLink',MockSerial):
                return replay_module.replay(trace,output/name,'MOCK_ONLY',build,921600)
        good=call('mock_serial_success')
        assert good['status']=='pass' and good['transactions']==15 and good['passed_transactions']==15
        assert opened[-1].closed and len(opened[-1].writes)==30 # command+bulk for each NTT
        assert all(len(opened[-1].writes[i].splitlines())==256 for i in range(1,30,2))
        results.append('mock serial explicit build/baud, 15 calls bulk path, close and full evidence')
        try:call('wrong_build',1)
        except ValueError as exc:assert 'RDY build conflicts' in str(exc)
        else:raise AssertionError('wrong RDY accepted')
        bad=json.loads((output/'wrong_build/replay.json').read_text())
        assert bad['status']=='fail' and bad['transactions']==0 and opened[-1].closed
        results.append('wrong RDY rejected; failure evidence retained; transport closed')
        # Correct protocol/checksum carrying an intentionally wrong numeric result.
        expected=[v for r in records for v in r['output_signed']]
        expected[0]=(expected[0]+1)%3329
        hex_file(vectors/'ntt_batch_exp.txt',expected)
        try:call('wrong_value')
        except ValueError as exc:assert '1 mismatched' in str(exc)
        else:raise AssertionError('wrong numeric serial result accepted')
        bad=json.loads((output/'wrong_value/replay.json').read_text())
        assert bad['status']=='fail' and bad['results'][0]['mismatched']==1
        assert bad['passed_transactions']==0 and opened[-1].closed
        results.append('wrong numeric result rejected; raw rows and transaction log retained')
        with patch.object(replay_module.link,'SerialLink',side_effect=SystemExit('MOCK open failed')):
            try:replay_module.replay(trace,output/'open_failure','MOCK_ONLY',4,921600)
            except SystemExit:pass
            else:raise AssertionError('open failure accepted')
        assert json.loads((output/'open_failure/replay.json').read_text())['status']=='fail'
        results.append('port open failure retained as fail')
        bit=vectors/'dummy_test_only.bit';bit.write_bytes(b'NOT A BITSTREAM; MOCK TEST ONLY')
        def success_runner(cmd,**kwargs):
            dst=Path(cmd[cmd.index('--output')+1]);dst.mkdir()
            shutil.copyfile(output/'mock_serial_success/replay.json',dst/'replay.json')
            return subprocess.CompletedProcess(cmd,0,b'MOCK SUCCESS\n',b'')
        session=run_session(trace,output/'session_success','MOCK_ONLY',4,bit,75,921600,runner=success_runner)
        assert session['status']=='pass' and session['transactions']==15
        assert not session['frequency_measured'] and not session['programmed_bitstream_verified']
        results.append('session success requires all 15 numeric results; provenance remains declared')
        def nonzero(cmd,**kwargs):return subprocess.CompletedProcess(cmd,2,b'partial\n',b'MOCK failure\n')
        session=run_session(trace,output/'session_nonzero','MOCK_ONLY',4,bit,75,921600,runner=nonzero)
        assert session['status']=='fail' and (output/'session_nonzero/stderr.txt').read_bytes()==b'MOCK failure\n'
        results.append('child nonzero rejected and stdout/stderr retained')
        def timeout_runner(cmd,**kwargs):
            return subprocess.run([sys.executable,'-c',"import time;print('MOCK partial',flush=True);time.sleep(5)"],
                                  capture_output=True,timeout=0.2)
        session=run_session(trace,output/'session_timeout','MOCK_ONLY',4,bit,75,921600,runner=timeout_runner)
        assert session['status']=='timeout' and (output/'session_timeout/stdout.txt').is_file()
        results.append('real subprocess timeout caught; partial evidence retained')
        def incomplete(cmd,**kwargs):
            p=success_runner(cmd,**kwargs)
            dst=Path(cmd[cmd.index('--output')+1])/'replay.json'
            data=json.loads(dst.read_text());data['results'][5]['id']=99;write_json(dst,data)
            return p
        session=run_session(trace,output/'session_bad_evidence','MOCK_ONLY',4,bit,75,921600,runner=incomplete)
        assert session['status']=='fail'
        results.append('zero child exit with invalid per-call evidence rejected')
        before=(output/'session_success/session.json').read_bytes()
        try:run_session(trace,output/'session_success','MOCK_ONLY',4,bit,75,921600,runner=success_runner)
        except FileExistsError:pass
        else:raise AssertionError('old session overwritten')
        assert (output/'session_success/session.json').read_bytes()==before
        results.append('existing session rejected without overwriting evidence')
    result=dict(status='pass',scope='mock transports/child runners only; NO board or electrical timing test',
                checks=results,hardware_tested=False)
    write_json(output/'tests.json',result)
    print(f'PASS: {len(results)} board-delivery orchestration checks; all mock, no hardware.')
    return result


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('trace',type=Path);ap.add_argument('--output',type=Path,required=True)
    args=ap.parse_args();test(args.trace,args.output)
