#!/usr/bin/env python3
"""从提词稿生成剪映可导入的字幕（SRT）。

- 每段一个文件：`demo/subtitles/segN.srt`（从 0 起算，铺在该段人声轨上）；
- 合并一份：`demo/subtitles/all.srt`（九段首尾相接，段间留 0.6 s）；
- 时间线：`demo/subtitles/timeline.csv`。

有 A 的 WAV（`assets/*_video_vo_segN.wav`）时按真实时长分配；
没有时按提词稿的目标秒数生成**预览**，并打印警告 —— 预览只用于排版，
不能当最终字幕交。

用法：
    python demo/make_video_srt.py
    python demo/make_video_srt.py --out demo/subtitles --max-len 18
"""
import argparse
import csv
import glob
import re
import sys
import wave
from pathlib import Path

# Windows 控制台默认 GBK，emoji / 部分符号会直接抛 UnicodeEncodeError
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = Path(__file__).resolve().parent.parent
DEFAULT_SRC = REPO / "demo" / "narration_teleprompter.md"
ASSETS = REPO / "assets"

HEAD_RE = re.compile(
    r"^## 段 (\d+) · (.+?)（目标 (\d+) s ｜ 旁白 (\d+) 字，约 (\d+) s）"
)


def parse_segments(text):
    """返回 {段号: {title,target,planned,narration,visual}}（保持源顺序）。"""
    segs = {}
    cur = None
    for line in text.splitlines():
        m = HEAD_RE.match(line)
        if m:
            cur = int(m.group(1))
            segs[cur] = {
                "title": m.group(2),
                "target": int(m.group(3)),
                "planned": int(m.group(5)),
                "narration": [],
                "visual": "",
            }
            continue
        if cur is None:
            continue
        if line.startswith("> "):
            segs[cur]["narration"].append(line[2:].strip())
        elif line.startswith("**画面**"):
            segs[cur]["visual"] = line[len("**画面**："):].strip()
            cur = None
    for seg in segs.values():
        text = "".join(seg.pop("narration"))
        text = re.sub(r"[*`]", "", text)
        seg["text"] = text
    return dict(sorted(segs.items()))


def submission_text(seg_no, text):
    """段 8 有两版；SRT 用提交视频版（最后一句不是「板子也在」）。"""
    if seg_no != 8:
        return text
    return text.replace(
        "这块板子也在，随时可以真跑一遍。", "仓库地址在画面下方。"
    )


def _is_token_char(ch):
    return ch.isascii() and (ch.isalnum() or ch in "-_/")


def _cut_outside_token(s, cut):
    """英文单词/数字不从中间断开（AI-agent、921600 这类）。"""
    if cut <= 0 or cut >= len(s):
        return cut
    if not (_is_token_char(s[cut - 1]) and _is_token_char(s[cut])):
        return cut
    start = cut - 1
    while start > 0 and _is_token_char(s[start - 1]):
        start -= 1
    end = cut
    while end < len(s) and _is_token_char(s[end]):
        end += 1
    return start if start >= 8 else end


def split_cues(text, max_len):
    """按句号切句；超长的再按逗号/顿号/破折号切到 max_len 附近。"""
    cues = []
    for sentence in re.findall(r"[^。！？；]+[。！？；]?", text):
        s = sentence.strip()
        if not s:
            continue
        while len(s) > max_len:
            cut = max(s.rfind("，", 0, max_len), s.rfind("、", 0, max_len))
            dash = s.rfind("——", 0, max_len)
            if dash > 0:
                cut = max(cut, dash + 1)
            if cut < max_len // 2:
                cut = max_len
            else:
                cut += 1
            cut = _cut_outside_token(s, cut)
            cues.append(s[:cut].strip())
            s = s[cut:].lstrip("，、—— ").strip()
        if s:
            cues.append(s.strip())
    # 把「t 打法。」这类过短碎片并回上一条
    merged = []
    for c in cues:
        if merged and len(c) <= 2:
            merged[-1] += c
        else:
            merged.append(c)
    return merged


def find_wav(seg_no, assets=ASSETS):
    hits = sorted(glob.glob(str(assets / f"*_video_vo_seg{seg_no}.wav")))
    return Path(hits[-1]) if hits else None


def wav_seconds(path):
    with wave.open(str(path), "rb") as w:
        return w.getnframes() / float(w.getframerate())


def allocate(cues, total):
    """按字数比例分配时长，每句至少 1.0 s；不够时整体压缩到 total。"""
    weights = [max(len(c), 1) for c in cues]
    raw = [total * w / sum(weights) for w in weights]
    floor = min(1.0, total / len(cues))
    fixed = [max(r, floor) for r in raw]
    scale = total / sum(fixed)
    return [f * scale for f in fixed]


def ts(seconds):
    ms = int(round(seconds * 1000))
    h, ms = divmod(ms, 3600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def write_srt(path, cues, offset=0.0, lead=0.2):
    lines = []
    t = offset + lead
    for i, (text, dur) in enumerate(cues, 1):
        lines += [str(i), f"{ts(t)} --> {ts(t + dur)}", text, ""]
        t += dur
    path.write_text("\n".join(lines), encoding="utf-8", newline="\n")


def main():
    ap = argparse.ArgumentParser(description="从提词稿生成剪映字幕")
    ap.add_argument("--src", default=str(DEFAULT_SRC))
    ap.add_argument("--out", default=str(REPO / "demo" / "subtitles"))
    ap.add_argument("--max-len", type=int, default=18, help="单条字幕最多汉字数")
    ap.add_argument("--assets", default=str(ASSETS), help="WAV 所在目录")
    args = ap.parse_args()
    assets = Path(args.assets)

    segs = parse_segments(Path(args.src).read_text(encoding="utf-8"))
    if sorted(segs) != list(range(9)):
        raise SystemExit(f"提词稿应含段 0–8，实际：{sorted(segs)}")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    missing = [n for n in segs if find_wav(n, assets) is None]
    if missing:
        print(f"⚠ 未找到 seg{sorted(missing)} 的 WAV：时间按提词稿目标秒数估算（预览）")

    rows = []
    all_cues = []
    t_all = 0.0
    for n, seg in segs.items():
        text = submission_text(n, seg["text"])
        cues = split_cues(text, args.max_len)
        wav = find_wav(n, assets)
        if wav:
            seconds = wav_seconds(wav) - 0.4
        else:
            seconds = float(seg["planned"])
        durs = allocate(cues, seconds)
        write_srt(out / f"seg{n}.srt", list(zip(cues, durs)))
        all_cues += [(f"{n}", c, d) for c, d in zip(cues, durs)]
        rows.append({
            "seg": n,
            "title": seg["title"],
            "audio": wav.name if wav else f"(缺) *_video_vo_seg{n}.wav",
            "audio_seconds": f"{seconds + 0.4:.2f}" if wav else "",
            "planned_seconds": seg["planned"],
            "target_seconds": seg["target"],
            "visual": seg["visual"],
        })

    # 合并版：段间留 0.6 s
    lines = []
    t = 0.2
    idx = 1
    for _, text, dur in all_cues:
        lines += [str(idx), f"{ts(t)} --> {ts(t + dur)}", text, ""]
        idx += 1
        t += dur
    (out / "all.srt").write_text("\n".join(lines), encoding="utf-8", newline="\n")

    with (out / "timeline.csv").open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)

    total = sum(d for _, _, d in all_cues) + 0.6 * 8
    print(f"✅ {len(segs)} 段 / {len(all_cues)} 条字幕 → {out}")
    print(f"   人声轨合计约 {total / 60:.1f} 分钟（不含画面停顿）")
    if missing:
        print("   ⚠ 以上为预览时间；WAV 到齐后重跑本脚本即可得到同步字幕")


if __name__ == "__main__":
    main()
