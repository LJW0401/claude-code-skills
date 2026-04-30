# claude-code-skills

小企鹅的 Claude Code Skills 合集。

## Skill 列表

- **frontend-design** — 创建高质量前端界面的美学原则与设计指导
- **architecture-diagram** — 生成深色主题的 HTML/SVG 架构图
- **daily-summary** — 基于当天 Claude Code / Codex 会话记录生成每日工作总结
- **weekly-summary** — 基于最近 7 天的日报或原始会话记录生成每周工作总结

子仓库（git submodule，见 `.gitmodules`）：

- **claude-code-git-workflows** — Git 流程相关 skill（commit / merge / pr / push / release 等）
- **claude-code-project-workflows** — 项目研发流程 skill（requirements / arch / dev-plan / dev-execute 等）

首次克隆需带子仓库：

```bash
git clone --recurse-submodules <repo>
# 或已克隆后再拉取：
git submodule update --init --recursive
```

## 安装

使用 `manage.sh` 在 `~/.claude/skills/` 中创建符号链接，即可被 Claude Code 识别：

```bash
./manage.sh install            # 安装所有 skill
./manage.sh status             # 查看安装状态
./manage.sh update             # 重建符号链接
./manage.sh uninstall          # 卸载
./manage.sh install --force    # 覆盖指向其它项目的同名 symlink（也支持 -f / force）
```

脚本会**递归扫描**仓库中所有包含 `SKILL.md` 的目录（包括子模块内部）并将其作为 skill 安装；symlink 名取自 `SKILL.md` 所在目录的 basename。同名冲突会直接报错退出。

## 同步到 Codex

使用 `link-codex-skills.sh` 将 `~/.claude/skills/` 下所有 Claude Code skill 链接到 `~/.codex/skills/`，让 Codex 也能发现并调用这些 skill：

```bash
./link-codex-skills.sh install     # 创建缺失链接
./link-codex-skills.sh status      # 查看链接状态
./link-codex-skills.sh update      # 重建本脚本管理的链接
./link-codex-skills.sh uninstall   # 移除本脚本管理的链接
```

脚本默认不会覆盖 `~/.codex/skills/` 中已有的非符号链接，也不会改动指向其他位置的符号链接。可通过环境变量覆盖源和目标目录：

```bash
CLAUDE_SKILLS_DIR=~/.claude/skills CODEX_SKILLS_DIR=~/.codex/skills ./link-codex-skills.sh install
```

## 目录约定

每个 skill 是一个子目录，目录下必须包含 `SKILL.md`：

```
claude-code-skills/
├── .gitmodules                       # 子仓库登记
├── manage.sh
├── link-codex-skills.sh
├── frontend-design/
│   └── SKILL.md
├── claude-code-git-workflows/        # submodule
│   ├── commit/SKILL.md
│   └── ...
├── claude-code-project-workflows/    # submodule
└── ...
```
