# GitHub 镜像 —— 一步步操作（2026-10-21 起）

> 目标：在 GitHub 放一份**冻结版**镜像。Gitee 仍是日常仓库，GitHub **不日常同步**，
> 只在冻结后（10/25–27）推一次，提交前把可见性改成 Public。
> ⚠️ 两个 remote 必须**独立**（`origin`=Gitee，`github`=GitHub），**不要**给一个 remote 配两个 URL。

## 0. 先确认现状

本机现在只有 Gitee：

```text
origin  https://gitee.com/lanxiteacher/pqc-ntt-mlkem.git
```

要变成：

```text
origin  https://gitee.com/lanxiteacher/pqc-ntt-mlkem.git   ← 日常，不动
github  https://github.com/<你的用户名>/pqc-ntt-mlkem.git    ← 冻结后推一次
```

## 1. 建 GitHub 账号（**只能你做**）

1. 打开 https://github.com/signup ，用邮箱注册（建议用队里长期能收信的邮箱）。
2. 收邮件、点验证链接。
3. 建议顺手开 2FA（Settings → Password and authentication → Two-factor authentication）。
   ⚠️ 开了 2FA 之后，命令行**不能**用账号密码推，必须用下面第 3 步的 token 或 SSH key。

## 2. 建仓库（**只能你做**，1 分钟）

1. 右上角 `+` → **New repository**。
2. Repository name：`pqc-ntt-mlkem`（与 Gitee 同名，便于对照）。
3. **Visibility：先选 Private**。
   - 现在选 Private，冻结推完、提交前再改 Public —— 避免 10 月下旬的中间状态提前公开。
   - 竞赛要求「开源」时，把 Private 改成 Public 即可（Settings → General → Danger Zone → Change visibility）。
4. **不要**勾 “Add a README file / Add .gitignore / Choose a license” —— 仓库里已经有了，勾了会多出一个无关的初始提交。
5. Create repository。

## 3. 认证：二选一（**只能你生成**）

### 方案 A：HTTPS + Personal Access Token（最简单，推荐）

1. GitHub 右上头像 → **Settings** → 左下 **Developer settings** →
   **Personal access tokens** → **Tokens (classic)** → **Generate new token (classic)**。
2. Note 填 `pqc-ntt-mlkem push`；Expiration 选 90 days；
   Scope 勾 **`repo`**（整块，推私有库需要）。
3. **Generate token** → 页面只显示一次 `ghp_...`，复制下来。
4. 第一次 `git push` 时 Windows 会弹 Git Credential Manager：
   - Username 填 GitHub 用户名；
   - Password 处**粘贴 token**（不是账号密码）；
   - 成功后凭据存进 Windows 凭据管理器，后面不用再输。

⚠️ **token 不要写进 remote URL、不要贴进聊天/仓库/日志**。泄漏就回 GitHub 页面 Revoke 重发。

### 方案 B：SSH key（不想管 token 就用这个）

```bash
ssh-keygen -t ed25519 -C "你的邮箱"       # 一路回车；有旧 key 就换个文件名
cat ~/.ssh/id_ed25519.pub                  # 复制整行
```

GitHub → Settings → **SSH and GPG keys** → New SSH key → 粘贴 → Add。
验证：`ssh -T git@github.com` 应回 “Hi <用户名>! You have successfully authenticated”。
这时 remote 用 SSH 形式：`git@github.com:<用户名>/pqc-ntt-mlkem.git`。

## 4. 加 remote（**我可以代做**，你给用户名）

```bash
git remote add github https://github.com/<你的用户名>/pqc-ntt-mlkem.git
git remote -v          # 应看到 origin 与 github 两行，各自独立
```

## 5. 冻结后推一次（10/25–27；**我可以代跑**，首次要你在弹窗点一下）

```bash
git tag -a freeze-2026-10-27 -m "submission freeze"   # 可选：给冻结版打标签
git push github main
git push github freeze-2026-10-27                     # 推了 tag 才有
```

⚠️ 只推 `main`。**不要** `git push --all`、**不要** `git push --mirror`，
也不要把 github 配成 origin 的第二个 URL（那就成了“一次推两边”）。

## 6. 推完核对（**我可以代做**）

- 网页上能看到 `README.md` / `rtl/` / `report/` / `logs/`；
- 仓库 **Settings → General** 里可见性还是 Private（提交前再改 Public）；
- 确认这些**没有**被推上去：`research/papers/`、`research/*.pdf`、`*.bit`、
  `assets/2026-10-15_A_board_uart_five_transactions.mp4`（112 MB 母版）—— `.gitignore` 已挡；
- 仓库大小：含 14.9 MB 的 1080p 录屏，约 30–60 MB 量级，GitHub 单文件上限 100 MB，没问题。

## 7. 之后怎么维护

- 日常提交/推送照旧只对 **Gitee**；GitHub 不跟着同步。
- 冻结后如果 Gitee 又修了评审必须改的东西：改完再 `git push github main` 一次（普通 push，历史是线性的）。
- 提交当天：GitHub 仓库改 **Public**，把链接放进提交材料；Gitee 也同步开公开（若还没开）。

## 8. 边界（别踩）

- GitHub 上的历史是**全部历史**（含 logs/ 里的内部记录）。推之前先想清楚：这些内容公开没问题。
- 不要把 token、密码、私钥写进仓库任何文件；`.gitignore` 里已有 `*token*.txt/md` 的粗挡，但别依赖它。
- 不要 force push，不要把两个 remote 配成镜像自动同步。
