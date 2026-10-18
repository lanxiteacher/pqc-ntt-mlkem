"""Audit existing board_run report text; never operates hardware or recomputes NTT.

Exit: 0 all supplied reports pass, 1 explicit failures, 2 incomplete evidence/I/O.
Supported format: run_board_txn_report.sh (full per-command output + summary).
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sys

COMMANDS = ('#PING', '#NTT 1', '#INTT 1', '#PMUL NTT 1', '#PMUL TIME 1', '#PMUL FULL 1')
HEADER = re.compile(r'^--- (#[A-Z]+(?: [A-Z]+)?(?: \d+)?)(?:（.*）)?\s*---\s*$', re.M)
STATUS_TEXT = {'pass': '通过', 'fail': '失败', 'incomplete': '证据不完整', 'not_present': '未见执行段'}


def audit_text(text, expected_build=None):
    """Conservative structural audit of declared results, not raw coefficient validation."""
    issues = []
    before, separator, tail = text.partition('\n汇总\n')
    headers = list(HEADER.finditer(before))
    sections = {}
    for index, match in enumerate(headers):
        end = headers[index + 1].start() if index + 1 < len(headers) else len(before)
        sections.setdefault(match[1], []).append(before[match.end():end])
    builds = re.findall(r'^\s*折叠度：pe(1|4|16)（', text, re.M)
    build = int(builds[0]) if len(builds) == 1 else None
    if build is None:
        issues.append('缺少唯一的报告档位声明（仅支持新格式完整日志）')
    if expected_build is not None and build != expected_build:
        issues.append(f'报告档位 {build} 与要求 {expected_build} 不同')
    tags = re.findall(r'PE=(1|4|16) TAG=([^）\n]*)', text)
    if len(tags) != 1 or int(tags[0][0]) != build:
        issues.append('生成参数缺失、重复或与报告档位不一致')
    unexpected = set(sections) - set(COMMANDS)
    if unexpected:
        issues.append('存在未知执行段：' + ', '.join(sorted(unexpected)))
    rows = []
    for command in COMMANDS:
        blocks = sections.get(command, [])
        reasons = []
        status = 'incomplete'
        if not blocks:
            status = 'not_present'
            reasons.append('日志中没有本命令执行段；不能断言从未执行')
        elif len(blocks) != 1:
            reasons.append('执行段重复，拒绝挑选其中一次作为结果')
        else:
            block = blocks[0]
            markers = re.findall(r'^\s*→\s*(?:✅ (PASS)|❌ (FAIL)（rc=(\d+)）)\s*$', block, re.M)
            counts = [(int(n), int(bad)) for n, bad in
                      re.findall(r'(?:FNTT|INTT|PWM2)：(\d+) 个系数里 \*\*(\d+)\*\* 个不同。', block)]
            outcomes = re.findall(r'^\s*' + re.escape(command) + r'：(OK|FAILED|STOP)（', block, re.M)
            failed = any(m[1] == 'FAIL' for m in markers) or any(bad > 0 for _, bad in counts)
            failed = failed or any(o in ('FAILED', 'STOP') for o in outcomes)
            if failed:
                status = 'fail'
                reasons.append('执行段记录失败退出、事务失败或非零差异；不一定是硬件算术故障')
            else:
                if len(markers) != 1 or markers[0][0] != 'PASS':
                    reasons.append('缺少唯一的成功退出标记')
                if outcomes != ['OK']:
                    reasons.append('缺少唯一的本命令事务 OK 记录')
                if len(re.findall(r'^\s*插座：真串口 .+（\d+-8N1）\s*$', block, re.M)) != 1:
                    reasons.append('缺少唯一的真串口来源声明（陪练不计为真板日志）')
                if command == '#PING':
                    # Unlike arbitrary probe commands, a PING refusal is not a passing PING.
                    if '回帧原文：#OK PING*17' not in block or '结论：探活成功' not in block:
                        reasons.append('缺少成功 PING 回帧及结论')
                else:
                    wanted_kind = 'FNTT' if command == '#NTT 1' else ('PWM2' if command == '#PMUL NTT 1' else 'INTT')
                    if re.findall(r'(FNTT|INTT|PWM2)：\d+ 个系数里', block) != [wanted_kind]:
                        reasons.append('比较结果的运算类型不符合本命令')
                    if counts != [(256, 0)]:
                        reasons.append('缺少唯一的 256 系数、0 差异结果')
                    if re.findall(r'收到 (\d+) 行结果：', block) != ['256']:
                        reasons.append('缺少唯一的收到 256 行结果记录')
                    if re.findall(r'--check：按 \*\*pe(\d+)\*\*', block) != [str(build)]:
                        reasons.append('解包档位缺失或与报告档位不同')
                    wanted = '256' if command in ('#NTT 1', '#INTT 1') else '512'
                    sent = re.findall(r'^\s*命令：' + re.escape(command) + r'\s+数据行：(\d+)\s*$', block, re.M)
                    if sent != [wanted]:
                        reasons.append('命令/输入行数记录不符合本命令契约')
                    if '结论：全部对得上。' not in block:
                        reasons.append('缺少数值核对成功结论')
                if not reasons:
                    status = 'pass'
        rows.append(dict(command=command, status=status, reasons=reasons))
    summaries = re.findall(r'^\s*(#[A-Z]+(?: [A-Z]+)?(?: \d+)?)\s+(?:✅ (PASS)|❌ (FAIL)（rc=\d+）)\s*$', tail, re.M)
    if not separator or Counter(s[0] for s in summaries) != Counter(COMMANDS):
        issues.append('汇总命令缺失、重复或不完整')
    else:
        summary_map = {cmd: 'pass' if yes else 'fail' for cmd, yes, no in summaries}
        for row in rows:
            if row['status'] in ('pass', 'fail') and summary_map[row['command']] != row['status']:
                issues.append(row['command'] + ' 的汇总与执行段冲突')
    totals = re.findall(r'^\s*(\d+) / (\d+) 条全中\s*$', tail, re.M)
    declared_passes = sum(bool(s[1]) for s in summaries)
    if totals != [(str(declared_passes), '6')]:
        issues.append('汇总总数缺失或与各条标记不一致')
    status = 'fail' if any(r['status'] == 'fail' for r in rows) else (
        'pass' if not issues and all(r['status'] == 'pass' for r in rows) else 'incomplete')
    return dict(status=status, declared_build=build,
                declared_tag=tags[0][1] if len(tags) == 1 else None,
                hardware_provenance_verified=False, frequency_verified=False,
                coefficients_recomputed=False, commands=rows, issues=issues)


def audit_file(path, expected_build=None):
    raw = path.read_bytes()
    report = audit_text(raw.decode('utf-8-sig').replace('\r\n', '\n'), expected_build)
    report.update(file=str(path.resolve()), sha256=hashlib.sha256(raw).hexdigest())
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('logs', nargs='+', type=Path)
    parser.add_argument('--build', choices=(1, 4, 16), type=int, help='require this declared build')
    parser.add_argument('--output', type=Path, help='new directory for summary.json/summary.md; must not exist')
    args = parser.parse_args(argv)
    reports = []
    for path in args.logs:
        try:
            reports.append(audit_file(path, args.build))
        except (OSError, UnicodeError) as exc:
            reports.append(dict(file=str(path.resolve()), status='incomplete', commands=[], issues=[str(exc)]))
    lines = ['# Existing board log audit', '',
             'Checks recorded text only; no hardware access, frequency verification, or coefficient recomputation.', '']
    for result in reports:
        title = f"{Path(result['file']).name}: {STATUS_TEXT[result['status']]}"
        print(title)
        lines.extend(['## ' + title, ''])
        for row in result['commands']:
            detail = '; '.join(row['reasons'])
            message = f"  {row['command']}: {STATUS_TEXT[row['status']]}" + (f' ({detail})' if detail else '')
            print(message)
            lines.append('- ' + message.strip())
        for issue in result['issues']:
            print('  注意：' + issue)
            lines.append('- 注意：' + issue)
        lines.append('')
    if args.output:
        try:
            args.output.mkdir(parents=True, exist_ok=False)
            payload = dict(schema_version=1, scope='existing_log_text_audit', reports=reports)
            (args.output / 'summary.json').write_bytes((json.dumps(payload, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))
            (args.output / 'summary.md').write_bytes(('\n'.join(lines) + '\n').encode('utf-8'))
        except OSError as exc:
            print(f'ERROR: cannot create output: {exc}', file=sys.stderr)
            return 2
    return 1 if any(r['status'] == 'fail' for r in reports) else (
        0 if all(r['status'] == 'pass' for r in reports) else 2)


if __name__ == '__main__':
    sys.exit(main())
