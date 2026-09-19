# -*- coding: utf-8 -*-
"""
把 kat_MLKEM_768.rsp 的尾部补齐。

背景：文件 0..11,999,999 字节已验证无误，但尾部被混入了一个 279 字节的
GitHub 限流错误页，导致最后两条记录（count=998/999）不完整。
只差最后 12,890 字节 —— 一次 Range 请求就能补上，但当前配额已耗尽。

设计要点（都是踩过的坑）：
  1. **不只查大小，还要查内容**。这是最关键的教训：光比字节数的话，
     一个 279 字节的 JSON 错误页只要"大小对得上"就会被当成正常数据写进去。
     这里显式拒绝含 '"message"' 的响应。
  2. 403 时**不闷头睡到重置**，而是每 60 秒重试一次 ——
     本机出口 IP 会轮换（实测 .37 和 .175 都出现过），换个 IP 就有新配额，
     可能远早于重置时刻就能拿到。
  3. 幂等：文件已完整就直接退出，不重复下载。

运行：PYTHONIOENCODING=utf-8 python complete_kat.py
"""
import os
import re
import subprocess
import sys
import time
import datetime

sys.stdout.reconfigure(encoding="utf-8")

URL = ("https://api.github.com/repos/post-quantum-cryptography/KAT/"
       "contents/MLKEM/kat_MLKEM_768.rsp")
TOTAL = 12_012_890
PREFIX = 12_000_000          # 已验证无误的前缀长度
TAIL_LEN = TOTAL - PREFIX    # 12,890
OUT = "kat_MLKEM_768.rsp"


def log(msg):
    print("[%s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def reset_time():
    try:
        r = subprocess.run(["curl", "-s", "--max-time", "30",
                            "https://api.github.com/rate_limit"],
                           capture_output=True, text=True)
        m = re.search(r'"core"\s*:\s*\{[^}]*"reset"\s*:\s*(\d+)', r.stdout)
        return int(m.group(1)) if m else time.time() + 600
    except Exception:
        return time.time() + 600


def fetch_tail():
    """返回 (http_code, bytes)。bytes 为空表示失败。"""
    r = subprocess.run(
        ["curl", "-s", "-L", "--max-time", "120",
         "-H", "Accept: application/vnd.github.raw",
         "-r", "%d-%d" % (PREFIX, TOTAL - 1),
         "-w", "\n%{http_code}",
         URL],
        capture_output=True)
    body = r.stdout
    nl = body.rfind(b"\n")
    if nl < 0:
        return "000", b""
    try:
        code = body[nl + 1:].decode().strip()
    except Exception:
        return "000", b""
    data = body[:nl]
    return code, data


# ---- 已经是好的就直接退出 ------------------------------------------------
if os.path.exists(OUT) and os.path.getsize(OUT) == TOTAL:
    log("文件已是完整的 %d 字节，无需处理" % TOTAL)
    sys.exit(0)

log("目标：%s → %d 字节（当前 %d）"
    % (OUT, TOTAL, os.path.getsize(OUT) if os.path.exists(OUT) else 0))

# ---- 先把已知损坏的尾部切掉 ----------------------------------------------
with open(OUT, "r+b") as f:
    f.truncate(PREFIX)
log("已截断到已验证的前缀 %d 字节" % PREFIX)

# ---- 反复尝试取尾部 ------------------------------------------------------
deadline = time.time() + 3 * 3600      # 最多折腾 3 小时
attempt = 0
while time.time() < deadline:
    attempt += 1
    code, data = fetch_tail()

    if code in ("200", "206") and len(data) == TAIL_LEN:
        # ★ 内容校验：拒绝 JSON 错误页
        if b'"message"' in data[:400] or data.lstrip()[:1] == b"{":
            log("⚠️  拿到 %d 字节，但内容是 JSON（错误页），丢弃" % len(data))
        else:
            with open(OUT, "ab") as f:
                f.write(data)
            size = os.path.getsize(OUT)
            log("✅ 尾部已补齐，文件现在 %d 字节" % size)
            if size != TOTAL:
                log("❌ 大小与预期 %d 不符" % TOTAL)
                sys.exit(1)
            sys.exit(0)
    else:
        # 看看这次拿到的到底是什么
        snippet = data[:120].decode("utf-8", "replace").replace("\n", " ")
        log("第 %d 次尝试失败 HTTP=%s 得到 %d 字节 | %s"
            % (attempt, code, len(data), snippet))

    # 403/429：等一会儿再试（出口 IP 轮换的话可能提前成功）
    if code in ("403", "429"):
        rt = reset_time()
        wait = min(60, max(5, rt - time.time()))
        if attempt % 10 == 1:
            log("    限流中，官方重置时刻 %s，但仍每 60 秒重试（出口 IP 会轮换）"
                % datetime.datetime.fromtimestamp(rt).strftime("%H:%M:%S"))
    else:
        wait = 15

    time.sleep(wait)

log("❌ 超时，仍未取到尾部")
sys.exit(1)
