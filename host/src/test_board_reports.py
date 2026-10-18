"""Existing evidence and damaged-log controls; no board access."""
from pathlib import Path
import tempfile
import unittest

from check_board_reports import COMMANDS, audit_file, audit_text, main
import contextlib
import io

REPORTS = Path(__file__).resolve().parents[2] / 'rtl' / 'vivado' / 'reports'


class BoardReportAcceptance(unittest.TestCase):
    def setUp(self):
        self.text = (REPORTS / 'board_pe1_txn.txt').read_text(encoding='utf-8')

    def test_six_current_board_reports(self):
        for name, build in [('board_pe1_txn.txt', 1), ('board_pe4_txn.txt', 4),
                            ('board_pe16_txn.txt', 16), ('board_pe1_f80_txn.txt', 1),
                            ('board_pe4_f75_txn.txt', 4), ('board_pe16_f62.5_txn.txt', 16)]:
            with self.subTest(name=name):
                result = audit_file(REPORTS / name, build)
                self.assertEqual(result['status'], 'pass', result)
                self.assertFalse(result['frequency_verified'])
                self.assertFalse(result['hardware_provenance_verified'])
                self.assertEqual(len(result['sha256']), 64)

    def test_historical_failure_and_legacy_format(self):
        result = audit_file(REPORTS / 'board_pe1_txn_2026-10-15_5of6.txt')
        self.assertEqual(result['status'], 'fail')
        self.assertEqual([r['command'] for r in result['commands'] if r['status'] == 'fail'], ['#PMUL TIME 1'])
        old = audit_file(REPORTS / 'board_pe4_txn_2026-10-04.txt')
        self.assertEqual(old['status'], 'incomplete')

    def test_missing_and_truncated_sections(self):
        no_full = self.text[:self.text.index('--- #PMUL FULL 1')]
        result = audit_text(no_full)
        self.assertEqual(result['status'], 'incomplete')
        self.assertEqual(result['commands'][-1]['status'], 'not_present')
        truncated = self.text[:self.text.index('      FNTT：')]
        self.assertEqual(audit_text(truncated)['commands'][1]['status'], 'incomplete')

    def test_success_markers_alone_never_pass(self):
        for bad in [self.text.replace('256 个系数里 **0**', '256 个系数里 **1**', 1),
                    self.text.replace('收到 256 行结果：', '收到 255 行结果：', 1),
                    self.text.replace('--check：按 **pe1**', '--check：按 **pe4**', 1),
                    self.text.replace('插座：真串口', '插座：陪练'),
                    self.text.replace('FNTT：256', 'INTT：256', 1),
                    self.text.replace('回帧原文：#OK PING*17', '回帧原文：#ERR 01*00'),
                    self.text.replace('6 / 6 条全中', '5 / 6 条全中')]:
            with self.subTest(sample=bad[:40]):
                self.assertNotEqual(audit_text(bad)['status'], 'pass')

    def test_duplicates_conflicts_and_wrong_build(self):
        head = self.text.index('--- #PING')
        end = self.text.index('--- #NTT 1')
        duplicate = self.text[:end] + self.text[head:end] + self.text[end:]
        self.assertEqual(audit_text(duplicate)['commands'][0]['status'], 'incomplete')
        self.assertEqual(audit_text(self.text, 4)['status'], 'incomplete')
        conflict = self.text.replace('   #NTT 1             ✅ PASS', '   #NTT 1             ❌ FAIL（rc=1）')
        self.assertEqual(audit_text(conflict)['status'], 'incomplete')

    def test_cli_exit_codes_output_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as temp, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            folder = Path(temp)
            output = folder / 'result'
            self.assertEqual(main([str(REPORTS / 'board_pe1_txn.txt'), '--output', str(output)]), 0)
            self.assertTrue((output / 'summary.json').is_file())
            before = (output / 'summary.json').read_bytes()
            self.assertEqual(main([str(REPORTS / 'board_pe1_txn.txt'), '--output', str(output)]), 2)
            self.assertEqual((output / 'summary.json').read_bytes(), before)
            self.assertEqual(main([str(REPORTS / 'board_pe1_txn_2026-10-15_5of6.txt')]), 1)
            self.assertEqual(main([str(folder / 'absent.txt')]), 2)
            cut = folder / 'cut.txt'
            cut.write_bytes(self.text[:self.text.index('--- #PMUL FULL 1')].encode('utf-8'))
            self.assertEqual(main([str(cut)]), 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
