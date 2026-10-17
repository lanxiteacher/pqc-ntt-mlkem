"""Compare ordered integer JSON arrays, independently of algorithm or hardware.

Usage: python refsim/compare_integer_results.py expected.json actual.json --report report.json
Exit codes: 0 exact match, 1 result mismatch, 2 invalid input/report I/O.
This offline component does not call, time, or validate PYNQ hardware.
"""
import argparse
import json
from pathlib import Path
import sys


def validate(values, name):
    if not isinstance(values, (list, tuple)):
        raise ValueError(f"{name}: expected an integer array")
    for index, value in enumerate(values):
        # bool is an int subclass in Python, but is not a numeric result here.
        if type(value) is not int:
            raise ValueError(f"{name}: index {index} must be an integer, got {value!r}")


def compare(expected, actual, max_details=10):
    """Indices are zero-based. Details are capped; all positions are checked.

    Every missing or extra value counts as a mismatch. No modular reduction,
    scaling, sorting, tolerance, padding, or input permutation is performed.
    """
    validate(expected, "expected")
    validate(actual, "actual")
    if not expected:
        raise ValueError("expected: empty reference cannot establish correctness")
    if type(max_details) is not int or max_details < 1:
        raise ValueError("max_details must be a positive integer")
    matched = mismatched = 0
    details = []
    for index in range(max(len(expected), len(actual))):
        if index >= len(expected):
            kind = "extra"
        elif index >= len(actual):
            kind = "missing"
        elif expected[index] != actual[index]:
            kind = "value"
        else:
            matched += 1
            continue
        mismatched += 1
        if len(details) < max_details:
            details.append(dict(index=index, position=index + 1, kind=kind,
                                expected=expected[index] if index < len(expected) else None,
                                actual=actual[index] if index < len(actual) else None))
    return dict(schema_version=1, status="pass" if mismatched == 0 else "mismatch",
                comparison="ordered_exact_integer", expected_count=len(expected),
                actual_count=len(actual), matched=matched, mismatched=mismatched,
                details=details, details_omitted=mismatched - len(details))


def read_values(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("expected", type=Path)
    parser.add_argument("actual", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--max-details", type=int, default=10)
    args = parser.parse_args(argv)
    if args.report and args.report.resolve() in {args.expected.resolve(), args.actual.resolve()}:
        print("ERROR: report path must not overwrite either input", file=sys.stderr)
        return 2
    try:
        result = compare(read_values(args.expected), read_values(args.actual), args.max_details)
    except (OSError, ValueError) as exc:
        result = dict(schema_version=1, status="error", error=str(exc))
    result["expected_file"] = str(args.expected.resolve())
    result["actual_file"] = str(args.actual.resolve())
    if args.report:
        try:
            args.report.write_bytes((json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
        except OSError as exc:
            print(f"ERROR: cannot write report: {exc}", file=sys.stderr)
            return 2
    if result["status"] == "error":
        print(f"ERROR: {result['error']}")
        return 2
    print(f"{result['status'].upper()}: expected={result['expected_count']}, "
          f"actual={result['actual_count']}, matched={result['matched']}, "
          f"mismatched={result['mismatched']}")
    for item in result["details"]:
        print(f"  position={item['position']} (index={item['index']}) {item['kind']}: "
              f"expected={item['expected']}, actual={item['actual']}")
    if result["details_omitted"]:
        print(f"  {result['details_omitted']} additional differences omitted from details")
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
