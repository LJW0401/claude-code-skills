# claude-code-skills

小企鹅的 Claude Code Skills 合集。

## Skill 列表

- **frontend-design** — 创建高质量前端界面的美学原则与设计指导
- **daily-summary** — 基于当天 Claude Code 会话记录生成每日工作总结
- **weekly-summary** — 基于最近 7 天的日报或原始会话记录生成每周工作总结

## 安装

使用 `manage.sh` 在 `~/.claude/skills/` 中创建符号链接，即可被 Claude Code 识别：

```bash
./manage.sh install     # 安装所有 skill
./manage.sh status      # 查看安装状态
./manage.sh update      # 重建符号链接
./manage.sh uninstall   # 卸载
```

脚本会自动扫描仓库中包含 `SKILL.md` 的子目录并将其作为 skill 安装。

## 目录约定

每个 skill 是一个子目录，目录下必须包含 `SKILL.md`：

```
claude-code-skills/
├── manage.sh
├── frontend-design/
│   └── SKILL.md
└── ...
```
