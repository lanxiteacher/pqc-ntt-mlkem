"""Reproducible synthetic examples; no FPGA, PYNQ, or hardware timing."""
import argparse
import json
from pathlib import Path
import sys

from compare_integer_results import compare


def cases():
    # Reference formulas and synthetic producers are separate, small examples.
    a, b = [1, -2, 30, 4, 0], [10, 20, -3, 40, 5]
    add_gold = [a[i] + b[i] for i in range(len(a))]
    add_actual = list(map(sum, zip(a, b)))
    values = [3, -1, 4, 0, 2, -5, 7]
    prefix_gold = [sum(values[:i + 1]) for i in range(len(values))]
    prefix_actual, total = [], 0
    for value in values:
        total += value
        prefix_actual.append(total)
    bad = add_actual.copy()
    bad[3] += 1
    swapped = prefix_actual.copy()
    swapped[0], swapped[1] = swapped[1], swapped[0]
    return [
        ("vector_add_ok", {"a": a, "b": b}, add_gold, add_actual, "pass"),
        ("vector_add_bad_value", {"a": a, "b": b}, add_gold, bad, "mismatch"),
        ("prefix_sum_ok", {"values": values}, prefix_gold, prefix_actual, "pass"),
        ("prefix_sum_bad_order", {"values": values}, prefix_gold, swapped, "mismatch"),
        ("prefix_sum_missing", {"values": values}, prefix_gold, prefix_actual[:-1], "mismatch"),
    ]


def write_json(path, value):
    path.write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def run(output):
    # Existing directories are rejected so rerunning cannot destroy manual evidence.
    output.mkdir(parents=True, exist_ok=False)
    rows = []
    for name, inputs, expected, actual, wanted in cases():
        folder = output / name
        folder.mkdir()
        write_json(folder / "inputs.json", inputs)
        write_json(folder / "expected.json", expected)
        write_json(folder / "actual.json", actual)
        result = compare(expected, actual)
        result.update(source="synthetic_python", hardware_validated=False)
        write_json(folder / "report.json", result)
        rows.append(dict(case=name, expected_status=wanted, observed_status=result["status"],
                         accepted=result["status"] == wanted, matched=result["matched"],
                         mismatched=result["mismatched"]))
    summary = dict(schema_version=1, source="synthetic_python", hardware_validated=False,
                   hardware_timing_collected=False, all_checks_passed=all(r["accepted"] for r in rows),
                   cases=rows)
    write_json(output / "summary.json", summary)
    lines = ["# Synthetic offline comparison demo", "",
             "No FPGA/PYNQ execution or hardware performance measurement.", "",
             "An expected mismatch is a successful negative control, not a correct algorithm output.", "",
             "| Case | Expected | Observed | Matched | Mismatched | Accepted |",
             "|---|---|---|---:|---:|---|"]
    lines.extend(f"| {r['case']} | {r['expected_status']} | {r['observed_status']} | "
                 f"{r['matched']} | {r['mismatched']} | {r['accepted']} |" for r in rows)
    (output / "summary.md").write_bytes(("\n".join(lines) + "\n").encode("utf-8"))
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new output directory; must not exist")
    args = parser.parse_args(argv)
    try:
        result = run(args.output)
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    for row in result["cases"]:
        print(f"{row['case']}: expected={row['expected_status']}, observed={row['observed_status']}, "
              f"accepted={row['accepted']}")
    print(f"Synthetic checks: {sum(r['accepted'] for r in result['cases'])}/{len(result['cases'])}")
    return 0 if result["all_checks_passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
