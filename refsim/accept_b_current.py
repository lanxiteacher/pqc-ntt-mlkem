"""Unified B acceptance: Phase 2, signed input controls, host, delivery compatibility.

No physical serial port is opened. Requires Python, gcc, iverilog/vvp, pyserial.
Optional --reuse-phase2 imports a complete source-matching run without rerunning it.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from accept_strengthening import save

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--reuse-phase2', type=Path)
    args = ap.parse_args()
    out = args.output.resolve()
    if out.exists():
        raise FileExistsError('choose a NEW output directory')
    out.mkdir(parents=True)
    inputs = sorted(set((ROOT/'host/src').glob('*.py')) |
                    set((ROOT/'refsim').glob('*.py')) |
                    set((ROOT/'refsim').glob('*.c')))
    sources = {p.relative_to(ROOT).as_posix(): sha(p) for p in inputs}
    result = dict(status='running', board_access=False, source_sha256=sources,
                  phase2_reused=bool(args.reuse_phase2), tests=[])
    save(out/'acceptance.json', result)

    def run(name, argv, timeout=180):
        with (out/(name+'.txt')).open('wb') as log:
            proc = subprocess.run([str(x) for x in argv], cwd=ROOT,
                                  stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        if proc.returncode:
            raise RuntimeError(f'{name} failed; inspect {out / (name + ".txt")}')
        result['tests'].append(dict(name=name, status='pass'))
        save(out/'acceptance.json', result)
        print(f'PASS: {name}', flush=True)

    try:
        import serial  # Require loop:// coverage instead of silently skipping it.
        result['pyserial_version'] = serial.__version__
        phase2 = args.reuse_phase2.resolve() if args.reuse_phase2 else out/'phase2'
        if not args.reuse_phase2:
            print('Running Phase 2; detailed progress is written to phase2_run.txt.', flush=True)
            run('phase2_run', [sys.executable, ROOT/'refsim/accept_phase2.py',
                              '--output', phase2], timeout=7200)
        phase = json.loads((phase2/'acceptance.json').read_text(encoding='utf-8'))
        assert phase['status'] == 'complete'
        assert set(phase['stages']) == {'board_audit', 'ntt100', 'traces', 'mutations'}
        assert all(sha(ROOT/p) == h for p, h in phase['source_sha256'].items())
        result['phase2'] = phase
        save(out/'phase2_acceptance.json', phase)
        print('PASS: complete Phase 2 evidence and source hashes', flush=True)
        # Malformed inputs must be rejected before running the signed C oracle.
        signed = phase2/'ntt100/signed.exe'
        cases = {'valid': (['0']*256, 0), 'short': (['0']*255, 3),
                 'extra': (['0']*257, 3), 'positive_outside': (['3330']+['0']*255, 3),
                 'negative_outside': (['-3330']+['0']*255, 3),
                 'junk': (['1z']+['0']*255, 3), 'float': (['1.5']+['0']*255, 3),
                 'overflow': (['9'*50]+['0']*255, 3)}
        controls = []
        for name, (rows, code) in cases.items():
            file = out/(name+'.in.txt')
            file.write_bytes(('\n'.join(rows)+'\n').encode('ascii'))
            p = subprocess.run([str(signed), str(file), str(out/(name+'.out.txt'))],
                               capture_output=True, timeout=10)
            assert p.returncode == code, name
            controls.append(dict(name=name, status='pass', exit_code=code))
        result['signed_controls'] = controls
        # Refusal to overwrite an existing evidence directory.
        p = subprocess.run([sys.executable, str(ROOT/'refsim/accept_phase2.py'),
                            '--output', str(phase2)], capture_output=True, timeout=10)
        assert p.returncode != 0 and b'NEW output directory' in p.stderr
        result['existing_output_rejected'] = True
        for file in sorted((ROOT/'host/src').glob('test_*.py')):
            run(file.stem, [sys.executable, file])
        run('delivery_compatibility', [sys.executable, ROOT/'refsim/accept_trace_delivery.py',
                                      '--output', out/'delivery'], timeout=1200)
        assert all(sha(ROOT/p) == h for p, h in sources.items()), 'source changed during run'
        result['status'] = 'pass'
    except BaseException as exc:
        result.update(status='fail', error=str(exc))
        raise
    finally:
        save(out/'acceptance.json', result)
    mutation = result['phase2']['stages']['mutations']
    print(f"PASS: B local acceptance; mutation detections={mutation['detected']}/51, "
          f"survivors={len(mutation['survivors'])}; inspect survivor classifications. No board accessed.")


if __name__ == '__main__':
    main()
