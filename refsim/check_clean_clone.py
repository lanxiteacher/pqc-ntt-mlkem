"""Clone the pushed repository into a fresh local directory and run B acceptance.

This checks missing/unpushed source or build artifacts, not a second physical PC.
Requires git, sh, gcc, Python and iverilog. No Vivado/board/GTKWave is required.
The temporary clone and all full logs are kept for review; nothing is deleted.
Usage: python refsim/check_clean_clone.py --output logs/verification_YYYY-MM-DD_B_clean_clone.json
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    for name in ("git", "sh", "gcc", "iverilog", "vvp"):
        if not shutil.which(name):
            raise RuntimeError(f"missing tool: {name}; install it and retry")
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    origin = subprocess.check_output(["git", "remote", "get-url", "origin"], cwd=REPO,
                                     encoding="utf-8").strip()
    work = Path(tempfile.mkdtemp(prefix="pqc_clean_clone_")).resolve()
    clone = work / "repo"
    print(f"Fresh clone on this PC: {clone}", flush=True)
    subprocess.run(["git", "clone", "--no-local", origin, str(clone)], check=True,
                   env=env, capture_output=True, timeout=120)
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=clone, encoding="ascii").strip()
    report = dict(date=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  scope="fresh remote clone on the SAME physical PC; not H10 second-PC acceptance",
                  commit=commit, platform=platform.platform(), python=sys.version,
                  clone=str(clone), steps=[])
    # No saved executable or simulation output may be present before building.
    tracked = subprocess.check_output(["git", "ls-files"], cwd=clone, encoding="utf-8").splitlines()
    if any(Path(x).suffix.lower() in (".exe", ".vvp", ".o", ".out") for x in tracked):
        raise RuntimeError("build artifact tracked in fresh clone")
    tasks = [("kat_build", ["sh", "research/mlkem_kat/build_kat.sh"]),
             ("kat_1000", [str(clone / "research/mlkem_kat/kat_verify.exe"),
                           "research/mlkem_kat/kat_MLKEM_768.rsp"])]
    tasks += [(Path(script).stem, ["sh", script]) for script in (
        "refsim/run_fntt_check.sh", "refsim/run_intt_pwm2_check.sh",
        "refsim/run_polmul_check.sh", "refsim/run_ntt_layers.sh",
        "refsim/run_proto_accept.sh")]
    tasks += [(p.stem, [sys.executable, str(p)]) for p in sorted((clone / "host/src").glob("test_*.py"))]
    tasks += [("parameterized_polmul", [sys.executable, "refsim/check_polmul_param.py", "--negative-controls"]),
              ("fntt_wave", [sys.executable, "refsim/run_wave_check.py"]),
              ("uart_rtl_fast", ["sh", "refsim/run_uart_check.sh", "+fast"])]
    try:
        for name, command in tasks:
            start = time.monotonic()
            print(f"RUN {name}", flush=True)
            p = subprocess.run(command, cwd=clone, env=env, capture_output=True,
                               encoding="utf-8", errors="replace", timeout=300)
            log = work / (name + ".txt")
            log.write_bytes((p.stdout + p.stderr).encode("utf-8"))
            step = dict(name=name, returncode=p.returncode, seconds=round(time.monotonic()-start, 2),
                        log=str(log), output=p.stdout, stderr=p.stderr)
            report["steps"].append(step)
            print(f"{'PASS' if p.returncode == 0 else 'FAIL'} {name} ({step['seconds']} s)", flush=True)
            if p.returncode:
                print(p.stdout[-2000:], p.stderr[-1000:], flush=True)
                raise RuntimeError(f"{name} failed; see {log}")
        report["tracked_changes_after_run"] = subprocess.check_output(
            ["git", "diff", "--name-only"], cwd=clone, encoding="utf-8").splitlines()
        report["passed"] = True
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes((json.dumps(report, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
        print(f"Evidence: {args.output}; full logs retained at {work}", flush=True)
    print(f"PASS: {len(report['steps'])} stages from committed remote sources. "
          "Second-PC verification remains pending.")


if __name__ == "__main__":
    main()
