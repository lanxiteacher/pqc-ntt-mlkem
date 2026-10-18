"""Replay an extracted NTT transcript through the actual Host/unpack pipeline.

Default: synthetic known-answer loopback for all three builds, no arithmetic.
Real serial requires explicit --port AND --build; no automatic board access.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import tempfile

from kem_trace import validate_trace, hex_file, write_json

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host/src'))
import fake_board
import host
import link
import unpack


def replay(trace_path, output, port=None, build=None, baud=115200):
    if output.exists():
        raise FileExistsError('output must be a new directory')
    payload = json.loads(trace_path.read_text(encoding='utf-8'))
    if payload.get('algorithm') != 'ML-KEM-768' or payload.get('schema_version') != 1:
        raise ValueError('unsupported transcript')
    records = payload['records']
    validate_trace(records)
    if port is not None and build not in (1, 4, 16):
        raise ValueError('real serial requires explicit --build 1/4/16')
    if port is None and build is not None:
        raise ValueError('--build is for explicit serial replay; loopback checks all three')
    if type(baud) is not int or baud <= 0:
        raise ValueError('baud must be a positive integer')
    output.mkdir(parents=True)
    rows = []
    result = dict(schema_version=1, status='running',
                  source='serial' if port else 'synthetic_known_answer_replay',
                  serial_requested=bool(port), hardware_provenance_verified=False,
                  rtl_arithmetic_verified=False, frequency_verified=False,
                  trace_file=str(trace_path.resolve()),
                  trace_sha256=hashlib.sha256(trace_path.read_bytes()).hexdigest(),
                  transactions=0, coefficients=0, port=port,
                  baud=baud if port else None, results=rows, handshakes=[])
    write_json(output / 'replay.json', result)
    try:
        _run_replay(records, output, port, build, baud, rows, result)
        result['status']='pass'
    except BaseException as exc:
        result.update(status='fail',error_type=type(exc).__name__,error=str(exc))
        raise
    finally:
        result.update(transactions=len(rows),
                      coefficients=sum(len(r.get('unpacked_values',[])) for r in rows),
                      passed_transactions=sum(r['status']=='pass' for r in rows))
        write_json(output / 'replay.json', result)
    return result


def _run_replay(records, output, port, build, baud, rows, result):
    with tempfile.TemporaryDirectory(prefix='kem_replay_') as tmp:
        work = Path(tmp)
        hex_file(work / 'ntt_batch_in.txt', [v for r in records for v in r['input_signed']])
        hex_file(work / 'ntt_batch_exp.txt', [v for r in records for v in r['output_signed']])
        for pe in ((build,) if port else (1, 4, 16)):
            transport = (link.SerialLink(port=port, baud=baud) if port else
                         link.LoopbackLink(board=fake_board.FakeBoard(batch_dir=work, build=pe, physical_order=True)))
            try:
                hst = host.Host(transport)
                hst.handshake()
                result['handshakes'].append(dict(requested_build=pe,reported_build=hst.build))
                write_json(output/'replay.json',result)
                if hst.build is not None and hst.build != pe:
                    raise ValueError('RDY build conflicts with requested build')
                for record in records:
                    values = [v % 3329 for v in record['input_signed']]
                    expected = [v % 3329 for v in record['output_signed']]
                    command = '#NTT 1'
                    order = unpack.load_permutation(('#NTT',), 0, pe)
                    data = [f'{values[i]:03x}' for i in order]
                    result['current_call']=dict(id=record['id'],phase=record['phase'],build=pe)
                    write_json(output/'replay.json',result)
                    txn = hst.run(command, data, expect_rows=256)
                    row=dict(id=record['id'],phase=record['phase'],build=pe,
                             status='transaction_failed',outcome=txn.outcome,attempts=txn.attempts,
                             raw_rows=txn.rows,transaction_log=txn.log)
                    rows.append(row)
                    result.update(transactions=len(rows),coefficients=(len(rows)-1)*256)
                    write_json(output/'replay.json',result)
                    if txn.outcome != host.RESULT_OK:
                        raise ValueError(f'NTT {record["id"]} pe{pe}: {txn.summary()}')
                    row['status']='invalid_output'
                    got = unpack.unpack(unpack.FNTT, txn.rows, pe)
                    different, details = unpack.compare_values(got, expected)
                    row.update(status='pass' if different == 0 else 'mismatch',mismatched=different,
                               details=details,unpacked_values=got)
                    write_json(output/'replay.json',result)
                    if different:
                        raise ValueError(f'NTT {record["id"]} pe{pe}: {different} mismatched')
            finally:
                transport.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--port', help='explicit serial port; actually sends NTT data to hardware')
    parser.add_argument('--build', type=int, choices=(1, 4, 16))
    parser.add_argument('--baud', type=int, default=115200)
    args = parser.parse_args()
    try:
        result = replay(args.trace, args.output, args.port, args.build, args.baud)
    except (OSError, ValueError, KeyError) as exc:
        parser.exit(2, f'ERROR: {exc}\n')
    print(f'PASS: source={result["source"]}, transactions={result["transactions"]}, '
          f'coefficients={result["coefficients"]}; no frequency or hardware provenance proof')


if __name__ == '__main__':
    main()
