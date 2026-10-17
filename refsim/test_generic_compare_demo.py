"""Offline integration acceptance for examples, saved evidence, and notebook cells."""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from run_generic_compare_demo import run


class DemoAcceptance(unittest.TestCase):
    def test_saved_cases_and_overwrite_protection(self):
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / 'demo'
            summary = run(output)
            self.assertTrue(summary['all_checks_passed'])
            self.assertFalse(summary['hardware_validated'])
            self.assertEqual(len(summary['cases']), 5)
            self.assertEqual(sum(r['observed_status'] == 'mismatch' for r in summary['cases']), 3)
            cli = Path(__file__).with_name('compare_integer_results.py')
            for row in summary['cases']:
                folder = output / row['case']
                report = json.loads((folder / 'report.json').read_text(encoding='utf-8'))
                self.assertEqual(report['status'], row['expected_status'])
                process = subprocess.run([sys.executable, str(cli), str(folder / 'expected.json'),
                                          str(folder / 'actual.json')], capture_output=True)
                self.assertEqual(process.returncode, 0 if row['expected_status'] == 'pass' else 1)
            bad = json.loads((output / 'vector_add_bad_value' / 'report.json').read_text(encoding='utf-8'))
            self.assertEqual((bad['details'][0]['position'], bad['details'][0]['expected'],
                              bad['details'][0]['actual']), (4, 44, 45))
            before = (output / 'summary.json').read_bytes()
            with self.assertRaises(FileExistsError):
                run(output)
            self.assertEqual((output / 'summary.json').read_bytes(), before)

    def test_notebook_code_cells_without_jupyter(self):
        notebook = Path(__file__).with_name('generic_compare_template.ipynb')
        data = json.loads(notebook.read_text(encoding='utf-8'))
        scope = {}
        with contextlib.redirect_stdout(io.StringIO()):
            for cell in data['cells']:
                if cell['cell_type'] == 'code':
                    exec(compile(''.join(cell['source']), str(notebook), 'exec'), scope)
        self.assertEqual(scope['example']['mismatched'], 1)
        self.assertFalse(scope['example']['hardware_provenance_verified'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
