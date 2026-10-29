"""Export one committed source revision, hash and extract-check every member.

This creates a SOURCE candidate, not the final competition submission. It does
not include ignored bitstreams, PDF, video or signatures and never publishes.
Only git-tracked bytes at the requested revision enter the archive.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--ref', default='HEAD')
    args = ap.parse_args()
    out = args.output.resolve()
    if out == ROOT or ROOT in out.parents:
        raise ValueError('output must be outside the repository')
    out.mkdir(parents=True, exist_ok=False)
    commit = subprocess.check_output(['git','rev-parse',args.ref+'^{commit}'],cwd=ROOT,text=True).strip()
    data = subprocess.check_output(['git','archive','--format=zip',commit],cwd=ROOT)
    archive = out/'source.zip'
    archive.write_bytes(data)
    files = []
    extracted = out/'extracted'
    extracted.mkdir()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        assert z.testzip() is None
        names = set()
        for info in z.infolist():
            name = info.filename
            p = PurePosixPath(name)
            if p.is_absolute() or '..' in p.parts or '\\' in name or name in names:
                raise ValueError('unsafe/duplicate archive name: '+name)
            names.add(name)
            if info.is_dir():
                continue
            payload = z.read(name)
            target = extracted.joinpath(*p.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            assert hashlib.sha256(target.read_bytes()).hexdigest() == digest
            files.append(dict(path=name,size=len(payload),sha256=digest))
    for required in ('README.md','host/src/board_run.py','refsim/accept_b_current.py',
                     'refsim/check_independent_polmul.py','refsim/measure_board_service.py'):
        assert (extracted/required).is_file(), required
    result = dict(status='pass', scope='committed source candidate; not final submission',
                  commit=commit, archive_sha256=hashlib.sha256(data).hexdigest(),
                  extracted_bytes_verified=True, files=files,
                  missing_external_deliverables=['bitstreams and identity manifest',
                      'final report PDF','final video','signed forms','hardware revalidation'],
                  public_mirror_verified=False)
    (out/'manifest.json').write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'))
    print(f'PASS: source {commit}; {len(files)} extracted files hash-verified')
    print('Missing final deliverables remain explicit in manifest.json; no publication performed.')


if __name__ == '__main__':
    main()
