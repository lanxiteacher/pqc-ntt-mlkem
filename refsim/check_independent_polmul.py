"""Independent O(N^2) negacyclic convolution versus actual FULL RTL, all PEs.

Uses no C/NTT/basemul oracle. FULL output is canonical time-domain, with tau
read permutation; NTT and inverse Montgomery factors cancel in FULL.
"""
import argparse
import hashlib
import json
from pathlib import Path
import random
import tempfile

from check_polmul_param import REPO, HERE, tool, run, read_hex, write_hex, parse_output, compare


def convolution(a, b):
    result = [0] * 256
    for i, x in enumerate(a):
        for j, y in enumerate(b):
            degree = i + j
            result[degree % 256] += x * y * (1 if degree < 256 else -1)
    return [x % 3329 for x in result]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    rng = random.Random(20261029)
    zero = [0]*256
    unit = [1]+[0]*255
    last = [0]*255+[1]
    x = [0, 1]+[0]*254
    random_poly = lambda: [rng.randrange(3329) for _ in range(256)]
    a0, b0 = random_poly(), random_poly()
    pairs = [(zero, a0), (unit, a0), (last, x), (last, last),
             ([3328]*256, unit), (a0, b0), (b0, a0),
             ([(u+v)%3329 for u,v in zip(a0,b0)], x)]
    pairs += [(random_poly(), random_poly()) for _ in range(8)]
    gold = [convolution(a,b) for a,b in pairs]
    assert gold[0] == zero and gold[1] == a0
    assert gold[2] == [3328]+[0]*255
    assert gold[3] == [0]*254+[3328,0]
    assert gold[5] == gold[6]
    assert gold[7] == [(u+v)%3329 for u,v in zip(convolution(a0,x),convolution(b0,x))]
    a = [v for pair in pairs for v in pair[0]]
    b = [v for pair in pairs for v in pair[1]]
    expected = [v for row in gold for v in row]
    result = dict(status='running', board_access=False, seed=20261029,
                  oracle='integer schoolbook negacyclic convolution modulo x^256+1 and 3329',
                  groups=16, runs=[], source_sha256={})
    sources = [Path(__file__), HERE/'polmul_param_tb.v', *sorted((REPO/'rtl/ntt_core').glob('*.v'))]
    result['source_sha256'] = {p.relative_to(REPO).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    try:
        with tempfile.TemporaryDirectory(prefix='pqc_independent_') as tmp:
            work = Path(tmp)
            write_hex(work/'in_a.txt', a)
            write_hex(work/'in_b.txt', b)
            for pe in (1,4,16):
                exe = work/'dut.vvp'
                run([tool('iverilog'), '-g2012', '-s', 'polmul_param_tb', f'-DCFG_PE_NUM={pe}',
                     '-DCFG_HALF=0', '-o', exe, *sorted((REPO/'rtl/ntt_core').glob('*.v')),
                     HERE/'polmul_param_tb.v'], work)
                stdout = run([tool('vvp'), exe], work)
                (out/f'pe{pe}.txt').write_bytes(stdout.encode('utf-8'))
                got = parse_output(stdout, pe, 0)
                assert compare(got, expected) == (4096,4096), f'pe{pe} mismatch'
                bad = expected.copy()
                bad[0] = (bad[0]+1)%3329
                assert compare(got,bad) == (4095,4095)
                wrong_sign = expected.copy()
                wrong_sign[2*256] = 1
                assert compare(got,wrong_sign)[1] < 4096
                rotated = [row[1:]+row[:1] for row in got]
                assert compare(rotated,expected)[1] < 4096
                result['runs'].append(dict(pe=pe, matched=4096, negative_controls=3))
                print(f'PASS independent FULL pe{pe}: 4096 coefficients; sign/value/order controls rejected', flush=True)
        result.update(status='pass', total_coefficients=12288)
    finally:
        (out/'acceptance.json').write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'))


if __name__ == '__main__':
    main()
