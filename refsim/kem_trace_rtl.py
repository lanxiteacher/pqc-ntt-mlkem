"""Actually calculate the 15 ML-KEM forward NTT calls in pe1/4/16 RTL.

Uses the existing bounded batch FNTT bench, with CFG_NV=15. No board access.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from check_polmul_param import HERE, REPO, tool, read_hex
from kem_trace import validate_trace, hex_file, write_json, SOURCES, REF
from accept_strengthening import checked


def verify_output(out, records, pe):
    n = len(records)
    values, cycles = {}, {}
    if any(word in out for word in ('WARNING', 'ERROR', 'FATAL')):
        raise ValueError('RTL warning/error')
    for line in out.splitlines():
        t = line.split()
        if not t:
            continue
        if t[0] == 'VALUE':
            if len(t) != 4 or not re.fullmatch('[0-9a-fA-F]{3}', t[3]):
                raise ValueError('unknown/malformed RTL value')
            key = (int(t[1]), int(t[2]))
            if not (0 <= key[0] < n and 0 <= key[1] < 256) or key in values:
                raise ValueError('duplicate/out-of-range RTL value')
            values[key] = int(t[3], 16)
        elif t[0] == 'CYCLES':
            if len(t) != 3 or int(t[1]) in cycles:
                raise ValueError('duplicate/malformed cycle')
            cycles[int(t[1])] = int(t[2])
    if out.splitlines().count(f'COMPLETE_TIMING {pe} {n}') != 1 or len(values) != n*256 or set(cycles) != set(range(n)):
        raise ValueError('incomplete RTL output')
    expected_cycles = {1:907, 4:235, 16:72}[pe]
    rows = []
    for g, record in enumerate(records):
        if cycles[g] != expected_cycles:
            raise ValueError(f'pe{pe} call{g}: incorrect latency')
        physical = [values[g, i] for i in range(256)]
        canonical = [0]*256
        for i, x in enumerate(physical):
            j = i//4*4+[0,2,1,3][i%4] if pe == 1 else i
            canonical[j] = x
        gold = [v % 3329 for v in record['output_signed']]
        bad = [i for i in range(256) if canonical[i] != gold[i]]
        if bad:
            raise ValueError(f'pe{pe} call{g}: {len(bad)} wrong coefficients; first={bad[0]}')
        rows.append(dict(id=record['id'], phase=record['phase'], status='pass',
                         coefficients=256, top_cycles=cycles[g], core_cycles=cycles[g]-3,
                         physical_output=physical, canonical_output=canonical))
    return rows


def replay(trace, output):
    trace, output = Path(trace).resolve(), Path(output).resolve()
    if output.exists():
        raise FileExistsError('output must be a new directory')
    payload = json.loads(trace.read_text(encoding='utf-8'))
    if payload.get('algorithm') != 'ML-KEM-768' or payload.get('schema_version') != 1:
        raise ValueError('unsupported transcript')
    records = payload['records']
    counts = validate_trace(records)
    output.mkdir(parents=True)
    sources = [*sorted((REPO/'rtl/ntt_core').glob('*.v')),
               *sorted(REF.glob('*.[ch]')), HERE/'strengthening_timing_tb.v',
               HERE/'kem_trace_rtl.py', HERE/'ntt_once_tool.c',
               REPO/'research/mlkem_kat/randombytes_stub.c']
    hashes = {str(p.relative_to(REPO)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    result = dict(status='running', source='rtl_simulation', board_tested=False,
                  trace_sha256=hashlib.sha256(trace.read_bytes()).hexdigest(),
                  source_sha256=hashes, phase_counts=counts, builds=[])
    write_json(output/'replay.json',result)
    try:
        libs = [REF/(n+'.c') for n in SOURCES]
        libs.append(REPO/'research/mlkem_kat/randombytes_stub.c')
        checked([tool('gcc'),'-O2','-Wall','-I'+str(REF),'-o',output/'oracle.exe',
                 HERE/'ntt_once_tool.c',*libs],output,'compile_oracle')
        for r in records:
            hex_file(output/'oracle_in.txt',r['input_signed'])
            checked([output/'oracle.exe','oracle_in.txt','oracle_out.txt','--ntt'],output,f'oracle_{r["id"]}')
            if read_hex(output/'oracle_out.txt',256) != [v % 3329 for v in r['output_signed']]:
                raise ValueError('trace disagrees with fresh C oracle')
        hex_file(output/'timing_in.txt',[v for r in records for v in r['input_signed']])
        for pe in (1,4,16):
            checked([tool('iverilog'),'-g2012','-s','strengthening_timing_tb',
                     f'-DCFG_PE_NUM={pe}',f'-DCFG_NV={len(records)}','-o',output/f'pe{pe}.vvp',
                     *sorted((REPO/'rtl/ntt_core').glob('*.v')),HERE/'strengthening_timing_tb.v'],output,f'compile_pe{pe}')
            out = checked([tool('vvp'),output/f'pe{pe}.vvp'],output,f'simulate_pe{pe}')
            rows = verify_output(out,records,pe)
            # Negative control: changing one expected trace coefficient must fail.
            altered = json.loads(json.dumps(records))
            altered[7]['output_signed'][100] = (altered[7]['output_signed'][100]+1)%3329
            try:
                verify_output(out,altered,pe)
            except ValueError as exc:
                if '1 wrong coefficients' not in str(exc): raise
            else:
                raise AssertionError('corrupted expected trace accepted')
            first_value=next(s for s in out.splitlines() if s.startswith('VALUE '))
            bad_outputs=[
                ('unknown_value',out.replace(first_value,'VALUE 0 0 xxx',1)),
                ('duplicate_value',out+'\n'+first_value+'\n'),
                ('missing_completion',out.replace(f'COMPLETE_TIMING {pe} 15','REMOVED_COMPLETION',1)),
            ]
            rejected=[]
            for name,bad_out in bad_outputs:
                try:verify_output(bad_out,records,pe)
                except ValueError:rejected.append(name)
                else:raise AssertionError('bad RTL output accepted: '+name)
            result['builds'].append(dict(pe=pe,status='pass',transactions=len(rows),
                    coefficients=len(rows)*256,negative_corrupted_expected='rejected',
                    negative_output_guards=rejected,results=rows))
            write_json(output/'replay.json',result)
            print(f'RTL pe{pe}: 15/15 calls, 3840/3840 coefficients; latency and bad-answer rejection PASS',flush=True)
        if any(hashlib.sha256((REPO/p).read_bytes()).hexdigest()!=h for p,h in hashes.items()):
            raise AssertionError('source changed during RTL replay')
        result.update(status='pass',transactions=45,coefficients=11520)
    except BaseException as exc:
        result.update(status='fail',error=str(exc))
        raise
    finally:
        write_json(output/'replay.json',result)
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('trace',type=Path)
    ap.add_argument('--output',type=Path,required=True)
    args=ap.parse_args()
    replay(args.trace,args.output)
    print('PASS: actual RTL arithmetic for 45 ML-KEM NTT calls; board NOT tested.')

if __name__=='__main__':main()
