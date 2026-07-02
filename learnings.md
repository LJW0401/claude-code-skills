# Learnings

## 2026-07-01

### Bug 修复：daily-summary Codex-only 当天被误判为空
- **发现于**：用户报告桌面通知显示“无会话记录”。
- **现象**：2026-07-01 09:00-21:00 明明有 Codex 会话，定时任务仍跳过复盘且不生成 HTML。
- **根因**：`daily-summary.sh` 的前置检查只用 `find ~/.claude/projects` 统计 Claude Code jsonl，忽略 `~/.codex/state_5.sqlite` 索引到的 Codex rollout。
- **修复**：包装脚本复用 `collect.py` 统计 `claude_code_sessions + codex_rollouts`，`manage.sh` 同步部署 `collect.py` 到运行态目录。
- **回归测试**：原 `daily-summary/assets/tests/test_daily_summary_precheck.sh` 覆盖 Codex-only 应继续执行、空白日应跳过；该测试文件已按后续要求移除。
- **为什么原测试没覆盖**：定时包装脚本之前没有测试，且前置检查和正文采集各自维护数据源逻辑，Codex-only 场景没有被验证。
- **紧急程度**：中。
- **衍生改进建议**：后续可让无头执行器直接消费前置检查生成的 digest，减少重复扫描。
