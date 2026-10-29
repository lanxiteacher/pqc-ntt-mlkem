"""B release-candidate acceptance, never substitutes for board or human acceptance.

Run from any directory. New output must be outside the repository. Requires
Python/pyserial/git/sh/gcc/iverilog/vvp and remote read access. No Vivado needed.
Does not tag a team freeze, publish repositories or update the GitHub mirror.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    out = args.output.resolve()
    if out == ROOT or ROOT in out.parents:
        raise ValueError('output must be outside the repository')
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, PYTHONIOENCODING='utf-8')
    commit = subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    assert not subprocess.check_output(['git','diff','HEAD','--name-only'],cwd=ROOT).strip(), 'commit changes first'
    result = dict(status='running', commit=commit, board_access=False,
                  executor='AI automatic execution; not B personal manual acceptance',
                  date=datetime.datetime.now(datetime.timezone.utc).isoformat(), steps=[])
    tasks = [
        ('b_current',['refsim/accept_b_current.py','--output',out/'b_current'],10800),
        ('independent_math',['refsim/check_independent_polmul.py','--output',out/'math'],600),
        ('board_service',['refsim/measure_board_service.py','--output',out/'service'],600),
        ('clean_clone',['refsim/check_clean_clone.py','--output',out/'clean_clone.json'],3600),
        ('source_package',['refsim/build_source_candidate.py','--ref',commit,'--output',out/'package'],300),
    ]
    try:
        for name,argv,timeout in tasks:
            print('RUN '+name,flush=True)
            with (out/(name+'.txt')).open('wb') as log:
                proc = subprocess.run([sys.executable,*map(str,argv)],cwd=ROOT,env=env,
                                      stdout=log,stderr=subprocess.STDOUT,timeout=timeout)
            result['steps'].append(dict(name=name,exit_code=proc.returncode))
            if proc.returncode:
                raise RuntimeError(name+' failed; inspect '+str(out/(name+'.txt')))
            if name=='clean_clone':
                cloned = json.loads((out/'clean_clone.json').read_text(encoding='utf-8'))
                assert cloned['commit']==commit, 'remote changed; candidate and clone do not match'
            print('PASS '+name,flush=True)
        # Exercise the extracted package, rather than only the source workspace.
        extracted = out/'package/extracted'
        with (out/'extracted_cli.txt').open('wb') as log:
            p = subprocess.run([sys.executable,'host/src/test_board_run_failures.py'],cwd=extracted,
                               env=env,stdout=log,stderr=subprocess.STDOUT,timeout=120)
        assert p.returncode==0, 'extracted CLI checks failed'
        result['steps'].append(dict(name='extracted_cli',exit_code=p.returncode))
        assert not subprocess.check_output(['git','diff','HEAD','--name-only'],cwd=ROOT).strip()
        result.update(status='pass', pending_external=['new hardware replay and formal host regression',
                      'A constraint coverage note','second physical PC H10','team final freeze and artifacts',
                      'B personal manual acceptance','final mirror/publication'])
    except BaseException as exc:
        result.update(status='fail',error=str(exc))
        raise
    finally:
        result['output_sha256'] = {p.relative_to(out).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in out.glob('*.txt')}
        (out/'acceptance.json').write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'))
    print('PASS: B source candidate; external deliverables remain explicitly pending.',flush=True)


if __name__ == '__main__':
    main()
