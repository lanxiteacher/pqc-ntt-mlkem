# -*- coding: utf-8 -*-
"""
可断点续传地抓取 kat_MLKEM_768.rsp。

为什么不能一把梭：
  这个网络会在 0.8~1.6 MB 处掐断连接（codeload / raw 主机都试过）。
  只有 api.github.com 的 Range 请求能稳定拿到小块 —— 但它每小时只给
  60 次请求（未认证）。所以策略是：

    200 KB 一块 × 61 块 = 12,012,890 字节

  60 块正好能用一小时配额拿完。碰到 403 限流就睡到重置时刻再继续。

断点续传：已存在且大小正确的块直接跳过，所以中途被打断也不丢进度。

运行：PYTHONIOENCODING=utf-8 python fetch_kat.py
"""
import os
import re
import subprocess
import sys
import time
import math

sys.stdout.reconfigure(encoding="utf-8")

URL = ("https://api.github.com/repos/post-quantum-cryptography/KAT/"
       "contents/MLKEM/kat_MLKEM_768.rsp")
TOTAL = 12_012_890
CHUNK = 200_000
PARTS = "parts"
OUT = "kat_MLKEM_768.rsp"
ACCEPT = "application/vnd.github.raw"

os.makedirs(PARTS, exist_ok=True)
nchunks = math.ceil(TOTAL / CHUNK)


def chunk_path(i):
    return os.path.join(PARTS, "%04d" % i)


def expected_size(i):
    start = i * CHUNK
    return min(CHUNK, TOTAL - start)


def curl_range(start, end, dest):
    """返回 (http_code, 实际写入字节数)。"""
    r = subprocess.run(
        ["curl", "-s", "-L", "--max-time", "120",
         "-H", "Accept: " + ACCEPT,
         "-r", "%d-%d" % (start, end),
         "-o", dest,
         "-w", "%{http_code} %{size_download}",
         URL],
        capture_output=True, text=True)
    out = r.stdout.strip().split()
    if len(out) != 2:
        return "000", 0
    return out[0], int(out[1])


def rate_limit_reset():
    """查限流重置时刻（这次调用本身也计数，但只在被限流时才用）。"""
    r = subprocess.run(
        ["curl", "-s", "--max-time", "30",
         "https://api.github.com/rate_limit"],
        capture_output=True, text=True)
    m = re.search(r'"core"\s*:\s*\{[^}]*"reset"\s*:\s*(\d+)', r.stdout)
    return int(m.group(1)) if m else time.time() + 600


done = 0
for i in range(nchunks):
    p = chunk_path(i)
    want = expected_size(i)

    if os.path.exists(p) and os.path.getsize(p) == want:
        done += 1
        continue

    for attempt in range(6):
        code, got = curl_range(i * CHUNK, i * CHUNK + want - 1, p)

        if code == "403" or code == "429":
            reset = rate_limit_reset()
            wait = max(0, reset - time.time()) + 5
            print("  ⏳ 触发限流，睡 %.0f 秒（到 %s）"
                  % (wait, time.strftime("%H:%M:%S", time.localtime(reset))),
                  flush=True)
            time.sleep(wait)
            continue

        # Range 请求成功返回 206 Partial Content（服务端若忽略 Range 才回 200）
        if code in ("200", "206") and got == want:
            break

        if code == "416":           # 请求越界 = 文件比预期短
            print("  ⚠️  第 %d 块 416 —— 文件实际长度小于 %d" % (i, TOTAL))
            break

        print("  ↻ 第 %d 块第 %d 次失败 (HTTP=%s 得到 %d / 期望 %d)"
              % (i, attempt + 1, code, got, want), flush=True)
        time.sleep(2 + 3 * attempt)
    else:
        print("  ❌ 第 %d 块彻底失败，中止（已拿到的块保留，可重跑续传）" % i)
        sys.exit(1)

    done += 1
    if done % 5 == 0 or done == nchunks:
        print("  进度 %d/%d 块 (%.1f MB)"
              % (done, nchunks, done * CHUNK / 1e6), flush=True)

# ---- 合并 ----------------------------------------------------------------
print("\n合并分块 → %s" % OUT)
with open(OUT, "wb") as fout:
    for i in range(nchunks):
        with open(chunk_path(i), "rb") as fin:
            fout.write(fin.read())

size = os.path.getsize(OUT)
print("完成：%s  %d 字节" % (OUT, size))
if size != TOTAL:
    print("⚠️  大小与预期 %d 不符" % TOTAL)
else:
    print("✅ 大小与预期一致")
