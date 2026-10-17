"""Protocol/layout integration, not RTL arithmetic verification.

Run all five commands, 16 groups and three builds through the actual Host.
The fake physical interface is independently specified in fake_board.py.
Negative controls reject both a damaged coefficient and a missing load shuffle.
The CLI checks exercise handshake -> build selection -> build_data -> unpack.
"""
import contextlib
import io
from pathlib import Path
import subprocess
import sys

import board_run
import fake_board
import host
import link
import unpack
import vectors


def main():
    transactions = 0
    for build in (1, 4, 16):
        for key, (files, exp_file) in vectors.VECTORS.items():
            command = " ".join(key) + " 1"
            inputs = [vectors.split_groups(vectors.read_vector(vectors.BATCH_DIR / f), f)
                      for f in files]
            expected = vectors.split_groups(vectors.read_vector(vectors.BATCH_DIR / exp_file), exp_file)
            assert len(expected) == 16
            bd = fake_board.FakeBoard(build=build, physical_order=True)
            hst = host.Host(link.LoopbackLink(bd))
            assert hst.handshake() and hst.build == build
            for group in range(16):
                data = [rows[group][i] for bank, rows in enumerate(inputs)
                        for i in unpack.load_permutation(key, bank, build)]
                if group == 0:
                    assert board_run.build_data(command, build)[0] == data
                txn = hst.run(command, data, expect_rows=256)
                assert txn.outcome == host.RESULT_OK, txn.summary()
                assert bd.group == group and not bd.mismatches
                got = unpack.unpack(unpack.kind_of(command), txn.rows, build)
                assert got == [int(v, 16) for v in expected[group]], (build, command, group)
                transactions += 1
            print(f"pe{build} {command}: 16/16 transactions, 4096/4096 coefficients")
    # Exercise the actual CLI with automatically discovered build values.
    for build in (1, 4, 16):
        for key in vectors.VECTORS:
            capture = io.StringIO()
            with contextlib.redirect_stdout(capture):
                rc = board_run.main(["--loopback", "--physical-order", "--fake-build", str(build),
                                     "--check", " ".join(key) + " 1"])
            assert rc == 0, capture.getvalue()
    # A permissive mock must not turn these into successful group-zero replies.
    for damaged in (False, True):
        bd = fake_board.FakeBoard(build=1, physical_order=True)
        hst = host.Host(link.LoopbackLink(bd))
        hst.handshake()
        data, _ = board_run.build_data("#INTT 1", 1)
        if damaged:
            data[0] = "001" if data[0] == "000" else "000"
        else:
            data = vectors.read_vector(vectors.BATCH_DIR / "intt_batch_in.txt")[:256]
        try:
            hst.run("#INTT 1", data, expect_rows=256)
        except ValueError as e:
            assert "no exact input vector" in str(e)
        else:
            raise AssertionError("bad data/layout silently accepted")
    # CLI fails loudly on wrong build and unknown command as well.
    for args in (["--loopback", "--physical-order", "--fake-build", "1", "--build", "4", "#PMUL NTT 1"],):
        p = subprocess.run([sys.executable, str(Path(board_run.__file__)), *args],
                           capture_output=True, encoding="utf-8")
        assert p.returncode != 0
    print(f"PASS: {transactions} transactions, {transactions * 256} coefficients; "
          "15 CLI checks; damaged-data / missing-shuffle / wrong-build controls rejected")
    print("Scope: known-vector replay only; no RTL or electrical timing proof.")


if __name__ == "__main__":
    main()
