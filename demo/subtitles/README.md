# 字幕（生成物）

由 `python demo/make_video_srt.py` 生成，**不要手改**。

| 文件 | 内容 |
|---|---|
| `seg0.srt` … `seg8.srt` | 每段一条，时间从 0 起算；铺在该段人声轨上 |
| `all.srt` | 九段首尾相接（段间 0.6 s），备用 |
| `timeline.csv` | 段号、人声文件、真实/计划时长、画面素材 |

⚠️ **当前是预览版（2026-10-24）**：A 的 9 段 WAV 还没入库，时间按提词稿的
目标秒数估算，只用于排版预览。

WAV 到齐后重跑一次即为同步字幕：

```bash
python demo/make_video_srt.py
```

脚本从 `assets/*_video_vo_segN.wav` 读真实时长；拉丁词与数字不从中间断行。
剪辑用法见 `../video_cut_sheet.md`。
