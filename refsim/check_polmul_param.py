"""FULL/HALF on pe1/pe4/pe16: fresh C oracle, RTL, multiset AND ordered check.

No edits to the original six shell scripts or existing vector values.
All build/simulation intermediates go to an isolated temporary directory.
Unknown/missing/duplicate output, timeout, nonzero exit and bad data all fail.
Use --negative-controls to exercise wrong-load, corrupted-gold and missing-PE guards.
"""
import argparse
from collections import Counter
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def tool(name):
    found = shutil.which(name)
    if not found and os.name == "nt" and name in ("iverilog", "vvp"):
        candidate = Path("C:/iverilog/bin") / (name + ".exe")
        if candidate.is_file():
            found = str(candidate)
    if not found:
        raise RuntimeError(f"missing tool: {name}")
    return found


def run(args, cwd):
    p = subprocess.run([str(x) for x in args], cwd=cwd, capture_output=True,
                       encoding="utf-8", errors="replace", timeout=120)
    if p.returncode:
        raise RuntimeError(f"command failed ({p.returncode}): {args}\n{p.stdout[-3000:]}\n{p.stderr[-3000:]}")
    return p.stdout


def read_hex(path, count):
    rows = path.read_text(encoding="ascii").splitlines()
    if len(rows) != count or any(not re.fullmatch(r"[0-9a-fA-F]{1,3}", x) for x in rows):
        raise ValueError(f"{path}: expected {count} hex coefficients")
    values = [int(x, 16) for x in rows]
    if any(x >= 3329 for x in values):
        raise ValueError(f"{path}: value outside field")
    return values


def write_hex(path, values):
    path.write_bytes(("\n".join(f"{x:03x}" for x in values) + "\n").encode("ascii"))


def parse_output(out, pe, half):
    seen = {}
    for line in out.splitlines():
        if line.startswith("DOUT "):
            t = line.split()
            if len(t) != 4 or not re.fullmatch(r"[0-9a-fA-F]{3}", t[3]):
                raise ValueError(f"invalid/unknown RTL output: {line}")
            key = (int(t[1]), int(t[2]))
            if not (0 <= key[0] < 16 and 0 <= key[1] < 256) or key in seen:
                raise ValueError(f"duplicate/out-of-range row: {line}")
            seen[key] = int(t[3], 16)
    if len(seen) != 4096 or out.splitlines().count(f"COMPLETE {pe} {half} 16") != 1:
        raise ValueError("missing output/completion marker")
    if any(x in out for x in ("WARNING", "ERROR", "FATAL")):
        raise ValueError("simulation emitted a warning/error")
    return [[seen[g, i] for i in range(256)] for g in range(16)]


def compare(got, expected):
    multiset = ordered = 0
    for group, row in enumerate(got):
        gold = expected[group*256:(group+1)*256]
        # Count intersections with multiplicity, not set membership.
        multiset += sum((Counter(row) & Counter(gold)).values())
        # Final INTT output follows tau on all three builds (§5.3.4).
        ordered += sum(value == gold[i//2 + 128*(i%2)] for i, value in enumerate(row))
    return multiset, ordered


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--negative-controls", action="store_true")
    args = ap.parse_args()
    gcc, iv, vvp = (tool(n) for n in ("gcc", "iverilog", "vvp"))
    core = sorted((REPO / "rtl/ntt_core").glob("*.v"))
    if not core:
        raise RuntimeError("missing rtl/ntt_core sources")
    ref = REPO / "research/kyber_ref"
    libs = [ref / (name + ".c") for name in
            ("poly", "polyvec", "ntt", "reduce", "cbd", "indcpa", "kem", "verify", "fips202", "symmetric-shake")]
    libs.append(REPO / "research/mlkem_kat/randombytes_stub.c")
    with tempfile.TemporaryDirectory(prefix="pqc_polmul_") as tmp:
        work = Path(tmp).resolve()
        oracle = work / "oracle.exe"
        run([gcc, "-O2", "-Wall", "-I" + str(ref), "-o", oracle,
             HERE / "polmul_full_tool.c", *libs], work)
        last_got = last_gold = None
        for half, name in ((0, "fullmul"), (1, "halfmul")):
            a = read_hex(HERE / f"batch/{name}_a.txt", 4096)
            b = read_hex(HERE / f"batch/{name}_b.txt", 4096)
            frozen = read_hex(HERE / f"batch/{name}_exp.txt", 4096)
            if len(set(a)) < 1000 or len(set(b)) < 1000 or a == b:
                raise ValueError("degenerate or identical A/B vectors")
            expected = []
            for group in range(16):
                write_hex(work / "a.txt", a[group*256:(group+1)*256])
                write_hex(work / "b.txt", b[group*256:(group+1)*256])
                run([oracle, "a.txt", "b.txt", "gold.txt", "--half" if half else "--full"], work)
                expected.extend(read_hex(work / "gold.txt", 256))
            if expected != frozen:
                raise ValueError(f"{name}: frozen expectation disagrees with freshly compiled C")
            print(f"{name}: fresh C oracle agrees with 4096 frozen coefficients; "
                  f"A/B unique={len(set(a))}/{len(set(b))}", flush=True)
            write_hex(work / "in_a.txt", a)
            write_hex(work / "in_b.txt", b)
            for pe in (1, 4, 16):
                executable = work / "dut.vvp"
                run([iv, "-g2012", "-s", "polmul_param_tb", f"-DCFG_PE_NUM={pe}",
                     f"-DCFG_HALF={half}", "-o", executable, *core, HERE / "polmul_param_tb.v"], work)
                out = run([vvp, executable], work)
                got = parse_output(out, pe, half)
                multi, ordered = compare(got, expected)
                print(f"{'HALF' if half else 'FULL'} pe{pe}: multiset {multi}/4096; "
                      f"ordered(tau) {ordered}/4096", flush=True)
                if (multi, ordered) != (4096, 4096):
                    raise AssertionError(f"{name} pe{pe} mismatch")
                last_got, last_gold = got, expected
            if args.negative_controls and not half:
                run([iv, "-g2012", "-s", "polmul_param_tb", "-DCFG_PE_NUM=4", "-DBAD_LOAD",
                     "-o", executable, *core, HERE / "polmul_param_tb.v"], work)
                wrong = parse_output(run([vvp, executable], work), 4, 0)
                hits, _ = compare(wrong, expected)
                if hits == 4096:
                    raise AssertionError("wrong-load negative control did not fail")
                print(f"NEGATIVE wrong B load: multiset {hits}/4096, rejected", flush=True)
        if args.negative_controls:
            bad_gold = list(last_gold)
            bad_gold[7*256+100] = (bad_gold[7*256+100] + 1) % 3329
            assert compare(last_got, bad_gold) == (4095, 4095)
            print("NEGATIVE one corrupted expected coefficient: 4095/4096, rejected", flush=True)
            run([iv, "-g2012", "-s", "polmul_param_tb", "-o", executable,
                 *core, HERE / "polmul_param_tb.v"], work)
            p = subprocess.run([vvp, str(executable)], cwd=work, capture_output=True,
                               encoding="utf-8", errors="replace", timeout=20)
            if p.returncode == 0 or "CFG_PE_NUM is required" not in p.stdout:
                raise AssertionError("missing-PE guard did not fail")
            print("NEGATIVE missing PE: nonzero fatal, rejected", flush=True)
    print("PASS: 6 RTL runs, 24576 coefficients, fresh C oracle; no Vivado/board required.")


if __name__ == "__main__":
    main()
