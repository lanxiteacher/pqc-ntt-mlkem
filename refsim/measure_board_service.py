"""Measure actual board FSM service cycles using a temporary instrumented smoke TB.

RTL is unchanged. UART is accelerated to 5 Mbaud ONLY in simulation to reduce
runtime; chip clock stays 50 MHz. Service cycles exclude serial transfer.
Repeated NTT start interval includes the synthetic UART/testbench pacing and
must NOT be described as measured hardware throughput or maximal core rate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from check_polmul_param import REPO, tool, run


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    board = REPO/'rtl/board'
    original = board/'tb/smoke_tb.v'
    text = original.read_text(encoding='utf-8')
    # Keep real DUT and all coefficient/response assertions, change only TB pacing.
    for old,new in [('115200','5000000'),('8680','200'),('4340','100')]:
        text = text.replace(old,new)
    text = text.replace('#2000;', '#40;')
    begin = text.index('        send_cmd("#NTT 1", 6);')
    marker = '        chk("#DONE NTT 1 256", 15, "S2 #DONE");'
    end = text.index(marker,begin)+len(marker)
    text = text[:end]+'\n'+text[begin:end]+text[end:]
    monitor = '''
    integer audit_cycle = 0;
    integer audit_previous = -1;
    always @(posedge sys_clk) begin
        #2;
        audit_cycle = audit_cycle + 1;
        if (dut.u_fsm.state !== audit_previous) begin
            $display("AUDIT_STATE %0d %0d", audit_cycle, dut.u_fsm.state);
            audit_previous = dut.u_fsm.state;
        end
    end
'''
    text = text.replace('module smoke_tb;', 'module smoke_tb;\n'+monitor,1)
    sources = [original,*sorted(board.glob('*.v')),REPO/'rtl/uart_rx.v',REPO/'rtl/uart_tx.v',
               *sorted((REPO/'rtl/ntt_core').glob('*.v'))]
    result = dict(status='running', board_access=False, clock_hz=50000000,
                  uart_simulation_baud=5000000, runs=[],
                  source_sha256={p.relative_to(REPO).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),*sources]},
                  generated_tb_sha256=hashlib.sha256(text.encode('utf-8')).hexdigest())
    try:
        with tempfile.TemporaryDirectory(prefix='pqc_service_') as tmp:
            work = Path(tmp)
            tb = work/'service_tb.v'
            tb.write_bytes(text.encode('utf-8'))
            rtl = [p for p in sources if p != original]
            for pe in (1,4,16):
                exe = work/f'pe{pe}.vvp'
                macro = [] if pe == 1 else [f'-DTB_PE{pe}']
                run([tool('iverilog'),'-g2012','-s','smoke_tb',*macro,'-o',exe,tb,*rtl],work)
                try:
                    proc = subprocess.run([tool('vvp'), str(exe)], cwd=board/'tb',
                                          capture_output=True, encoding='utf-8', errors='replace', timeout=300)
                    if proc.returncode:
                        raise RuntimeError(proc.stdout + proc.stderr)
                    stdout = proc.stdout
                except subprocess.TimeoutExpired as exc:
                    partial = exc.stdout or b''
                    (out/f'pe{pe}_timeout.txt').write_bytes(partial.encode('utf-8') if isinstance(partial,str) else partial)
                    raise
                (out/f'pe{pe}.txt').write_bytes(stdout.encode('utf-8'))
                assert '[FAIL]' not in stdout and re.search(r'比对点 780 个，失败 0 个',stdout)
                events = [(int(c),int(s)) for c,s in re.findall(r'^AUDIT_STATE (\d+) (\d+)$',stdout,re.M)]
                windows=[]
                for i,(cycle,state) in enumerate(events):
                    if state != 3:
                        continue
                    nxt = events[i+1:i+4]
                    assert len(nxt)==3 and [s for c,s in nxt] == [4,5,1], nxt
                    start,read,finish = [c for c,s in nxt]
                    windows.append(dict(load= start-cycle, compute_control=read-start,
                                        read=finish-read, total=finish-cycle, load_entry=cycle))
                assert len(windows)==3 and windows[0]['total']==windows[1]['total']
                result['runs'].append(dict(pe=pe, ntt=windows[:2], pwm=windows[2],
                    repeated_ntt_load_entry_interval=windows[1]['load_entry']-windows[0]['load_entry'],
                    interval_scope='synthetic 5 Mbaud UART with smoke TB pacing; not real board throughput'))
                print(f'PASS pe{pe}: NTT service {windows[0]["total"]} cycles',flush=True)
        result['status']='pass'
    finally:
        if result['status'] != 'pass':
            result['status'] = 'fail'
        (out/'acceptance.json').write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'))


if __name__ == '__main__':
    main()
