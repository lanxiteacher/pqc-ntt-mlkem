"""Canonicalize the three active host vectors without changing their values.

Default: audit only. Pass --apply to write three hex digits and LF endings.
The SHA-256 covers big-endian uint16 coefficient values, not their spelling.
This deliberately excludes historical dumps and the frozen mathematical data.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

FILES = ("halfmul_b.txt", "halfmul_exp.txt", "fullmul_exp.txt")
BATCH = Path(__file__).resolve().parent / "batch"


def audit(path):
    raw = path.read_bytes()
    rows = raw.decode("ascii").splitlines()
    if len(rows) != 4096 or any(not re.fullmatch(r"[0-9a-fA-F]{1,3}", s) for s in rows):
        raise ValueError(f"{path.name}: expected 4096 hexadecimal coefficients")
    values = [int(s, 16) for s in rows]
    if any(v >= 3329 for v in values):
        raise ValueError(f"{path.name}: coefficient outside [0, 3329)")
    digest = hashlib.sha256(b"".join(v.to_bytes(2, "big") for v in values)).hexdigest()
    canonical = ("\n".join(f"{v:03x}" for v in values) + "\n").encode("ascii")
    return values, digest, canonical, sum(len(s) != 3 for s in rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    # Validate every target before writing any of them.
    plans = [(BATCH / name, audit(BATCH / name)) for name in FILES]
    for path, (values, digest, canonical, changed_rows) in plans:
        if args.apply:
            path.write_bytes(canonical)
            after, after_digest, _, _ = audit(path)
            if after != values or after_digest != digest:
                raise RuntimeError(f"{path.name}: values changed")
        print(json.dumps(dict(file=path.name, rows=len(values),
                              padded_rows=changed_rows, values_sha256=digest,
                              applied=args.apply)))


if __name__ == "__main__":
    main()
