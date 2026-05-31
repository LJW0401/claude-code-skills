# weekly-summary 使用说明

基于本周（**周一到周六，周日不计**）的工作记录，双源融合生成 HTML 每周工作总结并发到本人飞书邮箱。

> 本文是面向人的速查。完整的执行逻辑（数据源格式、字段结构、聚合规则、HTML 渲染与发信）见同目录 [`SKILL.md`](./SKILL.md)，那份是写给 Claude 读的。

## 它做什么

1. **数据源1（主线，权威）**：拉飞书「汇报」里本人手写的工作日报/周报 —— 这是你亲手筛过的内容，定周报骨架、闭环结论和下周计划
2. **数据源2（细节补充）**：每天配一份 daily-summary 细节底稿 —— 先找本地 `daily-summary-*.html`，本地缺则从飞书邮箱「每日工作总结」邮件回退取，用来补汇报里被压掉的 commit / 数值 / bug 根因
3. **兜底**：汇报和本地/邮箱日报都缺时，才回退扫描 `~/.claude/projects` 的 `.jsonl` 原始会话
4. 按「摘要 / 项目进展 / 时间线 / 闭环与未闭环」组织成 HTML（三层结构）
5. 通过 `lark-cli` 取本人邮箱并发送（邮箱地址运行时获取，不硬编码）

> 飞书汇报是手写浓缩版（约几百字/天），本地 daily-summary 是会话还原（约数千字/天），差约一个数量级 —— 所以是**融合**而非二选一：汇报定调、日报补细节。

## 手动触发

> 「双源采集」（取本人 open_id、拉区间汇报、按本人过滤、配本地/邮箱细节）已固化为 `assets/collect.py`，纯标准库 + `lark-cli`、行为确定；Claude 拿它输出的 JSON digest 去聚合、撰写周报。可单独跑看采集结果：
>
> ```bash
> python3 assets/collect.py --pretty            # 默认本周（今天所在 ISO 周的周一起）
> python3 assets/collect.py --monday 2026-05-25 # 指定某周（传该周周一）
> ```
>
> 输出 JSON 顶层：`week`（周一/周六）、`me`（本人 open_id）、`stats`（report_days / detail_local / detail_mail / detail_none / weekly_reports）、`days[]`（每天 date·weekday·report·detail）、`weekly_reports[]`。

在 Claude Code 里直接说，例如：

- 「总结本周工作」
- 「写个周报」
- 「输出每周总结」

Claude 会跑 `collect.py` 采集，先用 `stats` 给你对账（覆盖了几天、细节来自本地还是邮箱回退、哪天缺），再聚合成周报。产物 `weekly-summary-YYYY-Www.html`（如 `weekly-summary-2026-W22.html`）默认落在当前工作目录。

## 时间口径

- **统计周一到周六，周日不计入**（每周 6 个工作日）
- 默认取今天所在 ISO 周；在周日跑也只统计本周一~周六，当天（周日）不计
- 指定其它周用 `--monday <该周周一>`；脚本时间窗按「周一 00:00 → 周日 00:00（不含）」取

## 前置依赖

- `lark-cli` 已 **登录 user 身份**且 token 未过期（`lark-cli doctor` 自检）—— 汇报与邮箱都用 `--as user` 读，无需给应用加 tenant 级 scope
- `python3`（跑 `collect.py`、解析 JSON、剥 HTML）
- 飞书侧：本人在「汇报」里写过工作日报/周报（数据源1），daily-summary 跑过或发过邮件（数据源2）

## 注意事项

- **以汇报为主线、不被细节淹没**：本地日报字数是汇报的约 10 倍，融合时别原样堆砌，每个项目只补 1-3 条关键细节（提交号/数值/根因）
- **只写真实出现过的里程碑**：commit / PR / release 必须在汇报或日报里真实出现，没抽到就说「本周无发版」，不臆造
- **缺细节不编**：某天本地和邮箱都没有，就只用汇报主线，标注「无细节源」
- 敏感信息（open_id、邮箱）一律运行时获取，不写进脚本、文档或任何产物
