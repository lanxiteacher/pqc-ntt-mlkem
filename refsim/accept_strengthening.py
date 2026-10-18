"""Reproducible RTL fault detection, followed by 100 random FNTT timing checks.

Original RTL/reference files are read only. All mutants, builds and raw logs
are retained below a new --output directory. Requires Python, gcc, iverilog/vvp.
"""
import argparse
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import subprocess
import time

from check_polmul_param import HERE, REPO, tool, read_hex, write_hex, parse_output, compare

CORE = REPO / 'rtl/ntt_core'
# One exact replacement per mutant; compilation failures NEVER count as kills.
MUTATIONS = [
 ('add_modulus', 'modadd.v', "R - 13'd3329", "R - 13'd3328", 'wrong modular-add modulus'),
 ('sub_modulus', 'modsub.v', "R + 13'd3329", "R + 13'd3328", 'wrong modular-subtract modulus'),
 ('sub_sign', 'modsub.v', '(R[12] == 0)', '(R[12] != 0)', 'inverted borrow correction'),
 ('mul_operator', 'intmul.v', 'P_DSP = A*B;', 'P_DSP = A+B;', 'multiply replaced by add'),
 ('div2_parity', 'div2.v', "11'd1665", "11'd1664", 'wrong odd-input division correction'),
 ('ct_input', 'butterfly.v', 'assign w0 = (CT) ? w5r0 : B;', 'assign w0 = (CT) ? B : w5r0;', 'CT input mux swapped'),
 ('ct_delay', 'butterfly.v', 'assign w1 = (CT) ? Ar1  : A;', 'assign w1 = A;', 'CT alignment register bypassed'),
 ('inverse_delay', 'butterfly.v', 'assign w7 = (CT) ? w2r0 : w2r2;', 'assign w7 = w2r0;', 'inverse output pipeline bypassed'),
 ('twiddle_delay', 'butterfly.v', 'assign Ww = (CT) ? W : Wr0;', 'assign Ww = W;', 'inverse twiddle alignment bypassed'),
 ('butterfly_output', 'butterfly.v', 'assign O = w6r0;', 'assign O = w7;', 'odd output uses even output'),
 ('read_address', 'addressgenerator.v', 'raddr0          <= raddr;', "raddr0          <= raddr + 1'b1;", 'read address off by one'),
 ('write_address', 'addressgenerator.v', 'waddr0          <= waddrd0;', "waddr0          <= waddrd0 + 1'b1;", 'write address off by one'),
 ('twiddle_address', 'addressgenerator.v', 'assign raddr_tw = raddr_twd0;', "assign raddr_tw = raddr_twd0 + 1'b1;", 'twiddle index off by one'),
 ('bank_select', 'KyberHPMNTT.v', "de0[bg] = (load_ab || read_ab || exec_ab) ? 1'b0 : de2[bg];", "de0[bg] = (load_ab || read_ab || exec_ab) ? de2[bg] : 1'b0;", 'bank A write enable selection inverted'),
 ('pwm_bank', 'KyberHPMNTT.v', "dr1[bg] = (curr_state == OP_PWM2) ? {1'b1, drb_src} : dr2[bg];", "dr1[bg] = (curr_state == OP_PWM2) ? {1'b0, drb_src} : dr2[bg];", 'PWM bank B half address wrong'),
 ('serializer_order', 'KyberHPMNTT_top.v', 'dsel     = PE_NUMBER - 1 - rsub;', 'dsel     = rsub;', 'output lane order reversed'),
 ('load_alignment', 'KyberHPMNTT_top.v', 'din_core = sr[12*PE_NUMBER-1:0];', 'din_core = sr[12*PE_NUMBER+11:12];', 'input serial alignment shifted one coefficient'),
]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save(path, value):
    path.write_bytes((json.dumps(value, ensure_ascii=False, indent=2)+'\n').encode('utf-8'))

def command(args, cwd, stem, timeout=180):
    start=time.monotonic()
    try:
        p=subprocess.run([str(a) for a in args], cwd=cwd, capture_output=True,
                         encoding='utf-8', errors='replace', timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        # Timeout is a distinct infrastructure/inconclusive result, never a kill.
        for suffix, content in [('stdout',exc.stdout),('stderr',exc.stderr)]:
            data=content if isinstance(content,bytes) else (content or '').encode('utf-8')
            (cwd/(stem+'.'+suffix+'.txt')).write_bytes(data)
        save(cwd/(stem+'.command.json'),{'args':[str(a) for a in args],
             'status':'timeout','timeout_seconds':timeout})
        raise RuntimeError(f'tool timeout ({timeout}s): {args[0]}') from exc
    (cwd/(stem+'.stdout.txt')).write_bytes(p.stdout.encode('utf-8'))
    (cwd/(stem+'.stderr.txt')).write_bytes(p.stderr.encode('utf-8'))
    save(cwd/(stem+'.command.json'), {'args':[str(a) for a in args],
         'returncode':p.returncode,'seconds':round(time.monotonic()-start,3)})
    return p

def checked(args,cwd,stem):
    p=command(args,cwd,stem)
    if p.returncode:
        raise RuntimeError(f'{stem} failed; inspect {cwd}')
    return p.stdout

def build_oracles(work):
    ref=REPO/'research/kyber_ref'
    libs=[ref/(n+'.c') for n in ('poly','polyvec','ntt','reduce','cbd','indcpa','kem','verify','fips202','symmetric-shake')]
    libs.append(REPO/'research/mlkem_kat/randombytes_stub.c')
    for name,src in [('polmul','polmul_full_tool.c'),('ntt','ntt_once_tool.c')]:
        checked([tool('gcc'),'-O2','-Wall','-I'+str(ref),'-o',work/(name+'.exe'),HERE/src,*libs],work,'compile_'+name)

def mutation_stage(work):
    a=read_hex(HERE/'batch/fullmul_a.txt',4096)
    b=read_hex(HERE/'batch/fullmul_b.txt',4096)
    frozen=read_hex(HERE/'batch/fullmul_exp.txt',4096)
    if min(len(set(a)),len(set(b)))<1000 or any(a[g*256:(g+1)*256]==b[g*256:(g+1)*256] for g in range(16)):
        raise ValueError('degenerate vectors')
    expected=[]
    for g in range(16):
        write_hex(work/'a.txt',a[g*256:(g+1)*256]);write_hex(work/'b.txt',b[g*256:(g+1)*256])
        checked([work/'polmul.exe','a.txt','b.txt','gold.txt','--full'],work,f'oracle_full_{g}')
        expected.extend(read_hex(work/'gold.txt',256))
    if expected!=frozen: raise AssertionError('fresh C disagrees with frozen oracle')
    results=[]
    for item in [None,*MUTATIONS]:
        name='baseline' if item is None else item[0]
        case=work/name;case.mkdir()
        write_hex(case/'in_a.txt',a);write_hex(case/'in_b.txt',b)
        src=case/'core';shutil.copytree(CORE,src)
        info={'id':name,'build':4,'mode':'FULL','groups':16,'coefficients':4096}
        if item:
            _,file,old,new,why=item
            p=src/file;raw=p.read_bytes();anchor=old.encode('ascii')
            if raw.count(anchor)!=1: raise ValueError(f'{name}: anchor must occur exactly once')
            p.write_bytes(raw.replace(anchor,new.encode('ascii')))
            info.update(file=file,before=old,after=new,mechanism=why,
                        original_sha256=digest(CORE/file),mutant_sha256=digest(p))
        compiled=command([tool('iverilog'),'-g2012','-s','polmul_param_tb','-DCFG_PE_NUM=4',
              '-DCFG_HALF=0','-o',case/'dut.vvp',*sorted(src.glob('*.v')),HERE/'polmul_param_tb.v'],case,'compile')
        if compiled.returncode:
            info['status']='compile_error'
        else:
            sim=command([tool('vvp'),case/'dut.vvp'],case,'simulate')
            if sim.returncode:
                info['status']='simulation_error'
                info['detail']='nonzero simulation exit; not counted as detected arithmetic fault'
            else:
                try:
                    got=parse_output(sim.stdout,4,0)
                    multi,ordered=compare(got,expected)
                    info.update(multiset_matches=multi,ordered_matches=ordered)
                    info['status']='pass' if ordered==4096 and multi==4096 else 'detected_mismatch'
                    if info['status']=='detected_mismatch':
                        info['first_mismatch']=next({'group':g,'position':i,'actual':x,
                            'expected':expected[g*256+i//2+128*(i%2)]}
                            for g,row in enumerate(got) for i,x in enumerate(row)
                            if x!=expected[g*256+i//2+128*(i%2)])
                except ValueError as exc:
                    # Unknown data is a behavioral detection only after a complete run.
                    complete=sim.stdout.splitlines().count('COMPLETE 4 0 16')==1
                    rows=[s for s in sim.stdout.splitlines() if s.startswith('DOUT ')]
                    unknown=any(re.fullmatch(r'DOUT \d+ \d+ [0-9a-fA-FxXzZ]{3}',s) and re.search('[xXzZ]',s.split()[-1]) for s in rows)
                    info['status']='detected_unknown' if complete and len(rows)==4096 and unknown else 'invalid_output'
                    info['detail']=str(exc)
        results.append(info);save(case/'result.json',info);save(work/'mutations.json',results)
        print(f"MUTATION {name}: {info['status']}",flush=True)
        if item is None and info['status']!='pass': raise AssertionError('baseline must pass before mutants')
    survivors=[r for r in results[1:] if not r['status'].startswith('detected_')]
    if survivors: raise AssertionError('survivors/infrastructure failures: '+str([(r['id'],r['status']) for r in survivors]))
    return results

def timing_stage(work):
    rng=random.Random(20261018)
    samples=[[rng.randrange(3329) for _ in range(256)] for _ in range(100)]
    if len({tuple(s) for s in samples})!=100 or min(len(set(s)) for s in samples)<200:
        raise AssertionError('random sample diversity failure')
    samples += [[0]*256,[3328]*256,[0,3328]*128]
    expected=[]
    for g,s in enumerate(samples):
        write_hex(work/'ntt_in.txt',s)
        checked([work/'ntt.exe','ntt_in.txt','ntt_gold.txt','--ntt'],work,f'oracle_ntt_{g}')
        expected.append(read_hex(work/'ntt_gold.txt',256))
    write_hex(work/'timing_in.txt',[x for row in samples for x in row])
    save(work/'timing_inputs.json',{'seed':20261018,'random_count':100,'edge_cases':['zero','q_minus_one','alternating'],
         'input_sha256':digest(work/'timing_in.txt'),'expected':expected})
    results=[]
    for pe,cc in [(1,904),(4,232),(16,69)]:
        checked([tool('iverilog'),'-g2012','-s','strengthening_timing_tb',f'-DCFG_PE_NUM={pe}',
                 '-o',work/f'timing_pe{pe}.vvp',*sorted(CORE.glob('*.v')),HERE/'strengthening_timing_tb.v'],work,f'compile_timing_pe{pe}')
        out=checked([tool('vvp'),work/f'timing_pe{pe}.vvp'],work,f'timing_pe{pe}')
        if any(s in out for s in ('WARNING','ERROR','FATAL')): raise AssertionError('timing simulation warning/error')
        cycles={};values={};addresses={g:[] for g in range(103)}
        for line in out.splitlines():
            t=line.split()
            if not t:continue
            if t[0]=='CYCLES':
                if len(t)!=3 or int(t[1]) in cycles: raise ValueError('bad cycle row')
                cycles[int(t[1])]=int(t[2])
            elif t[0]=='VALUE':
                if len(t)!=4 or not re.fullmatch('[0-9a-fA-F]{3}',t[3]): raise ValueError('unknown/malformed value')
                key=(int(t[1]),int(t[2]))
                if key in values:raise ValueError('duplicate value')
                values[key]=int(t[3],16)
            elif t[0]=='ADDR':
                if len(t)!=10 or any(re.search('[xXzZ]',x) for x in t[3:]):raise ValueError('bad address trace')
                addresses[int(t[1])].append(' '.join(t[2:]))
        if out.splitlines().count(f'COMPLETE_TIMING {pe} 103')!=1 or set(cycles)!=set(range(103)) or len(values)!=103*256:
            raise ValueError('incomplete timing run')
        traces=[];effective_traces=[]
        for g in range(103):
            if cycles[g]!=cc+3: raise AssertionError(f'pe{pe} sample{g} latency {cycles[g]} != {cc+3}')
            for i in range(256):
                j=(i//4*4+[0,2,1,3][i%4]) if pe==1 else i
                if values[g,i]!=expected[g][j]: raise AssertionError(f'pe{pe} sample{g} output{i} mismatch')
            if len(addresses[g])!=cc+3: raise AssertionError('address trace missing cycles')
            traces.append(hashlib.sha256(('\n'.join(addresses[g])+'\n').encode('ascii')).hexdigest())
            effective=[]
            for line in addresses[g]:
                fields=line.split() # offset, r0, r1, w0, w1, tw, wen0, wen1
                if fields[6]=='0':fields[3]='disabled'
                if fields[7]=='0':fields[4]='disabled'
                effective.append(' '.join(fields))
            effective_traces.append(hashlib.sha256(('\n'.join(effective)+'\n').encode('ascii')).hexdigest())
        if len(set(effective_traces))!=1: raise AssertionError('effective address/write-enable sequences differ; investigate')
        row={'pe':pe,'random_inputs':100,'edge_inputs':3,'core_cycles':cc,'wrapper_overhead':3,
             'observed_top_cycles':[cycles[g] for g in range(103)],'correct_coefficients':103*256,
             'raw_address_trace_sha256':traces,'raw_address_trace_variants':len(set(traces)),
             'effective_address_trace_sha256':effective_traces[0],'identical_effective_address_traces':103,
             'normalization':'write address ignored only while its write enable is zero; read/twiddle addresses and both enables compared every cycle',
             'observed_signals':['raddr0','raddr1','waddr0','waddr1','raddr_tw','wen0','wen1']}
        results.append(row);save(work/'timing.json',results)
        print(f'TIMING pe{pe}: 103 inputs, core={cc}, top={cc+3}; C outputs and effective address traces PASS; raw trace variants={len(set(traces))}',flush=True)
    return results

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output',type=Path,required=True)
    args=ap.parse_args();work=args.output.resolve()
    if work.exists():raise FileExistsError('choose a NEW output directory: '+str(work))
    work.mkdir(parents=True)
    sources=[*sorted(CORE.glob('*.v')),*sorted((REPO/'research/kyber_ref').glob('*.[ch]')),
             HERE/'accept_strengthening.py',HERE/'strengthening_timing_tb.v',HERE/'polmul_param_tb.v',
             HERE/'check_polmul_param.py',HERE/'polmul_full_tool.c',HERE/'ntt_once_tool.c',
             REPO/'research/mlkem_kat/randombytes_stub.c',
             *[HERE/f'batch/fullmul_{n}.txt' for n in ['a','b','exp']]]
    hashes={str(p.relative_to(REPO)).replace('\\','/'):digest(p) for p in sources}
    summary={'status':'running','source_sha256':hashes,'scope':'RTL simulation only; no board, no full side-channel security proof'}
    save(work/'acceptance.json',summary)
    try:
        summary['git_head']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip()
        summary['git_status']=subprocess.check_output(['git','status','--short'],cwd=REPO,text=True).splitlines()
        summary['tool_versions']={}
        for name,flag in [('gcc','--version'),('iverilog','-V'),('vvp','-V')]:
            p=command([tool(name),flag],work,'version_'+name)
            if p.returncode:raise RuntimeError('cannot identify tool version: '+name)
            summary['tool_versions'][name]=(p.stdout+p.stderr).splitlines()[0]
        build_oracles(work)
        summary['mutations']=mutation_stage(work)
        summary['timing']=timing_stage(work)
        if any(digest(REPO/p)!=h for p,h in hashes.items()):raise AssertionError('source files changed during acceptance')
        summary['status']='pass'
    except Exception as exc:
        summary.update(status='fail',error=str(exc));raise
    finally:
        save(work/'acceptance.json',summary)
    print('PASS: baseline; 17/17 RTL mutants detected; 100 random + 3 edge inputs x 3 builds. Board NOT tested.',flush=True)

if __name__=='__main__':main()
