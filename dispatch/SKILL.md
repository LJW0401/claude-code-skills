---
name: dispatch
description: 用自然语言把任务派发给子 agent 执行，默认后台运行，可选前台运行
disable-model-invocation: true
argument-hint: "[--fg] <自然语言任务描述>"
---

把用户用自然语言描述的任务派发给一个子 agent 去执行。默认在后台运行（不阻塞当前对话），如果用户在参数里显式带上 `--fg` 或 `--foreground`，则改为前台运行（等待结果再继续）。

## 参数解析

用户输入位于 `$ARGUMENTS`。按以下规则解析：

1. 如果 `$ARGUMENTS` 以 `--fg` 或 `--foreground` 开头（允许前后空格），则记 `background = false`，剩余部分作为任务描述
2. 否则 `background = true`，整段 `$ARGUMENTS` 都是任务描述
3. 如果任务描述为空，提示用户补充任务内容后停止

## 派发流程

1. 解析参数，得到 `background` 和任务描述
2. 用 `Agent` 工具派发任务，参数：
   - `subagent_type`: 按下方「子 agent 类型判定」选择
   - 注：除内置类型外，环境里若有用户自定义 subagent（如 code-reviewer），也可按相同规则匹配；不确定时回落到 `general-purpose`
   - `description`: 用 3–5 个中文/英文词概括任务
   - `prompt`: 把用户的自然语言任务**完整、自包含地**重写成给子 agent 的指令——子 agent 看不到当前对话，必须在 prompt 里交代清楚目标、相关路径/文件、产出形式、是否需要写代码或仅做调研。如果任务里隐含明显的工作目录或仓库上下文，把它写进 prompt
   - `run_in_background`: 等于 `background`
3. 调用之后：
   - 后台模式：告诉用户「已在后台派发：<任务摘要>」，提醒任务完成时会收到通知；不要轮询
   - 前台模式：等子 agent 返回结果，向用户汇总要点（不要原样转述长输出）

## 子 agent 类型判定

按以下优先级匹配任务描述里的关键词，选第一个命中的类型：

1. **`claude-code-guide`** — 命中："Claude Code"、"Agent SDK"、"Claude API"、"Anthropic SDK"、hooks、slash command、MCP、settings.json、IDE 扩展、键位绑定等。用于回答 Claude Code 工具链 / API 的使用问题，**不写代码**
2. **`Explore`** — 命中："调研"、"找一下"、"在哪"、"哪里定义"、"搜"、"看看 X 是怎么实现的"、"列出引用 X 的文件"。用于只读代码搜索，**不能改文件**；若任务可能要写代码，跳过此项
3. **`Plan`** — 命中："设计"、"做个方案"、"怎么实现"、"实施计划"、"步骤"、"架构"，且任务**不要求直接写代码**。用于产出实施计划与权衡分析
4. **`statusline-setup`** — 命中："状态栏"、"statusline"、配置 Claude Code 状态栏显示
5. **`general-purpose`** — 默认兜底。涉及写代码、改文件、跑命令、跨多步执行的任务一律用这个

判定边界：
- 任务里同时出现 "调研 + 改" → 用 `general-purpose`（Explore 无写权限）
- 任务里出现 "设计 + 实现" → 用 `general-purpose`（Plan 无写权限）
- 任务要求**输出调研文档/报告/md 文件**（"写一份调研文档"、"输出报告"、"落到 xxx.md"） → 用 `general-purpose`，不要用 `Explore`（Explore 没有 Write/Edit，只能返回文本，且只读取摘要片段会漏内容）
- 拿不准 → `general-purpose`，不要猜

## 注意事项

- prompt 里不要写 "based on prior context" 这类依赖当前对话上下文的话——子 agent 没有上下文
- 不要替用户决定写代码还是调研：如果用户说 "看看 X 是怎么实现的" 就明确是调研；说 "改一下 X" 才是写代码。把判断写进 prompt
- 一次只派发一个任务；如果用户描述了多件互不相关的事，先确认是合并成一个 agent 还是拆成多个并行
- 不要在派发前自己先去做大量探索——这正是要委派出去的工作
