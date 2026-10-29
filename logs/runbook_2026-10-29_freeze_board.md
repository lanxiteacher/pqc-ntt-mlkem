# 冻结回归 · 真板操作单（§4 + §5，约 25 分钟）

> **给谁**：A（只有 A 工位有板子与 Vivado）。
> **目的**：在冻结提交上留下 `_freeze` 证据，补齐 `logs/freeze_regression_checklist.md` §4/§5。
> **前置**：2026-10-29 的 J07 已证明同一套操作能跑通（`logs/verification_2026-10-29_A_j07_board.txt`），
> 本单只是换 `_freeze` 标签、换回 count=0 的交付 trace，并把证据名对齐清单。
>
> ⚠️ **所有命令都在仓库根目录执行**（`BIT=` 的相对路径按当前目录解析）。

## 一、开工前 5 分钟（逐条核，缺一条都表现为「看不到设备」）

```bash
git pull
git rev-parse --short HEAD          # 记下来，报告头与提交记录都要用
git status --porcelain              # 应只剩本机临时项

ls -l rtl/vivado/_runs/pe{1,4,16}/ntt_board.bit
sha256sum rtl/vivado/_runs/pe{1,4,16}/ntt_board.bit
powershell -NoProfile -Command "[System.IO.Ports.SerialPort]::GetPortNames()"
```

- [ ] 下载器插底板**右侧 14-Pin JTAG 座**（`USB_UART` / `USB_SLAVE` 不能下载）
- [ ] 底板 **P5 跳 PL 档**（3–5、4–6 短接）
- [ ] 启动拨码 **JTAG 档**（两位都 ON）
- [ ] 串口没被串口助手 / 上一次没退的 python 占着
- [ ] 三只位流都在；把三个 SHA-256 抄进下面的结果表（位流身份靠它）

> 串口号会变，**不要写死**。后面命令里的 `COM9` 全部换成上面查到的那个。
> `_runs/` 不在 git 里 —— 换机器要先用 `rtl/vivado/run_board_synth.sh` 重出。

## 二、§4 真板三档 × 六条命令（约 15 分钟）

每档两步：**先烧对应位流，再跑事务**。换档不重烧的症状是「256 个值全错」。

```bash
# ── pe1 ─────────────────────────────────────────────
BIT=rtl/vivado/_runs/pe1/ntt_board.bit sh rtl/vivado/run_board_prog.sh
PE=1  TAG=_freeze PORT=COM9 sh rtl/vivado/run_board_txn_report.sh

# ── pe4 ─────────────────────────────────────────────
BIT=rtl/vivado/_runs/pe4/ntt_board.bit sh rtl/vivado/run_board_prog.sh
PE=4  TAG=_freeze PORT=COM9 sh rtl/vivado/run_board_txn_report.sh

# ── pe16 ────────────────────────────────────────────
BIT=rtl/vivado/_runs/pe16/ntt_board.bit sh rtl/vivado/run_board_prog.sh
PE=16 TAG=_freeze PORT=COM9 sh rtl/vivado/run_board_txn_report.sh
```

**判据**：每档 **6/6** —— `#PING` + `#NTT 1` / `#INTT 1` / `#PMUL NTT 1` /
`#PMUL TIME 1` / `#PMUL FULL 1`，每条 0/256 不同。
产物：`rtl/vivado/reports/board_pe{1,4,16}_freeze_txn.txt`。

> `TAG=_freeze` 决定文件名，不与 10-18 的 `board_pe<N>_txn.txt` 和 10-29 的 `_j07` 互相覆盖。
> 报告已存在时不覆盖；确需重跑先留底再加 `FORCE=1`。

## 三、§5 count=0 交付 trace 三档 45 次（约 5 分钟）

```bash
PORT=COM9 OUTTAG=_freeze sh rtl/vivado/run_kem_trace_boards.sh
```

脚本会**自己逐档烧位流再跑**（不用手动烧），默认用
`logs/verification_2026-10-18_B_kem_delivery_trace.json`。

**判据**：三档各 **15/15**、每档 3,840 系数，合计 **45 次 / 11,520 系数**；
每个 `session.json` 的 `status=pass`、`transactions=15`。
产物：`logs/verification_<当天日期>_A_kem_serial_pe{1,4,16}_freeze/`。

> 输出目录不能已存在；重跑换 `OUTTAG=`（例如 `_freeze2`），不覆盖旧证据。
> ⚠️ 这份是 **count=0**；10-29 J07 跑的是 count=1/2（90 次）。两者合起来才是 135 次。

## 四、可选：§5.5 连续浸泡 40 分钟

跑完 §5 时板上是 pe16，可直接接着跑：

```bash
python rtl/vivado/soak_board.py --port COM9 --build 16 --minutes 40 \
  --no-flush --output logs/verification_2026-11-XX_A_soak_freeze.txt
```

**判据**：0 超时 / 0 数值不符 / 0 异常。
`--no-flush` 是浸泡专用开关（CH340 的 `flush()` 在持续负载下会永久阻塞）；
`--output` 显式给，别覆盖 10-21 那份。
不做不影响交付（10-21 已有 9,233/9,233 的浸泡）。

## 五、跑完做什么

1. 把三份 `board_pe*_freeze_txn.txt` 与 `..._freeze/session.json` 一起提交；
2. 在 `logs/freeze_regression_checklist.md` §10 勾掉「真板三档各 6/6」与「trace 三档各 15/15」，
   写上提交号与日期；
3. 在 `logs/project_state_changelog.md` 加一条「冻结回归 · 真板」；
4. 告诉 C：**报告不需要重建**（RTL 已冻结，正文未变）；
5. 九条放行条件全勾后，再打 `freeze-2026-11-04` tag 并推 GitHub 冻结版。

## 六、出问题怎么查

| 症状 | 先查什么 |
|---|---|
| 烧录报 `NO DEVICE` / 扫链为空 | 三样接线（14-Pin、P5、JTAG 拨码）；`sh rtl/vivado/run_board_prog.sh scan` |
| 板子不回话 | 串口号是否变了；有没有别的进程占串口；断电后位流是否已丢 |
| 256 个值**全错** | 烧的档位与 `PE=` 不一致 —— 重烧对应 `_runs/pe<N>/ntt_board.bit` |
| 开机没收到 `#RDY` | **预期**：串口在 PL 配置完成后才打开。不是故障（见 J07 日志 §3.1） |
| 报告已存在 | `TAG` 用错或重跑；留底后 `FORCE=1` |
| trace 输出目录已存在 | 换 `OUTTAG=` |
| 跑到一半卡住 | CH340 `flush()` 旧问题；本版 host 已去 flush + 写超时，重跑一次再看 |
