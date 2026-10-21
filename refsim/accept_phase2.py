"""B Phase 2: board evidence audit, 100 NTT vectors, 3 KAT traces, 51 mutants.

Runs locally without Vivado/board. --stage permits separate dated evidence.
Surviving mutants are reported, never converted into detected faults.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import random
import subprocess

from check_polmul_param import HERE, REPO, read_hex, tool, write_hex
from accept_strengthening import checked, build_oracles, mutation_stage, digest, save
from kem_trace import extract, read_first_kat, SOURCES, REF
from kem_trace_rtl import replay as rtl_replay, verify_output


def audit_board(work):
    trace_file=REPO/'logs/verification_2026-10-18_B_kem_delivery_trace.json'
    payload=json.loads(trace_file.read_text(encoding='utf-8'))
    trace_hash=digest(trace_file);rows=[]
    for pe in (1,4,16):
        folder=REPO/f'logs/verification_2026-10-21_A_kem_serial_pe{pe}'
        s=json.loads((folder/'session.json').read_text())
        r=json.loads((folder/'serial/replay.json').read_text())
        assert s['status']==r['status']=='pass' and r['source']=='serial'
        assert s['trace_sha256']==r['trace_sha256']==trace_hash
        assert s['build']==pe and s['transactions']==r['transactions']==r['passed_transactions']==15
        assert s['coefficients']==r['coefficients']==3840 and len(r['results'])==15
        for i,row in enumerate(r['results']):
            assert row['id']==i and row['phase']==payload['records'][i]['phase']
            assert row['build']==pe and row['status']=='pass' and row['mismatched']==0
            assert row['unpacked_values']==[v%3329 for v in payload['records'][i]['output_signed']]
        rows.append(dict(pe=pe,status='pass',transactions=15,coefficients=3840,
                         session_sha256=digest(folder/'session.json'),replay_sha256=digest(folder/'serial/replay.json'),
                         bitstream_sha256=s['bitstream_sha256'],declared_frequency_mhz=s['declared_frequency_mhz'],
                         baud=s['baud'],frequency_measured=s['frequency_measured'],
                         programmed_bitstream_verified=s['programmed_bitstream_verified']))
    result=dict(status='pass',scope='offline audit of A archived serial results; no new hardware run',
                trace_sha256=trace_hash,transactions=45,coefficients=11520,builds=rows)
    save(work/'result.json',result);print('BOARD EVIDENCE: 45 calls / 11520 values match original trace',flush=True)
    return result


def ntt100(work):
    build_oracles(work)
    checked([tool('gcc'),'-O2','-Wall','-I'+str(REF),'-o',work/'signed.exe',HERE/'ntt_signed_tool.c',
             *[REF/(n+'.c') for n in SOURCES],REPO/'research/mlkem_kat/randombytes_stub.c'],work,'compile_signed')
    old=read_hex(HERE/'batch/ntt_batch_in.txt',4096)
    frozen=read_hex(HERE/'batch/ntt_batch_exp.txt',4096)
    samples=[old[g*256:(g+1)*256] for g in range(16)]
    rng=random.Random(20261021)
    added=[[rng.randrange(3329) for _ in range(256)] for _ in range(84)]
    # Preserve all 16 existing vectors. Each new row has randomized remaining
    # coefficients plus explicit signed/boundary representatives.
    for row in added:row[:6]=[0,3328,3329,-1,-3329,-3328]
    samples+=added
    assert len({tuple(r) for r in samples})==100
    assert min(len(set(r)) for r in added)>200
    records=[]
    for g,row in enumerate(samples):
        (work/'signed.txt').write_bytes((''.join(f'{v}\n' for v in row)).encode('ascii'))
        checked([work/'signed.exe','signed.txt','signed_gold.txt'],work,f'signed_{g}')
        gold=read_hex(work/'signed_gold.txt',256)
        write_hex(work/'canonical.txt',[v%3329 for v in row])
        checked([work/'ntt.exe','canonical.txt','canonical_gold.txt','--ntt'],work,f'canonical_{g}')
        assert gold==read_hex(work/'canonical_gold.txt',256),'signed/canonical NTT disagreement'
        if g<16:assert gold==frozen[g*256:(g+1)*256],'old vector answer changed'
        records.append(dict(id=g,phase='original' if g<16 else 'random_with_boundaries',
                            input_signed=row,output_signed=gold))
    # Direct comparison of full signed inputs against canonical C calculations
    # independently anchors modulo conversion before the 12-bit RTL interface.
    save(work/'inputs_and_expected.json',dict(seed=20261021,records=records))
    write_hex(work/'timing_in.txt',[v%3329 for row in samples for v in row])
    builds=[]
    for pe in (1,4,16):
        checked([tool('iverilog'),'-g2012','-s','strengthening_timing_tb',f'-DCFG_PE_NUM={pe}',
                 '-DCFG_NV=100','-o',work/f'pe{pe}.vvp',*sorted((REPO/'rtl/ntt_core').glob('*.v')),
                 HERE/'strengthening_timing_tb.v'],work,f'compile_pe{pe}')
        out=checked([tool('vvp'),work/f'pe{pe}.vvp'],work,f'simulate_pe{pe}')
        rows=verify_output(out,records,pe)
        bad=copy.deepcopy(records);bad[37]['output_signed'][100]=(bad[37]['output_signed'][100]+1)%3329
        try:verify_output(out,bad,pe)
        except ValueError as exc:
            assert '1 wrong coefficients; first=100' in str(exc)
        else:raise AssertionError('bad expected accepted')
        builds.append(dict(pe=pe,status='pass',groups=100,coefficients=25600,
                           negative_mismatches=1,negative_location=[37,100],results=rows))
        print(f'NTT100 pe{pe}: 100/100, 25600/25600; signed boundary and single-error controls PASS',flush=True)
    result=dict(status='pass',seed=20261021,original_groups=16,new_random_groups=84,
                boundary_representatives=[0,3328,3329,-1,-3329,-3328],
                boundary_scope='signed values checked in C; RTL receives modulo-3329 canonical coefficients',
                input_sha256=digest(work/'timing_in.txt'),total_coefficients=76800,builds=builds)
    save(work/'result.json',result);return result


def traces(work):
    results=[];hashes=[];keys=[]
    for count in (0,1,2):
        folder=work/f'kat_{count}'
        summary=extract(folder,kat_count=count)
        rtl=rtl_replay(folder/'trace.json',folder/'rtl')
        h=digest(folder/'trace.json');hashes.append(h)
        fixture,_=read_first_kat(count);keys.append(fixture['pk'])
        if count==0:
            assert (folder/'trace.json').read_bytes()==(REPO/'logs/verification_2026-10-18_B_kem_delivery_trace.json').read_bytes()
        results.append(dict(kat_count=count,status='pass',trace_sha256=h,
                            pk_sha256=hashlib.sha256(bytes.fromhex(fixture['pk'])).hexdigest(),
                            d_sha256=hashlib.sha256(bytes.fromhex(fixture['d'])).hexdigest(),
                            phase_counts=summary['phase_counts'],rtl_transactions=rtl['transactions'],
                            rtl_coefficients=rtl['coefficients']))
        print(f'TRACE KAT count={count}: extraction/KAT/C/RTL PASS',flush=True)
    assert len(set(hashes))==len(set(keys))==3
    for invalid in (-1,100000):
        try:read_first_kat(invalid)
        except ValueError:pass
        else:raise AssertionError('invalid KAT count accepted')
    result=dict(status='pass',scope='three different community-compatible KAT records; forward NTT only',
                rtl_transactions=135,rtl_coefficients=34560,new_board_runs_performed=False,transcripts=results)
    save(work/'result.json',result);return result


def mutations(work):
    builds=[]
    for pe in (1,4,16):
        folder=work/f'pe{pe}';folder.mkdir();build_oracles(folder)
        rows=mutation_stage(folder,pe=pe,require_all_detected=False)
        builds.append(dict(pe=pe,baseline=rows[0],mutants=rows[1:]))
        save(work/'progress.json',builds)
    detected=[r for b in builds for r in b['mutants'] if r['status'].startswith('detected_')]
    survivors=[r for b in builds for r in b['mutants'] if r['status']=='pass']
    for row in survivors:
        row['classification']='survived_requires_analysis'
        if row['id']=='serializer_order' and row['build']==1:
            row['classification']='equivalent_for_pe1'
            row['reason']='PE=1: rsub always 0; original PE_NUMBER-1-rsub=0, mutant rsub=0. No lane order exists to reverse.'
    result=dict(status='completed',baseline_passes=3,attempted_mutants=51,detected=len(detected),
                survivors=survivors,builds=builds,
                scope='FULL 16 groups per PE; surviving/equivalent mutants NOT counted as detected')
    save(work/'result.json',result)
    print(f'MUTATION MATRIX: {len(detected)}/51 detected; {len(survivors)} survivors retained for analysis',flush=True)
    return result


STAGES={'board_audit':audit_board,'ntt100':ntt100,'traces':traces,'mutations':mutations}
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--stage',choices=['all',*STAGES],default='all')
    args=ap.parse_args();work=args.output.resolve()
    if work.exists():raise FileExistsError('choose a NEW output directory')
    work.mkdir(parents=True)
    sources=[*sorted((REPO/'rtl/ntt_core').glob('*.v')),*sorted(REF.glob('*.[ch]')),
             *sorted(HERE.glob('*.py')),*sorted(HERE.glob('*.v')),*sorted(HERE.glob('*.c')),
             REPO/'research/mlkem_kat/kat_MLKEM_768.rsp',REPO/'research/mlkem_kat/randombytes_stub.c',
             *sorted((HERE/'batch').glob('*.txt'))]
    hashes={str(p.relative_to(REPO)).replace('\\','/'):digest(p) for p in sources}
    result=dict(status='running',source_sha256=hashes,stages={},board_access=False,
                git_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip())
    save(work/'acceptance.json',result)
    try:
        for name,fn in STAGES.items():
            if args.stage not in ('all',name):continue
            folder=work/name;folder.mkdir()
            result['stages'][name]=fn(folder)
            save(work/'acceptance.json',result)
        assert all(digest(REPO/p)==h for p,h in hashes.items()),'source changed during acceptance'
        result['status']='complete'
    except BaseException as exc:
        result.update(status='fail',error=str(exc));raise
    finally:save(work/'acceptance.json',result)
    print('COMPLETE: requested Phase 2 checks executed; read mutation survivors explicitly. No board accessed.',flush=True)

if __name__=='__main__':main()
