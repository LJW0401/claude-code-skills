# daily-summary 使用说明

基于当天 Claude Code / Codex 的本机会话记录,自动还原工作主题,生成 HTML 每日工作总结并发到本人飞书邮箱。

> 本文是面向人的速查。完整的执行逻辑(数据源格式、解析片段、归类规则)见同目录 [`SKILL.md`](./SKILL.md),那份是写给 Claude 读的。

## 它做什么

1. 扫描 `~/.claude/projects` 下的 Claude Code `.jsonl` 与 `~/.codex` 下的 Codex rollout
2. 只取当天本地时间 **09:00–21:00** 复盘窗口内的会话
3. 从用户消息、助手回复、工具调用、命令结果还原「做了哪几件事」
4. 组织成 HTML：**主轴=全天时间线**(甘特图把几点在做哪个项目画出来 + 从早到晚的关键节点串联) → 可提交摘要 + 明日计划 →(分隔线)→ **副轴=各项目推进**(逐个项目复盘) + 跨项目观察
5. 通过 `lark-cli` 取本人邮箱并发送邮件(邮箱地址运行时获取,不硬编码)

## 手动触发

> 「采集 + 归类」(扫描会话、按 09:00–21:00 窗口过滤、按 `cwd` 合并成项目分组)已固化为 `assets/collect.py`,纯标准库、行为确定;Claude 拿它输出的 JSON digest 去提炼主题、撰写正文。可单独跑 `python3 assets/collect.py --date YYYY-MM-DD --pretty` 看采集结果。

在 Claude Code 里直接说,例如:

- 「总结今天的工作」
- 「根据对话整理日报」
- 「输出每日总结」

Claude 会自行驱动 `find` / `python3` / `lark-cli` 跑完全程。产物 `daily-summary-YYYY-MM-DD.html` 默认落在当前工作目录。

> 复盘窗口内没有任何会话(周末 / 休息日)时,不生成 HTML、不发邮件,直接告知「今天无工作记录」。

## 定时自动复盘(每天 21:00)

用 `assets/manage.sh` 一键部署 systemd user timer,每天 21:00 无人值守跑一次并发邮件。

```bash
cd assets
./manage.sh install     # 部署脚本+unit、开 linger、启用定时器(先校验 lark-cli 登录态)
./manage.sh status      # 看下次触发时间与 service 状态
./manage.sh run         # 立即手动跑一次(会真发邮件),用于验证链路
./manage.sh restart     # 改动 unit/脚本/配置模板后重新部署并重启使其生效
./manage.sh logs        # tail 运行日志
./manage.sh uninstall   # 停用并移除 unit 与脚本(保留日志与历史 HTML)
```

- 运行日志与 HTML 落在 `~/.local/state/daily-summary/`
- timer 配置 `Persistent=true`:关机错过的触发会在开机后补跑
- 定时任务前置检查复用 `collect.py`，按同一套规则识别 Claude Code 与 Codex 会话，窗口内两者都为 0 时才跳过
- 定时任务默认走 `claude --print --dangerously-skip-permissions` 放开工具权限(无人值守的必要条件,仅限该上下文)
- 可编辑 `~/ClaudeCode/tools/daily-summary/daily-summary.conf` 切换执行器：
  - `EXECUTOR=claude`：使用 Claude Code
  - `EXECUTOR=codex`：使用 Codex `codex exec --dangerously-bypass-approvals-and-sandbox`，切换前需确保 daily-summary skill 已安装到 Codex 可加载目录
- `./manage.sh restart` 会用仓库里的 `assets/daily-summary.conf` 覆盖运行态配置；只想临时切换时直接改运行态配置即可

## 前置依赖

- `lark-cli` 已登录且 token 未过期(发送前可 `lark-cli doctor` 自检)
- `python3`(解析 jsonl / 读 sqlite)、`find`、`date`
- 桌面通知依赖 `notify-send`(可选,失败不影响主流程)

## 注意事项

- **只写真实出现过的工作**,没抽到信号就承认没有,不臆造
- 敏感信息(邮箱等)一律运行时获取,不写进任何产物
- 默认一屏读完,不展开成长报告,除非明确要长版本
