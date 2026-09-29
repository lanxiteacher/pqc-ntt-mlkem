#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Two jobs, both about rtl/ntt_core/BROM.v:

1. EVIDENCE -- show that the three twiddle tables are genuinely different and
   not packings/slices of one another.  This is what ruled out a parametric
   table and forced the `generate` approach (design doc section 3.3c).

2. VERIFY -- prove the generated file's three branches are line-for-line
   identical to the upstream tables (modulo the 4-space indent this tree adds).

Exit code 0 only if every branch matches.

Usage (from anywhere):
    python3 rtl/ntt_core/tools/check_brom.py
"""

import os
import re
import sys

PE_TO_DIR = {1: "pe1", 4: "pe4", 16: "pe16"}

CASE_ENTRY = re.compile(r"(\d+)'d(\d+)\s*:\s*dout\s*<=\s*(.+?);")
WORD_12 = re.compile(r"12'h([0-9a-fA-F]+)")


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read().split("\n")


def case_block(lines):
    start = end = None
    for i, line in enumerate(lines):
        if start is None and line.strip().startswith("case(raddr)"):
            start = i
        if start is not None and line.strip() == "endcase":
            end = i
            break
    if start is None or end is None:
        raise SystemExit("no case/endcase block found")
    return lines[start:end + 1]


def parse_table(path):
    """index -> list of 12-bit words on that line (1 for pe1, 4 for pe4, 16 for pe16)."""
    text = open(path, encoding="utf-8", errors="replace").read()
    return {int(m.group(2)): [int(w, 16) for w in WORD_12.findall(m.group(3))]
            for m in CASE_ENTRY.finditer(text)}


def summarize_ranges(keys):
    """[1,2,3,7,8] -> '1-3, 7-8' (compact, so a long index list stays readable)."""
    out, start, prev = [], keys[0], keys[0]
    for k in keys[1:]:
        if k == prev + 1:
            prev = k
            continue
        out.append(str(start) if start == prev else f"{start}-{prev}")
        start = prev = k
    out.append(str(start) if start == prev else f"{start}-{prev}")
    return ", ".join(out)


def branch_bounds(new):
    marks = []
    for i, line in enumerate(new):
        if line.startswith("if (PE_NUMBER ==") or line.startswith("end else if (PE_NUMBER =="):
            marks.append((int(line.split("==")[1].split(")")[0]), i))
    bounds = {}
    for n, (pe, i) in enumerate(marks):
        end = marks[n + 1][1] if n + 1 < len(marks) else next(
            j for j in range(i, len(new)) if new[j].startswith("endgenerate"))
        bounds[pe] = (i, end)
    return bounds


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    src_root = os.path.normpath(os.path.join(here, "..", ".."))
    generated = os.path.normpath(os.path.join(here, "..", "BROM.v"))

    if not os.path.exists(generated):
        raise SystemExit(f"missing {generated} -- run gen_brom.py first")

    upstream = {}
    for pe, sub in PE_TO_DIR.items():
        path = os.path.join(src_root, sub, "BROM.v")
        if not os.path.exists(path):
            raise SystemExit(f"missing upstream file: {path}")
        upstream[pe] = parse_table(path)

    # ---------------------------------------------------------------- EVIDENCE
    print("=== EVIDENCE: are the tables packings/slices of pe1's? ===")
    flat1 = [upstream[1][i][0] for i in sorted(upstream[1])]
    pos1 = {}
    for i, v in enumerate(flat1):
        pos1.setdefault(v, []).append(i)

    for pe in (4, 16):
        table = upstream[pe]
        width = len(next(iter(table.values())))
        uniform = [k for k in sorted(table) if len(set(table[k])) == 1]
        first_varied = next((k for k in sorted(table) if len(set(table[k])) > 1), None)
        matched = []
        for k in sorted(table):
            vals = table[k]
            if vals[0] in pos1 and any(flat1[s:s + width] == vals for s in pos1[vals[0]]):
                matched.append(k)
        print(f"  {PE_TO_DIR[pe]}: {len(table)} entries x {width} words; "
              f"{len(uniform)} all-equal entries (first varied at {first_varied}); "
              f"{len(matched)}/{len(table)} entries appear as a contiguous run in pe1's flat table")
        if matched:
            print(f"    matching indices: {summarize_ranges(matched)}")
        if len(matched) == len(table):
            print(f"    -> pe{pe}'s table IS a slice of pe1's; a formula may exist")
        else:
            print(f"    -> pe{pe}'s table is NOT a slice of pe1's; a formula was ruled out")
    print()

    # ---------------------------------------------------------------- VERIFY
    print("=== VERIFY: generated branches vs upstream, line for line ===")
    new = read_lines(generated)
    bounds = branch_bounds(new)
    ok = True
    for pe, sub in PE_TO_DIR.items():
        if pe not in bounds:
            print(f"  MISSING BRANCH for PE_NUMBER={pe}")
            ok = False
            continue
        lo, hi = bounds[pe]
        chunk = new[lo:hi]
        # strip the 4-space indent gen_brom.py adds when nesting
        dedented = [(ln[4:] if ln.startswith("    ") else ln) for ln in chunk]
        got = case_block(dedented)
        want = case_block(read_lines(os.path.join(src_root, sub, "BROM.v")))
        if got == want:
            print(f"  OK   PE_NUMBER={pe:<3} {len(want)} lines identical to rtl/{sub}/BROM.v")
        else:
            ok = False
            print(f"  FAIL PE_NUMBER={pe}  got {len(got)} lines / want {len(want)} lines")
            for a, b in zip(got, want):
                if a != b:
                    print(f"       got : {a!r}\n       want: {b!r}")
                    break
    print()
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
