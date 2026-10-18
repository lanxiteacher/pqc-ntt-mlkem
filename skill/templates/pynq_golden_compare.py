"""PYNQ golden-reference adapter skeleton.

STATUS: SKELETON. Never executed on a PYNQ image or a Zynq board.
        Only syntax-checked (python -m py_compile). See skill/templates/README.md.

Purpose
-------
Turn whatever an arbitrary PYNQ Overlay computes into a one-dimensional
Python int list, save it as JSON, and let an independent golden-reference
comparator judge it. This file deliberately contains no comparison rules:
the one comparator is refsim/compare_integer_results.py (B, 2026-10-17).
Keeping one implementation avoids two definitions of "equal" drifting apart.

Boundaries -- do not remove these lines from a derived copy
-----------------------------------------------------------
* Skeleton only. collect_actual() is a TODO; no PYNQ API call here has
  been tested. Do not report this file as a working PYNQ result.
* No modular reduction, rescaling, sorting, padding or reordering. If the
  IP needs any of those, put them in a separate adapter layer and validate
  that layer independently. Hiding them here would make a wrong result
  look correct.
* Never copy expected values into actual. actual must come from hardware;
  synthetic values must be labelled synthetic.
* This is a correctness adapter, not a benchmark. Wall-clock time measured
  around these calls is not an IP performance number.

Minimal use on a machine that actually has PYNQ
-----------------------------------------------
    python pynq_golden_compare.py --bitfile design.bit --out actual.json
    python compare_integer_results.py expected.json actual.json --report report.json

Contract for collect_actual()
-----------------------------
Return list[int] with exactly the IP's output length, in the IP's output
order, already converted to Python int (NumPy int64 is not int and is
rejected by the comparator on purpose).

Before claiming a PYNQ result, verify each line:
  1. bit/hwh pair matches the board and the source commit;
  2. register map / DMA widths and signedness match the IP contract;
  3. every read has a finite timeout (no unbounded wait);
  4. DMA/cache handling follows the vendor example for this image;
  5. raw hardware output is preserved and exported, not retyped;
  6. expected values were computed independently of the hardware;
  7. one correct case and one deliberately wrong case were both run;
  8. resources are released deterministically after the run.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def load_overlay(bitfile: str):
    """Import pynq lazily so this file stays importable without PYNQ."""
    try:
        from pynq import Overlay
    except ImportError as exc:  # pragma: no cover - depends on host image
        raise SystemExit(
            "ERROR: pynq is not installed on this machine; this adapter is a "
            "skeleton until it is filled in and run on a PYNQ image"
        ) from exc
    return Overlay(str(bitfile))


def collect_actual(overlay, output_length: int) -> list[int]:
    """TODO: replace the body with the real IP interaction.

    Typical shape (pick what the IP actually exposes, do not mix them):

        ip = overlay.<ip_name>
        for index, value in enumerate(inputs):
            ip.write(0x10 + 4 * index, int(value) & 0xFFFFFFFF)
        ip.write(0x00, 1)                    # start
        wait_until(lambda: ip.read(0x04) & 1, timeout_s=1.0)
        return [int(ip.read(0x100 + 4 * i) & 0xFFFF) for i in range(output_length)]

    Keep every wait bounded. Do not loop on a status bit forever.
    """
    raise NotImplementedError(
        "collect_actual() is empty by design: fill it for the target IP and "
        "record which PYNQ image and bit/hwh pair it was run with"
    )


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bitfile", required=True, help="Overlay bitstream")
    parser.add_argument("--out", type=Path, required=True, help="actual JSON path")
    parser.add_argument("--length", type=int, default=None,
                        help="expected output length; default: no length check")
    args = parser.parse_args(argv)

    overlay = load_overlay(args.bitfile)
    actual = collect_actual(overlay, args.length)
    if not isinstance(actual, list) or any(type(value) is not int for value in actual):
        print("ERROR: collect_actual() must return a list[int] of Python ints",
              file=sys.stderr)
        return 2
    if args.length is not None and len(actual) != args.length:
        print(f"ERROR: expected {args.length} values, hardware returned {len(actual)}",
              file=sys.stderr)
        return 2

    args.out.write_bytes((json.dumps(actual, ensure_ascii=False) + "\n").encode("utf-8"))
    print(f"OK  wrote {len(actual)} hardware values to {args.out}")
    print("NEXT: python compare_integer_results.py expected.json actual.json --report report.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
