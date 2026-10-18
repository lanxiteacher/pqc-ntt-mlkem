"""One offline acceptance entry: extract, validate, replay, reject corruption.

Requires Python and gcc. Never opens a real serial port, runs RTL or calls PYNQ.
Output directory must be new. Exit 0 pass; 2 failure (no success summary).
"""
import argparse
import copy
import hashlib
from pathlib import Path

from kem_trace import extract, validate_trace, write_json
from kem_trace_replay import replay


def accept(output):
    summary = extract(output)
    print('1/4 PASS: baseline and traced KEM outputs match compatible KAT')
    print('2/4 PASS: 15 NTT calls rechecked with original C; extraction deterministic')
    result = replay(output / 'trace.json', output / 'offline_replay')
    if result['transactions'] != 45 or result['coefficients'] != 11520:
        raise AssertionError('incomplete offline replay')
    print('3/4 PASS: all 15 calls replayed through Host for pe1/4/16 (synthetic)')
    import json
    payload = json.loads((output / 'trace.json').read_text(encoding='utf-8'))
    records = payload['records']
    rejected = []
    for name, edit in [('missing_value', lambda r: r[0]['input_signed'].pop()),
                       ('boolean_value', lambda r: r[0]['input_signed'].__setitem__(0, True)),
                       ('wrong_phase', lambda r: r[0].__setitem__('phase', 'encaps'))]:
        bad = copy.deepcopy(records)
        edit(bad)
        try:
            validate_trace(bad)
        except ValueError:
            rejected.append(name)
        else:
            raise AssertionError('invalid transcript accepted: ' + name)
    try:
        extract(output)
    except FileExistsError:
        rejected.append('overwrite_existing_output')
    else:
        raise AssertionError('existing evidence overwritten')
    # Remove one required field: no partial trace may be silently replayed.
    bad = copy.deepcopy(payload)
    bad['records'] = bad['records'][:-1]
    write_json(output / 'negative_incomplete_trace.json', bad)
    try:
        replay(output / 'negative_incomplete_trace.json', output / 'invalid_replay')
    except ValueError:
        rejected.append('replay_incomplete_trace')
    else:
        raise AssertionError('incomplete replay accepted')
    print('4/4 PASS: malformed records and incomplete replay rejected; output protected')
    final = dict(status='pass', extraction=summary,
                 offline_replay=dict(transactions=45, coefficients=11520,
                                     source=result['source'], hardware_validated=False),
                 additional_negative_controls=rejected,
                 trace_sha256=hashlib.sha256((output / 'trace.json').read_bytes()).hexdigest(),
                 manual_acceptance='pending user execution',
                 hardware_replay='not executed', rtl_replay='not executed')
    write_json(output / 'acceptance.json', final)
    print('PASS: software trace acceptance complete; board replay NOT performed')
    return final


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        accept(args.output.resolve())
    except Exception as exc:
        parser.exit(2, f'ERROR: {exc}\n')


if __name__ == '__main__':
    main()
