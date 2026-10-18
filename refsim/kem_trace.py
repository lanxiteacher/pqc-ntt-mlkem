"""Extract and verify one public ML-KEM-768 KAT transcript; no board access.

Uses a temporary instrumented poly.c copy; research originals are never edited.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

from check_polmul_param import tool

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
REF = ROOT / 'research/kyber_ref'
SOURCES = ('poly', 'polyvec', 'ntt', 'reduce', 'cbd', 'indcpa', 'kem', 'verify', 'fips202', 'symmetric-shake')


def invoke(args, cwd):
    p = subprocess.run([str(a) for a in args], cwd=cwd, capture_output=True, timeout=120)
    if p.returncode:
        raise RuntimeError(f'command failed {p.returncode}: {args}\n{p.stderr.decode("utf-8", errors="replace")}')
    return p.stdout


def write_json(path, value):
    path.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))


def read_first_kat():
    record = {}
    path = ROOT / 'research/mlkem_kat/kat_MLKEM_768.rsp'
    for line in path.read_text(encoding='ascii').splitlines():
        if '=' not in line:
            continue
        key, value = (s.strip() for s in line.split('=', 1))
        if key == 'count' and 'count' in record:
            break
        record[key] = value
    sizes = dict(d=32, z=32, msg=32, pk=1184, sk=2400, ct=1088, ss=32)
    for key, size in sizes.items():
        if not re.fullmatch('[0-9a-fA-F]{' + str(size * 2) + '}', record.get(key, '')):
            raise ValueError('invalid KAT field ' + key)
    return record, path


def validate_trace(records):
    if not isinstance(records, list) or not records:
        raise ValueError('empty/invalid trace')
    phases = []
    for index, row in enumerate(records):
        if not isinstance(row, dict):
            raise ValueError('invalid trace record')
        if row.get('id') != index or type(row.get('id')) is not int:
            raise ValueError('missing/duplicate/out-of-order trace id')
        if row.get('phase') not in ('keygen', 'encaps', 'decaps'):
            raise ValueError('invalid phase')
        phases.append(row['phase'])
        for key in ('input_signed', 'output_signed'):
            values = row.get(key)
            if not isinstance(values, list) or len(values) != 256:
                raise ValueError('missing coefficient')
            if any(type(v) is not int or not -32768 <= v <= 32767 for v in values):
                raise ValueError('non-int or out-of-range coefficient')
    counts = dict(Counter(phases))
    # KYBER_K=3: keygen sk/e vectors; encaps sp; decaps b then re-encrypt sp.
    if counts != {'keygen': 6, 'encaps': 3, 'decaps': 6}:
        raise ValueError('incomplete phase coverage: ' + str(counts))
    if phases != ['keygen'] * 6 + ['encaps'] * 3 + ['decaps'] * 6:
        raise ValueError('phase order changed')
    return counts


def hex_file(path, values):
    path.write_bytes((''.join(f'{v % 3329:03x}\n' for v in values)).encode('ascii'))


def verify_oracle(records, exe, work):
    validate_trace(records)
    for row in records:
        hex_file(work / 'in.txt', row['input_signed'])
        invoke([exe, work / 'in.txt', work / 'out.txt', '--ntt'], work)
        actual = [int(s, 16) for s in (work / 'out.txt').read_text().splitlines()]
        if actual != [v % 3329 for v in row['output_signed']]:
            raise ValueError(f'NTT oracle mismatch id={row["id"]}')


def extract(output):
    if output.exists():
        raise FileExistsError('output must be a new directory')
    gcc = tool('gcc')
    kat, kat_path = read_first_kat()
    original = {p.name: p.read_bytes() for p in REF.glob('*') if p.is_file()}
    source = (REF / 'poly.c').read_text(encoding='utf-8')
    target = 'void poly_ntt(poly *r)\n{\n  ntt(r->coeffs);\n  poly_reduce(r);\n}'
    if source.count(target) != 1:
        raise ValueError('poly_ntt body changed; review instrumentation before proceeding')
    replacement = ('extern void trace_before(const poly *);\nextern void trace_after(const poly *);\n'
                   'void poly_ntt(poly *r)\n{\n  trace_before(r);\n  ntt(r->coeffs);\n'
                   '  poly_reduce(r);\n  trace_after(r);\n}')
    with tempfile.TemporaryDirectory(prefix='kem_trace_') as tmp:
        work = Path(tmp)
        (work / 'poly_trace.c').write_bytes(source.replace(target, replacement).encode('utf-8'))
        (work / 'fixture.bin').write_bytes(b''.join(bytes.fromhex(kat[k]) for k in ('d', 'z', 'msg', 'pk', 'sk', 'ct', 'ss')))
        common = [gcc, '-std=c99', '-O2', '-Wall', '-Wextra', '-DKYBER_K=3', '-I' + str(REF)]
        libs = [REF / (n + '.c') for n in SOURCES if n != 'poly']
        stub = ROOT / 'research/mlkem_kat/randombytes_stub.c'
        for mode, poly in [('baseline', REF / 'poly.c'), ('traced', work / 'poly_trace.c')]:
            invoke([*common, HERE / 'kem_trace_driver.c', poly, *libs, stub, '-o', work / (mode + '.exe')], work)
            invoke([work / (mode + '.exe'), work / 'fixture.bin', work / (mode + '.jsonl'), work / (mode + '.bin')], work)
        if (work / 'baseline.bin').read_bytes() != (work / 'traced.bin').read_bytes():
            raise ValueError('instrumentation changed KEM output')
        if (work / 'baseline.jsonl').read_bytes():
            raise ValueError('baseline unexpectedly traced')
        records = [json.loads(s) for s in (work / 'traced.jsonl').read_text().splitlines()]
        counts = validate_trace(records)
        invoke([work / 'traced.exe', work / 'fixture.bin', work / 'repeat.jsonl', work / 'repeat.bin'], work)
        if ((work / 'repeat.jsonl').read_bytes() != (work / 'traced.jsonl').read_bytes() or
                (work / 'repeat.bin').read_bytes() != (work / 'traced.bin').read_bytes()):
            raise ValueError('nondeterministic extraction')
        oracle = work / 'oracle.exe'
        invoke([*common, HERE / 'ntt_once_tool.c', REF / 'poly.c', *libs, stub, '-o', oracle], work)
        verify_oracle(records, oracle, work)
        # Negative controls must actually be rejected, including arithmetic corruption.
        rejected = []
        for name, bad in [('missing_call', records[:-1]),
                          ('duplicate_id', [dict(r, id=0) for r in records])]:
            try:
                validate_trace(bad)
            except ValueError:
                rejected.append(name)
            else:
                raise AssertionError('negative control passed: ' + name)
        corrupt = json.loads(json.dumps(records))
        corrupt[0]['output_signed'][0] += 1
        try:
            verify_oracle(corrupt, oracle, work)
        except ValueError:
            rejected.append('corrupt_coefficient')
        else:
            raise AssertionError('arithmetic negative control passed')
        if any((REF / name).read_bytes() != content for name, content in original.items()):
            raise ValueError('reference source changed')
        output.mkdir(parents=True)
        manifest = []
        for row in records:
            folder = output / f'ntt_{row["id"]:03d}_{row["phase"]}'
            folder.mkdir()
            hex_file(folder / 'input.hex', row['input_signed'])
            hex_file(folder / 'expected.hex', row['output_signed'])
            manifest.append(dict(id=row['id'], phase=row['phase'], command='#NTT 1',
                                 input=str((folder / 'input.hex').relative_to(output)).replace('\\', '/'),
                                 expected=str((folder / 'expected.hex').relative_to(output)).replace('\\', '/')))
        source_hashes = {name: hashlib.sha256(content).hexdigest() for name, content in original.items()}
        write_json(output / 'trace.json', dict(schema_version=1, algorithm='ML-KEM-768', kat_count=int(kat['count']),
                   scope='poly_ntt forward calls only; excludes invntt and complete hardware KEM',
                   canonicalization='signed coefficient modulo 3329; natural input; C poly_ntt output order',
                   records=records))
        write_json(output / 'manifest.json', dict(schema_version=1, hardware_validated=False, entries=manifest))
        summary = dict(status='pass', source='public community FIPS203-compatible KAT, not NIST official',
                       kat_count=int(kat['count']), kat_sha256=hashlib.sha256(kat_path.read_bytes()).hexdigest(),
                       phase_counts=counts, total_ntt_calls=len(records), total_coefficients=len(records)*256,
                       kem_kat_matched=True, instrumentation_unchanged=True, deterministic=True,
                       standalone_c_oracle_matched=True, reference_files_unchanged=True,
                       negative_controls_rejected=rejected, hardware_validated=False,
                       compiler=invoke([gcc, '--version'], work).decode(errors='replace').splitlines()[0],
                       reference_sha256=source_hashes)
        write_json(output / 'summary.json', summary)
        (output / 'summary.md').write_bytes((f'# ML-KEM-768 NTT transcript (software only)\n\n'
            f'KAT record {kat["count"]}; keygen={counts["keygen"]}, encaps={counts["encaps"]}, '
            f'decaps={counts["decaps"]}; {len(records)} calls / {len(records)*256} coefficients.\n\n'
            'PASS: public compatible KAT; baseline/traced identical; deterministic extraction; '
            'all forward NTT calls agree with separately built original C oracle; three negative controls rejected.\n\n'
            'No board or RTL replay has been performed. This does not implement complete ML-KEM on FPGA.\n').encode('utf-8'))
        return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = extract(args.output.resolve())
    except (OSError, ValueError, RuntimeError, AssertionError, subprocess.TimeoutExpired) as exc:
        parser.exit(2, f'ERROR: {exc}\n')
    print('PASS:', result['phase_counts'], 'calls=', result['total_ntt_calls'],
          'coefficients=', result['total_coefficients'], 'hardware_validated=False')


if __name__ == '__main__':
    main()
