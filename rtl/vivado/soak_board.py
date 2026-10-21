"""真板连续 #NTT 浸泡：一条命令、一个进程、固定串口，统计超时/数值不符/异常。

用法（板子已烧好、串口空闲）：

    python rtl/vivado/soak_board.py --port COM9 --build 16 --minutes 40

产出：
    logs/verification_<日期>_A_soak.txt   汇总 + 每次失败的明细（时间、类型、延迟）

判据：0 超时、0 数值不符、0 异常；吞吐按「实际经过时间」算，不按脚本自报。
⚠️ 只跑 #NTT 1（pe 档由 --build 声明）；换档要先换位流再改 --build。
"""

import argparse
import faulthandler
import os
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "host" / "src"))

import host
import link
import unpack
import vectors
import board_run

CMD = "#NTT 1"


def open_hst(port, baud):
    lk = link.open_link("serial", port=port, baud=baud)
    # 2026-10-21：连续无间隔压到 ~500 次时，CH340 的 write/flush 会永久阻塞
    # （进程 CPU 不再涨、板子其实还活着）。给底层串口一个写超时，
    # 把「永久卡死」变成可捕获的异常；harness 这层兜，不改 B 的 host/。
    try:
        lk._ser.write_timeout = 1.0
    except Exception:
        pass
    h = host.Host(lk, verbose=False)
    rdy = h.handshake()
    return lk, h, rdy


def start_watchdog(timeout=60.0):
    state = {"last": time.monotonic()}

    def loop():
        while True:
            time.sleep(5.0)
            if time.monotonic() - state["last"] > timeout:
                sys.stdout.write("!! %.0f s 无进展，卡住了；下面是栈\n" % timeout)
                sys.stdout.flush()
                faulthandler.dump_traceback()
                sys.stdout.flush()
                os._exit(4)

    threading.Thread(target=loop, daemon=True).start()
    return state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--build", type=int, required=True, choices=(1, 4, 16))
    ap.add_argument("--minutes", type=float, default=40.0)
    ap.add_argument("--count", type=int, default=0, help="0 = 按分钟数")
    ap.add_argument("--gap", type=float, default=0.02, help="两次事务之间的间隔秒数")
    ap.add_argument("--output", default="")
    args = ap.parse_args()

    data, exp_file = board_run.build_data(CMD, args.build)
    exp = unpack.read_values(vectors.BATCH_DIR / exp_file)[:vectors.GROUP_LEN]
    kind = unpack.kind_of(CMD)

    time.sleep(1.0)          # 让上一次 close 的 USB 管道先落定（2026-10-21 实测：太急会卡）
    lk, hst, rdy = open_hst(args.port, args.baud)
    time.sleep(0.5)
    try:
        lk.discard_pending()
    except Exception:
        pass
    wd = start_watchdog(60.0)
    print("port=%s baud=%d build=pe%d data_rows=%d gap=%.3fs rdy=%s"
          % (lk.port, lk.baud, args.build, len(data), args.gap,
             ("pe%d" % hst.build) if rdy else "missed"))
    sys.stdout.flush()

    t_start = time.monotonic()
    deadline = None if args.count else t_start + args.minutes * 60.0
    n = pass_n = fail_n = err_n = 0
    lat = []
    fails = []
    reopen_fail = 0
    consec = 0

    while True:
        if deadline is not None and time.monotonic() >= deadline:
            break
        if args.count and n >= args.count:
            break
        n += 1
        t0 = time.monotonic()
        try:
            txn = hst.run(CMD, data, expect_rows=vectors.GROUP_LEN)
            dt = time.monotonic() - t0
            if txn.outcome != host.RESULT_OK:
                fail_n += 1
                consec += 1
                fails.append((n, str(txn.outcome), "-", dt))
            else:
                got = unpack.unpack(kind, txn.rows, args.build)
                bad, _ = unpack.compare_values(got, exp)
                if bad:
                    fail_n += 1
                    consec += 1
                    fails.append((n, "MISMATCH", str(bad), dt))
                else:
                    pass_n += 1
                    lat.append(dt)
                    consec = 0
        except Exception as e:
            err_n += 1
            consec += 1
            fails.append((n, "EXC:" + type(e).__name__, "-", time.monotonic() - t0))
            reopen_fail += 1
            try:
                lk.close()
            except Exception:
                pass
            time.sleep(1.0)
            try:
                lk, hst, _ = open_hst(args.port, args.baud)
                reopen_fail = 0
            except Exception as e2:
                fails.append((n, "REOPEN:" + type(e2).__name__, "-", 0.0))
                if reopen_fail >= 6:
                    print("!! 连续 6 次重开串口失败，停止")
                    break
                time.sleep(2.0)
        if consec >= 5:
            print("!! 连续 5 次失败/异常，先停（板子或 USB 需要复位）")
            sys.stdout.flush()
            break
        wd["last"] = time.monotonic()
        if args.gap > 0:
            time.sleep(args.gap)
        if n % 100 == 0:
            el = time.monotonic() - t_start
            print("  %d 次：pass=%d fail=%d exc=%d  %.0f 次/分  %.1f 秒"
                  % (n, pass_n, fail_n, err_n, n / el * 60.0, el))
            sys.stdout.flush()

    elapsed = time.monotonic() - t_start
    ok = (fail_n == 0 and err_n == 0)
    lat_sorted = sorted(lat)
    p95 = lat_sorted[int(len(lat_sorted) * 0.95)] if lat_sorted else 0.0
    avg = sum(lat) / len(lat) if lat else 0.0
    date = datetime.now().strftime("%Y-%m-%d")
    out = Path(args.output) if args.output else ROOT / "logs" / ("verification_%s_A_soak.txt" % date)
    lines = [
        "真板 #NTT 浸泡（%s）" % datetime.now(timezone.utc).isoformat(),
        "port=%s baud=%d build=pe%d" % (args.port, args.baud, args.build),
        "数据行=%d 期望系数=%d" % (len(data), len(exp)),
        "连续次数=%d 通过=%d 失败=%d 异常=%d" % (n, pass_n, fail_n, err_n),
        "经过时间=%.1f s 吞吐=%.1f 次/分" % (elapsed, n / elapsed * 60.0 if elapsed else 0),
        "单次延迟 avg=%.3f s p95=%.3f s max=%.3f s" % (avg, p95, max(lat) if lat else 0.0),
        "结论=%s" % ("PASS: 0 超时 / 0 数值不符 / 0 异常" if ok else "FAIL: 详见明细"),
        "",
        "失败明细（序号, 类型, 不同系数, 延迟s）：",
    ]
    for f in fails:
        lines.append("  #%d %s %s %.3f" % f)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")

    print("")
    print("经过 %.1f 秒 / %d 次：pass=%d fail=%d exc=%d（%.1f 次/分）"
          % (elapsed, n, pass_n, fail_n, err_n, n / elapsed * 60.0 if elapsed else 0))
    print("avg=%.3f s p95=%.3f s max=%.3f s" % (avg, p95, max(lat) if lat else 0.0))
    print("PASS" if ok else "FAIL")
    print("日志：%s" % out)
    try:
        lk.close()
    except Exception:
        pass
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
