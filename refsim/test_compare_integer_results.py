"""Offline failure-path acceptance; no RTL simulation or PYNQ is invoked."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from compare_integer_results import compare, main


class ComparisonAcceptance(unittest.TestCase):
    def test_exact_with_signed_and_large_values(self):
        self.assertEqual(compare([-5, 0, 2**64], [-5, 0, 2**64])["status"], "pass")

    def test_position_must_match_even_when_multiset_matches(self):
        result = compare([7, 9, 7], [7, 7, 9])
        self.assertEqual(result["mismatched"], 2)
        self.assertEqual([d["position"] for d in result["details"]], [2, 3])

    def test_missing_extra_and_empty_actual(self):
        for gold, got, kind, count in [([1, 2], [1], "missing", 1),
                                        ([1], [1, 2], "extra", 1),
                                        ([1, 2], [], "missing", 2)]:
            result = compare(gold, got)
            self.assertEqual(result["status"], "mismatch")
            self.assertEqual(result["mismatched"], count)
            self.assertEqual(result["details"][0]["kind"], kind)

    def test_detail_limit_does_not_limit_comparison(self):
        result = compare([1] * 30, [2] * 30, max_details=2)
        self.assertEqual((result["mismatched"], len(result["details"]), result["details_omitted"]),
                         (30, 2, 28))

    def test_invalid_inputs_never_pass(self):
        for gold, got in [([], []), ([1], [True]), ([1], [1.0]), ([1], ["1"]),
                          ([1], [None]), ({"x": 1}, [1]), ([False], [0])]:
            with self.subTest(gold=gold, got=got), self.assertRaises(ValueError):
                compare(gold, got)

    def test_cli_exit_codes_and_saved_report(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            gold, got, report = (root / name for name in ("expected.json", "actual.json", "report.json"))
            gold.write_bytes(b"[11,22,33,44]\n")
            for content, code, status in [(b"[11,22,33,44]", 0, "pass"),
                                            (b"[11,22,33,45]", 1, "mismatch"),
                                            (b"not json", 2, "error"),
                                            (b"[true]", 2, "error")]:
                got.write_bytes(content)
                with contextlib.redirect_stdout(io.StringIO()):
                    rc = main([str(gold), str(got), "--report", str(report)])
                self.assertEqual(rc, code)
                self.assertEqual(json.loads(report.read_text(encoding="utf-8"))["status"], status)
            before = gold.read_bytes()
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(main([str(gold), str(got), "--report", str(gold)]), 2)
            self.assertEqual(gold.read_bytes(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
