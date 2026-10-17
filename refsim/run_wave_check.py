"""Compile the H5 FNTT wave bench and verify all 256 captured beats.

Usage: python refsim/run_wave_check.py [--render-svg]
Rebuilds the VCD from sources; no GTKWave or GUI is needed for verification.
The existing PNG is an optional illustration, not the machine verdict.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from check_polmul_param import tool

HERE = Path(__file__).resolve().parent


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--render-svg", action="store_true")
    args = ap.parse_args()
    modules = ("addressgenerator BRAM BROM butterfly div2 dt0 dt1 dt2 dt3 FA HA "
               "intmul modadd modmul modred modsub shiftreg KyberHPM1PE").split()
    sources = [HERE / "pe1" / (name + ".v") for name in modules]
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    with tempfile.TemporaryDirectory(prefix="pqc_wave_") as tmp:
        executable = Path(tmp) / "wave.vvp"
        subprocess.run([tool("iverilog"), "-g2012", "-s", "fntt_wave_tb", "-o", str(executable),
                        *map(str, sources), str(HERE / "pe1/fntt_wave_tb.v")],
                       cwd=HERE, env=env, check=True, timeout=60)
        result = subprocess.run([tool("vvp"), str(executable)], cwd=HERE, env=env,
                                capture_output=True, encoding="utf-8", errors="replace", timeout=60)
        print(result.stdout)
        if result.returncode or "256/256 全中" not in result.stdout:
            raise RuntimeError("wave bench did not pass")
    subprocess.run([sys.executable, str(HERE / "gen_wave_figure.py"),
                    "--svg-only" if args.render_svg else "--verify-only"],
                   cwd=HERE, env=env, check=True, timeout=60)
    print("PASS: rebuilt FNTT VCD; 256/256 known-value beats matched. Scope: baseline pe1, one group.")


if __name__ == "__main__":
    main()
